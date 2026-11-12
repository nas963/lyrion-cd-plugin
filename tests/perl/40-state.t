use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use File::Temp ();
use File::Path ();
use File::Spec ();
use JSON::PP ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::State') }

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my $S   = 'Plugins::AudioCD::State';
my $fix = dirname($0) . '/fixtures';

sub slurp {
	my ($name) = @_;
	open my $fh, '<:raw', "$fix/$name" or die "$name: $!";
	local $/;
	return scalar <$fh>;
}

my $TOC = JSON::PP->new->utf8->decode(slurp('real-disc-toc.json'))->{toc};
my $ID  = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';
# drugi disk: 3 pesme po 60 s
my $TOC2 = { first => 1, last => 3, leadout => 3 * 60 * 75,
	tracks => [ map { { n => $_, lba => ($_ - 1) * 60 * 75, data => 0 } } 1 .. 3 ] };
# samo data pesma
my $TOC_DATA = { first => 1, last => 1, leadout => 1000, tracks => [ { n => 1, lba => 0, data => 1 } ] };

my $root = File::Spec->rel2abs(File::Temp::tempdir('state-XXXXXX', DIR => '.', CLEANUP => 1));
my $seq  = 0;

sub mkdisc {
	my (%o) = @_;
	my $n = $o{tracks} // 9;
	return {
		discid => $o{discid} // $ID, cddbid => '6a0a1f09', source => $o{source} // 'musicbrainz',
		release_id => $o{release_id} // 'rel-1', release_group_id => 'rg-1',
		artist => $o{artist} // 'Bobby McFerrin', album => $o{album} // 'The Story of Jazz', year => 1995,
		disc_number => 1, disc_total => 1, compilation => 0,
		tracks => [ map { { n => $_, title => "Pesma $_", artist => 'Bobby McFerrin', length => 100 } } 1 .. $n ],
	};
}

sub mkresult {
	my (%o) = @_;
	my @c = map {
		my $d = mkdisc(%o, release_id => "rel-$_", album => ($_ == 1 ? ($o{album} // 'The Story of Jazz') : "Drugo izdanje $_"));
		{ release_id => "rel-$_", title => $d->{album}, artist => $d->{artist}, country => 'US', date => '1995',
			label => 'Lbl', format => 'CD', disc_count => 1, medium_position => 1, disc => $d }
	} 1 .. ($o{candidates} // 1);
	return {
		discid => $o{discid} // $ID, cddbid => '6a0a1f09', candidates => \@c, selected => 0,
		fuzzy => $o{fuzzy} // 0, disc => $c[0]{disc},
		cover_urls => $o{cover_urls} // [],
	};
}

# ---- lazni Lookup ----
{
	package FakeLookup;
	sub new { bless { calls => [] }, shift }
	sub lookup { my ($s, $toc, $cb, %o) = @_; push @{ $s->{calls} }, { toc => $toc, cb => $cb, opt => {%o} } }
	sub last_cb { $_[0]{calls}[-1]{cb} }
}

# ---- lazni Cache ----
{
	package FakeCache;
	sub new { bless { discid => undef, done => {}, busy => 0, starts => [], stops => 0, clears => 0 }, shift }
	sub start {
		my ($s, $disc, $toc, $n) = @_;
		push @{ $s->{starts} }, { disc => $disc, toc => $toc, n => $n };
		if (!defined $s->{discid} || $s->{discid} ne $disc->{discid}) { $s->{done} = {} }
		$s->{discid} = $disc->{discid};
		$s->{busy}   = 1;
		return 1;
	}
	sub stop   { my $s = shift; $s->{stops}++; $s->{busy} = 0 }
	sub clear  { my $s = shift; $s->{clears}++; $s->{busy} = 0; $s->{discid} = undef; $s->{done} = {} }
	sub busy   { $_[0]{busy} }
	sub discid { $_[0]{discid} }
	sub ready  { my ($s, $n) = @_; $s->{done}{$n} ? 1 : 0 }
	sub status { my $s = shift; { done => [ sort { $a <=> $b } keys %{ $s->{done} } ], failed => [], current => undef, percent => 0 } }
	sub complete_all { my ($s, $n) = @_; $s->{done} = { map { $_ => 1 } 1 .. $n }; $s->{busy} = 0 }
}

# ---- lazni Ripper ----
{
	package FakeRipper;
	sub new { bless { enq => [], aborts => [], cancels => [], current => undef, queue => [], history => [], err => undef }, shift }
	sub enqueue {
		my ($s, %a) = @_;
		push @{ $s->{enq} }, {%a};
		return (undef, $s->{err}) if $s->{err};
		my $id = 'rip-' . scalar @{ $s->{enq} };
		$s->{current} = { id => $id, disc => $a{disc}{discid}, percent => 0, state => 'ripping', eject_after => $a{eject_after} ? 1 : 0 };
		return ($id, undef);
	}
	sub abort_all { my ($s, $r) = @_; push @{ $s->{aborts} }, $r; $s->{current} = undef; $s->{queue} = []; 1 }
	sub cancel    { my ($s, $id) = @_; push @{ $s->{cancels} }, $id; 1 }
	sub busy      { $_[0]{current} || @{ $_[0]{queue} } ? 1 : 0 }
	sub status    { { current => $_[0]{current}, queue => $_[0]{queue} } }
	sub history   { [ @{ $_[0]{history} } ] }
}

# Svet: State sa laznim zavisnostima. $w->{toc} je ono sto drajv trenutno vraca.
sub world {
	my (%o) = @_;
	my $w = {
		toc     => exists $o{toc} ? $o{toc} : $TOC,
		toc_err => $o{toc_err},
		prefs   => { device => '/dev/cdrom', autoLoad => 1, autoRip => 0, autoRipProfile => 'secure',
			ejectAfterRip => 0, notify => 1, quietDrive => 0, quietSpeed => 8, driveOffset => '',
			profile => 'balanced', %{ $o{prefs} || {} } },
		lookup  => FakeLookup->new,
		cache   => FakeCache->new,
		ripper  => FakeRipper->new,
		missing => $o{missing} || [],
		plays   => [],
		covers  => [],
		ejects  => 0,
		notes   => [],
		kills   => 0,
		reads   => 0,
		cdinfo  => 0,
		lookup_kills => 0,
		drive   => [ 4, undef ],
		drive_calls => 0,
		eject_args => [],
		dir     => "$root/w" . ++$seq,
	};
	File::Path::make_path("$w->{dir}/meta", "$w->{dir}/rips");
	$w->{ripper}{history} = $o{history} if $o{history};
	require Plugins::AudioCD::MetaCache;
	$w->{meta} = Plugins::AudioCD::MetaCache->new(dir => "$w->{dir}/meta");
	$w->{state} = $S->new(
		pref        => sub { $w->{prefs}{ $_[0] } },
		read_toc    => sub { $w->{reads}++; return $w->{toc_err} ? (undef, $w->{toc_err}) : ($w->{toc}, undef) },
		lookup      => $w->{lookup},
		metacache   => $w->{meta},
		cache       => $w->{cache},
		ripper      => $w->{ripper},
		rips_dir    => sub { "$w->{dir}/rips" },
		fetch_cover => sub { push @{ $w->{covers} }, [@_] },
		play        => sub { push @{ $w->{plays} }, [@_]; return (1, undef) },
		eject       => sub { $w->{ejects}++; push @{ $w->{eject_args} }, $_[0] },
		missing_tools => sub { @{ $w->{missing} } },
		notify      => sub { push @{ $w->{notes} }, $_[0] },
		kill_all    => sub { $w->{kills}++ },
		drive_status => sub { $w->{drive_calls}++; @{ $w->{drive} } },
		lookup_busy => sub { $w->{cdinfo} },
		kill_lookup => sub { $w->{lookup_kills}++ },    # asinhrono: proces jos zivi
	);
	return $w;
}

sub loaded {
	my (%o) = @_;
	my $w = world(%o);
	$w->{state}->on_load;
	$w->{lookup}->last_cb->(mkresult(%{ $o{result} || {} }));
	return $w;
}

# ---------- load / lookup ----------
{
	my $w = world();
	my $st = $w->{state};
	is($st->snapshot->{status}, 'empty', 'pocetno stanje empty');
	$st->on_load;
	is($st->snapshot->{status}, 'reading', 'on_load -> reading');
	is($st->snapshot->{discid}, $ID, 'discid izracunat iz TOC-a');
	is($st->snapshot->{cddbid}, '6a0a1f09', 'cddbid izracunat iz TOC-a');
	is(scalar @{ $w->{lookup}{calls} }, 1, 'jedan lookup');
	ok(!$w->{lookup}{calls}[0]{opt}{offline}, 'online lookup');
	$w->{lookup}->last_cb->(mkresult(candidates => 2, fuzzy => 1));
	my $snap = $st->snapshot;
	is($snap->{status}, 'ready', 'lookup gotov -> ready');
	is($snap->{metadata}{album}, 'The Story of Jazz', 'metapodaci');
	is(scalar @{ $snap->{releases} }, 2, 'dva izdanja');
	is($snap->{releases}[1]{title}, 'Drugo izdanje 2', 'izdanje: naslov');
	ok(!exists $snap->{releases}[0]{disc}, 'izdanje bez celog diska u snapshot-u');
	is($snap->{release_idx}, 0, 'release_idx');
	is($snap->{fuzzy}, 1, 'fuzzy oznaka');
	is($snap->{drive_busy}, 'none', 'drive_busy none');
	ok($w->{meta}->get($ID), 'rezultat sacuvan u MetaCache');
	for my $k (qw(status toc discid cddbid releases release_idx metadata cover_url drive_busy cache rip errors missing_tools)) {
		ok(exists $snap->{$k}, "snapshot ima $k");
	}
	ok(eval { JSON::PP->new->encode($snap); 1 }, 'snapshot je JSON') or diag $@;

	# isti disk ponovo: nema novog lookup-a
	$st->on_load;
	is(scalar @{ $w->{lookup}{calls} }, 1, 'on_load za isti discid ne pokrece lookup');
	is($st->snapshot->{status}, 'ready', 'i dalje ready');

	# force: pokusaj ponovo
	$st->on_load(force => 1);
	is(scalar @{ $w->{lookup}{calls} }, 2, 'force -> novi lookup');
}

# MetaCache pogodak: bez lookup-a
{
	my $w = world();
	$w->{meta}->put($ID, mkresult(album => 'Iz kesa'));
	$w->{state}->on_load;
	is(scalar @{ $w->{lookup}{calls} }, 0, 'kes pogodak: nema lookup-a');
	is($w->{state}->snapshot->{status}, 'ready', 'kes pogodak: ready');
	is($w->{state}->snapshot->{metadata}{album}, 'Iz kesa', 'kes pogodak: album');
}

# offline: preskace MetaCache i trazi samo CD-Text/genericki
{
	my $w = world();
	$w->{meta}->put($ID, mkresult(album => 'Iz kesa'));
	$w->{state}->on_load(offline => 1);
	is(scalar @{ $w->{lookup}{calls} }, 1, 'offline: lookup uprkos kesu');
	ok($w->{lookup}{calls}[0]{opt}{offline}, 'offline: Lookup dobija offline => 1');
	my $gen = mkresult();
	$gen->{disc}{source} = 'generic';
	$gen->{disc}{album}  = 'Audio CD';
	$w->{lookup}->last_cb->($gen);
	is($w->{state}->snapshot->{metadata}{album}, 'Audio CD', 'offline: genericki');
	is($w->{meta}->get($ID)->{disc}{album}, 'Iz kesa', 'offline rezultat ne prepisuje kes');
}

# genericki rezultat (npr. nema mreze) se ne kesira
{
	my $w = world();
	$w->{state}->on_load;
	my $gen = mkresult();
	$gen->{disc}{source} = 'generic';
	$w->{lookup}->last_cb->($gen);
	ok(!$w->{meta}->get($ID), 'genericki rezultat nije kesiran');
}

# greske drajva
{
	my $w = world(toc_err => 'permission');
	$w->{state}->on_load;
	my $s = $w->{state}->snapshot;
	is($s->{status}, 'error', 'permission -> error');
	is($s->{errors}[0]{code}, 'permission', 'greska permission');
	is(scalar @{ $w->{lookup}{calls} }, 0, 'bez lookup-a');

	$w = world(toc_err => 'no_disc');
	$w->{state}->on_load;
	is($w->{state}->snapshot->{status}, 'empty', 'no_disc -> empty');
	is($w->{state}->snapshot->{errors}[0]{code}, 'no_disc', 'greska no_disc');

	$w = world(toc => $TOC_DATA);
	$w->{state}->on_load;
	is($w->{state}->snapshot->{status}, 'empty', 'data disk -> empty');
	is($w->{state}->snapshot->{errors}[0]{code}, 'no_audio', 'greska no_audio');
}

# ---------- omot ----------
{
	my $w = loaded(result => { cover_urls => [ 'http://caa/a', 'http://caa/b' ] });
	is(scalar @{ $w->{covers} }, 1, 'omot se preuzima');
	is_deeply($w->{covers}[0][0], [ 'http://caa/a', 'http://caa/b' ], 'omot: URL-ovi redom');
	is($w->{covers}[0][1], $w->{meta}->cover_path($ID), 'omot ide u MetaCache::cover_path');
	ok(!defined $w->{state}->snapshot->{cover_url}, 'pre preuzimanja nema cover_url');
	open my $fh, '>', $w->{meta}->cover_path($ID) or die $!;
	print {$fh} 'jpg';
	close $fh;
	$w->{covers}[0][2]->(1);
	is($w->{state}->snapshot->{cover_url}, "/plugins/AudioCD/cover/$ID.jpg", 'cover_url posle preuzimanja');
	ok(!exists $w->{state}->snapshot->{cover_path}, 'snapshot bez putanje fajla na serveru');

	# omot vec postoji: ne preuzima se ponovo
	my $w2 = world();
	File::Path::make_path("$w2->{dir}/meta");
	open $fh, '>', $w2->{meta}->cover_path($ID) or die $!;
	close $fh;
	$w2->{state}->on_load;
	$w2->{lookup}->last_cb->(mkresult(cover_urls => ['http://caa/a']));
	is(scalar @{ $w2->{covers} }, 0, 'postojeci omot se ne preuzima');
	ok(defined $w2->{state}->snapshot->{cover_url}, 'postojeci omot: cover_url');
}

# ---------- select_release / edit ----------
{
	my $w = loaded(result => { candidates => 3 });
	my $st = $w->{state};
	my ($ok, $err) = $st->select_release(2);
	ok($ok, 'select_release(2)');
	is($st->snapshot->{release_idx}, 2, 'release_idx 2');
	is($st->snapshot->{metadata}{album}, 'Drugo izdanje 3', 'metapodaci izabranog izdanja');
	is($w->{meta}->get($ID)->{selected}, 2, 'izbor sacuvan u kesu');
	my $w3 = world();
	$w3->{meta}->put($ID, { %{ mkresult(candidates => 3) }, selected => '2' });
	$w3->{state}->on_load;
	like(JSON::PP->new->encode({ i => $w3->{state}->snapshot->{release_idx} }), qr/"i":2\}/, 'release_idx je broj u JSON-u');
	($ok, $err) = $st->select_release(7);
	ok(!$ok, 'nepostojeci indeks odbijen');
	is($err->{error}, 'bad_index', 'greska bad_index');

	($ok, $err) = $st->edit({ artist => 'Đorđe Balašević', album => 'Ćao', year => 1990,
		tracks => [ { n => 1, title => 'Prva' }, { n => 2, title => 'Druga', artist => 'Gost' } ] });
	ok($ok, 'edit') or diag explain $err;
	my $m = $st->snapshot->{metadata};
	is($m->{artist}, 'Đorđe Balašević', 'edit: izvodjac');
	is($m->{album}, 'Ćao', 'edit: album');
	is($m->{source}, 'manual', 'edit: source manual');
	is($m->{tracks}[0]{title}, 'Prva', 'edit: naslov 1');
	is($m->{tracks}[1]{artist}, 'Gost', 'edit: izvodjac pesme 2');
	is($m->{tracks}[2]{title}, 'Pesma 3', 'edit: neizmenjena pesma ostaje');
	is($m->{tracks}[0]{length}, 100, 'edit: trajanje ostaje');
	is($m->{discid}, $ID, 'edit: discid ostaje');
	is($w->{meta}->get($ID)->{disc}{album}, 'Ćao', 'edit sacuvan (manual pobedjuje)');
	($ok, $err) = $st->edit('nije hash');
	ok(!$ok, 'edit: los ulaz odbijen');

	my $e = world();
	($ok, $err) = $e->{state}->edit({ album => 'x' });
	is($err->{error}, 'no_disc', 'edit bez diska -> no_disc');
}

# ---------- Play ----------
{
	my $w = loaded();
	my $st = $w->{state};
	my ($ok, $err) = $st->request_play('aa:bb', 3);
	ok($ok, 'request_play') or diag explain $err;
	is(scalar @{ $w->{cache}{starts} }, 1, 'kes pokrenut');
	is($w->{cache}{starts}[0]{n}, 3, 'kes pocinje od izabrane pesme');
	is($w->{cache}{starts}[0]{disc}{discid}, $ID, 'kes dobija disk');
	my $p = $w->{plays}[0];
	is($p->[0], 'aa:bb', 'play: plejer');
	is_deeply($p->[1], [ map { "audiocd://$ID/$_" } 1 .. 9 ], 'play: sve pesme');
	is($p->[2], 2, 'play: start od izabrane (indeks 2)');
	is($st->drive_busy, 'cache', 'drive_busy cache');

	# Review Focus 5: drugi Play istog diska (drugi plejer) koristi isti kes
	($ok, $err) = $st->request_play('cc:dd', 5);
	ok($ok, 'drugi request_play');
	is(scalar @{ $w->{cache}{starts} }, 2, 'drugi Play: isti kes, nadovezuje se');
	is($w->{cache}{clears} + $w->{cache}{stops}, 0, 'drugi Play: kes se ne brise i ne zaustavlja');
	is($w->{cache}{starts}[1]{disc}{discid}, $ID, 'drugi Play: isti disk');
	is(scalar @{ $w->{ripper}{enq} }, 0, 'nikad dva procesa na drajvu');

	# Review Focus 5: rip dok traje kesiranje
	($ok, $err) = $st->request_rip(profile => 'fast');
	ok(!$ok, 'rip dok se kesira odbijen');
	is($err->{error}, 'drive_busy', 'rip dok se kesira: drive_busy');
	is(scalar @{ $w->{ripper}{enq} }, 0, 'rip nije dodat u red');

	# kes kompletan -> rip moze
	$w->{cache}->complete_all(9);
	is($st->drive_busy, 'none', 'kes gotov -> none');
	($ok, $err) = $st->request_rip(profile => 'fast');
	ok($ok, 'rip posle kompletnog kesa') or diag explain $err;
	is($st->drive_busy, 'rip', 'drive_busy rip');

	# Play tokom ripa: disk je ceo u kesu -> radi
	($ok, $err) = $st->request_play('aa:bb', 1);
	ok($ok, 'Play tokom ripa radi kad je disk ceo u kesu');

	# nepostojeca pesma
	($ok, $err) = $st->request_play('aa:bb', 42);
	is($err->{error}, 'bad_track', 'nepostojeca pesma');
}

# Play tokom ripa bez kesa -> drive_busy
{
	my $w = loaded();
	my $st = $w->{state};
	my ($ok, $err) = $st->request_rip(profile => 'balanced');
	ok($ok, 'rip');
	($ok, $err) = $st->request_play('aa:bb', 1);
	ok(!$ok, 'Play tokom ripa odbijen');
	is($err->{error}, 'drive_busy', 'Play tokom ripa: drive_busy');
	is(scalar @{ $w->{cache}{starts} }, 0, 'kes nije pokrenut');
	is(scalar @{ $w->{plays} }, 0, 'plejer nije dirnut');
}

# Play/rip bez diska, bez alata
{
	my $w = world();
	my ($ok, $err) = $w->{state}->request_play('aa:bb', 1);
	is($err->{error}, 'no_disc', 'Play bez diska');
	($ok, $err) = $w->{state}->request_rip;
	is($err->{error}, 'no_disc', 'rip bez diska');

	$w = loaded(missing => ['cyanrip', 'flac']);
	($ok, $err) = $w->{state}->request_rip;
	is($err->{error}, 'missing_tools', 'rip bez cyanrip-a');
	is_deeply($err->{tools}, ['cyanrip'], 'rip: koji alat fali');
	($ok, $err) = $w->{state}->request_play('aa:bb', 1);
	is($err->{error}, 'missing_tools', 'Play bez flac-a');
	is_deeply($w->{state}->snapshot->{missing_tools},
		[ { tool => 'cyanrip', package => 'cyanrip' }, { tool => 'flac', package => 'flac' } ], 'snapshot: missing_tools sa paketom');
}

# ---------- rip argumenti ----------
{
	my $w = loaded(prefs => { quietDrive => 1, quietSpeed => 4, driveOffset => '6', ejectAfterRip => 1 });
	open my $fh, '>', $w->{meta}->cover_path($ID) or die $!;
	close $fh;
	my ($ok, $err) = $w->{state}->request_rip(profile => 'secure', flac => 8);
	ok($ok, 'rip');
	my $a = $w->{ripper}{enq}[0];
	is($a->{profile}, 'secure', 'rip: profil');
	is($a->{disc}{album}, 'The Story of Jazz', 'rip: disk');
	is($a->{toc}, $TOC, 'rip: toc');
	is($a->{device}, '/dev/cdrom', 'rip: uredjaj');
	is($a->{rips_dir}, "$w->{dir}/rips", 'rip: podrazumevani folder');
	is($a->{quiet_speed}, 4, 'rip: tisi drajv');
	is($a->{offset}, '6', 'rip: ofset');
	is($a->{eject_after}, 1, 'rip: eject iz prefs-a');
	is($a->{cover_src}, $w->{meta}->cover_path($ID), 'rip: omot');
	ok(!exists $a->{flac_level}, 'rip: bez flac nivoa (Ruling 15)');

	$w = loaded();
	($ok, $err) = $w->{state}->request_rip(dir => '/mnt/x', eject => 0);
	$a = $w->{ripper}{enq}[0];
	is($a->{rips_dir}, '/mnt/x', 'rip: folder iz zahteva');
	is($a->{profile}, 'balanced', 'rip: podrazumevani profil iz prefs-a');
	ok(!defined $a->{quiet_speed}, 'rip: bez tiseg drajva');
	ok(!defined $a->{offset}, 'rip: prazan ofset -> undef');
	is($a->{eject_after}, 0, 'rip: eject 0');
	ok(!defined $a->{cover_src}, 'rip: bez omota');

	($ok, $err) = $w->{state}->request_rip(dir => 'relativno');
	is($err->{error}, 'bad_args', 'rip: relativan folder odbijen');

	$w = loaded();
	$w->{ripper}{err} = { error => 'no_space', needed => 500, free => 100 };
	($ok, $err) = $w->{state}->request_rip;
	is_deeply($err, { error => 'no_space', needed => 500, free => 100 }, 'rip: greska Ripper-a se prosledjuje');
}

# ---------- Review Focus 1: izbacivanje tokom posla ----------
{
	my $w = loaded();
	my $st = $w->{state};
	$st->request_play('aa:bb', 1);
	$st->on_eject;
	my $s = $st->snapshot;
	is($s->{status}, 'empty', 'eject tokom kesiranja -> empty');
	ok(!defined $s->{discid}, 'stari discid nije prikazan');
	ok(!defined $s->{metadata}, 'stari metapodaci nisu prikazani');
	is_deeply($s->{releases}, [], 'nema izdanja');
	ok($w->{cache}{stops} >= 1, 'Cache::stop');
	ok($w->{cache}{clears} >= 1, 'Cache::clear');
	ok(!defined $w->{cache}->discid, 'kes obrisan');

	$w = loaded();
	$st = $w->{state};
	$w->{cache}->complete_all(9);
	$st->request_rip;
	$st->on_eject;
	is_deeply($w->{ripper}{aborts}, ['ejected'], "eject tokom ripa -> abort_all('ejected')");
	is($st->snapshot->{status}, 'empty', 'eject tokom ripa -> empty');
	is($st->drive_busy, 'none', 'drajv slobodan');

	# zakasneli lookup posle izbacivanja se ignorise
	$w = world();
	$st = $w->{state};
	$st->on_load;
	my $cb = $w->{lookup}->last_cb;
	$st->on_eject;
	$cb->(mkresult());
	is($st->snapshot->{status}, 'empty', 'zakasneli lookup posle eject-a ignorisan');
	ok(!defined $st->snapshot->{discid}, 'zakasneli lookup: nema discid');

	# zamenjen disk: novi disk prekida posao starog
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{toc} = $TOC2;
	my $reads = $w->{reads};
	my ($lok, $lerr) = $st->on_load;
	is($lerr->{error}, 'drive_busy', 'load tokom kesiranja -> drive_busy');
	is($w->{reads}, $reads, 'load tokom kesiranja: nema read_toc ioctl-a');
	$w->{cache}{busy} = 0;    # kes stao (npr. pesme pukle jer je disk izvadjen)
	$st->on_load;
	ok($w->{cache}{clears} >= 1, 'zamenjen disk: kes starog obrisan');
	is($st->snapshot->{status}, 'reading', 'zamenjen disk: reading');
	isnt($st->snapshot->{discid}, $ID, 'zamenjen disk: novi discid');
	ok(!defined $st->snapshot->{metadata}, 'zamenjen disk: nema starih metapodataka');

	# eject komanda: prekida poslove i izbacuje
	$w = loaded();
	$st = $w->{state};
	$st->request_rip;
	$st->eject;
	is_deeply($w->{ripper}{aborts}, ['ejected'], 'eject komanda: abort_all');
	is($w->{ejects}, 1, 'eject komanda: drajv izbacen');
	is($st->snapshot->{status}, 'empty', 'eject komanda: empty');
}

# ---------- polling ----------
{
	my $w = world();
	my $st = $w->{state};
	$st->on_drive_status(4, undef);    # CDS_DISC_OK
	is(scalar @{ $w->{lookup}{calls} }, 1, 'polling: disk ubacen -> load');
	$st->on_drive_status(4, undef);
	is(scalar @{ $w->{lookup}{calls} }, 1, 'polling: isti status -> nista');
	$w->{lookup}->last_cb->(mkresult());
	$st->on_drive_status(2, undef);    # CDS_TRAY_OPEN
	is($st->snapshot->{status}, 'empty', 'polling: disk izvadjen -> eject_event');

	# dok traje posao polling ne radi nista
	$w = loaded();
	$st = $w->{state};
	$st->on_drive_status(4, undef);
	$st->request_play('aa:bb', 1);
	$st->on_drive_status(1, undef);
	is($st->snapshot->{status}, 'ready', 'polling: ne radi dok traje kesiranje');

	# autoLoad iskljucen: ubacen disk se ne cita sam
	$w = world(prefs => { autoLoad => 0 });
	$w->{state}->on_drive_status(4, undef);
	is(scalar @{ $w->{lookup}{calls} }, 0, 'autoLoad 0: nema automatskog citanja');
}

# ---------- auto-rip ----------
{
	my $w = loaded(prefs => { autoRip => 1, autoRipProfile => 'secure' });
	is(scalar @{ $w->{ripper}{enq} }, 1, 'autoRip: rip posle lookup-a');
	is($w->{ripper}{enq}[0]{profile}, 'secure', 'autoRip: profil autoRipProfile');

	$w = world(prefs => { autoRip => 1 });
	$w->{ripper}{history} = [ { id => 'old', discid => $ID, result => 'ok' } ];
	$w->{state}->on_load;
	$w->{lookup}->last_cb->(mkresult());
	is(scalar @{ $w->{ripper}{enq} }, 0, 'autoRip: disk vec uspesno ripovan -> ne ponavlja');

	$w = loaded(prefs => { autoRip => 0 });
	is(scalar @{ $w->{ripper}{enq} }, 0, 'autoRip 0: nema ripa');
}

# ---------- obavestenje na kraju ripa ----------
{
	my $w = loaded();
	my $st = $w->{state};
	$w->{ripper}{history} = [ { id => 'r1', result => 'ok', album => 'A' } ];
	$st->on_rip_change;
	is(scalar @{ $w->{notes} }, 1, 'obavestenje za zavrsen rip');
	is($w->{notes}[0]{id}, 'r1', 'obavestenje: unos istorije');
	$st->on_rip_change;
	is(scalar @{ $w->{notes} }, 1, 'isti unos se ne javlja dvaput');
	unshift @{ $w->{ripper}{history} }, { id => 'r2', result => 'cancelled' };
	$st->on_rip_change;
	is(scalar @{ $w->{notes} }, 1, 'otkazan rip bez obavestenja');
	$w->{prefs}{notify} = 0;
	unshift @{ $w->{ripper}{history} }, { id => 'r3', result => 'error' };
	$st->on_rip_change;
	is(scalar @{ $w->{notes} }, 1, 'notify 0: bez obavestenja');

	# stara istorija pri startu se ne javlja
	my $w2 = world(history => [ { id => 'old', result => 'ok' } ]);
	$w2->{state}->on_rip_change;
	is(scalar @{ $w2->{notes} }, 0, 'stara istorija se ne javlja');
}

# ---------- Review Focus 4: gasenje ----------
{
	my $w = loaded();
	my $st = $w->{state};
	$st->request_play('aa:bb', 1);
	File::Path::make_path("$w->{dir}/rips/.audiocd-tmp/rip-1");
	$st->shutdown;
	is($w->{kills}, 1, 'shutdown: kill_all');
	ok($w->{cache}{clears} >= 1, 'shutdown: Cache::clear');
	ok(!-e "$w->{dir}/rips/.audiocd-tmp/rip-1", 'shutdown: tmp ripa obrisan');

	my $w2 = world();
	$w2->{state}->on_load;
	my $cb = $w2->{lookup}->last_cb;
	$w2->{state}->shutdown;
	$cb->(mkresult(cover_urls => ['http://x']));
	is(scalar @{ $w2->{covers} }, 0, 'posle shutdown-a zakasneli lookup nema efekta');
}

# ---------- disc_info ----------
{
	my $w = loaded();
	is($w->{state}->disc_info($ID)->{album}, 'The Story of Jazz', 'disc_info: trenutni disk');
	ok(!defined $w->{state}->disc_info('x' x 28), 'disc_info: nepoznat disk');
	$w->{state}->on_eject;
	is($w->{state}->disc_info($ID)->{album}, 'The Story of Jazz', 'disc_info: posle eject-a iz MetaCache-a');
}

# ---------- fix round 1: cd-info (lookup) cuva drajv ----------
{
	# load (force/offline) dok traje rip ili kes -> drive_busy, bez ioctl-a
	my $w = loaded();
	my $st = $w->{state};
	$w->{cache}->complete_all(9);
	$st->request_rip;
	my $reads = $w->{reads};
	for my $o ([ force => 1 ], [ offline => 1 ], []) {
		my ($ok, $err) = $st->on_load(@$o);
		is($err->{error}, 'drive_busy', "load (@$o) tokom ripa -> drive_busy");
	}
	is($w->{reads}, $reads, 'load tokom ripa: nema read_toc');
	is(scalar @{ $w->{lookup}{calls} }, 1, 'load tokom ripa: nema lookup-a');

	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	my ($ok, $err) = $st->on_load(force => 1);
	is($err->{error}, 'drive_busy', 'force load tokom kesiranja -> drive_busy');

	# cd-info radi: drive_busy 'lookup'; load odbijen
	$w = world();
	$st = $w->{state};
	$st->on_load(offline => 1);
	$w->{cdinfo} = 1;
	is($st->drive_busy, 'lookup', 'cd-info radi -> drive_busy lookup');
	$reads = $w->{reads};
	($ok, $err) = $st->on_load(force => 1);
	is($err->{error}, 'drive_busy', 'load dok radi cd-info -> drive_busy');
	is($w->{reads}, $reads, 'load dok radi cd-info: nema ioctl-a');
	$st->on_drive_status(1, undef);
	is($st->snapshot->{status}, 'reading', 'polling ne radi dok radi cd-info');

	# eject dok radi cd-info: ubija cd-info i ide odlozenim putem
	$st->eject;
	is($w->{lookup_kills}, 1, 'eject ubija cd-info');
	is_deeply($w->{eject_args}, [1], 'eject dok radi cd-info: odlozeno (was_busy)');
	is($st->snapshot->{status}, 'empty', 'eject: empty');

	# eject bez posla: odmah
	$w = loaded();
	$w->{state}->eject;
	is_deeply($w->{eject_args}, [0], 'eject bez posla: odmah');

	# kraj lookup-a ubija cd-info
	$w = world();
	$st = $w->{state};
	$st->on_load(offline => 1);
	$w->{cdinfo} = 1;
	$w->{lookup}->last_cb->(mkresult());
	is($w->{lookup_kills}, 1, 'lookup gotov -> cd-info ubijen');

	# Play/rip dok cd-info jos zivi: ubija ga i odbija (drajv ne sme da cita dva procesa)
	($ok, $err) = $st->request_play('aa:bb', 1);
	is($err->{error}, 'drive_busy', 'Play dok cd-info zivi -> drive_busy');
	is(scalar @{ $w->{cache}{starts} }, 0, 'kes nije pokrenut dok cd-info zivi');
	($ok, $err) = $st->request_rip;
	is($err->{error}, 'drive_busy', 'rip dok cd-info zivi -> drive_busy');
	is(scalar @{ $w->{ripper}{enq} }, 0, 'rip nije dodat dok cd-info zivi');
	ok($w->{lookup_kills} >= 2, 'zahtev ubija cd-info');
	$w->{cdinfo} = 0;
	($ok, $err) = $st->request_play('aa:bb', 1);
	ok($ok, 'Play posle cd-info radi');

	# autoRip ceka da cd-info zavrsi
	$w = world(prefs => { autoRip => 1 });
	$st = $w->{state};
	$st->on_load;
	$w->{cdinfo} = 1;
	$w->{lookup}->last_cb->(mkresult());
	is(scalar @{ $w->{ripper}{enq} }, 0, 'autoRip ceka cd-info');
	$w->{cdinfo} = 0;
	$st->on_lookup_idle;
	is(scalar @{ $w->{ripper}{enq} }, 1, 'autoRip posle cd-info');
	$st->on_lookup_idle;
	is(scalar @{ $w->{ripper}{enq} }, 1, 'autoRip samo jednom');

	# shutdown ubija cd-info
	$w = world();
	$w->{cdinfo} = 1;
	$w->{state}->shutdown;
	is($w->{lookup_kills}, 1, 'shutdown ubija cd-info');
}

# ---------- eject_event ----------
{
	# bez posla: proverava drajv
	my $w = loaded();
	my $st = $w->{state};
	$w->{drive} = [ 4, undef ];
	my ($ok, $err, $info) = $st->on_eject_event;
	is($st->snapshot->{status}, 'ready', 'eject_event, disk i dalje unutra -> ignorisan');
	$w->{drive} = [ 2, undef ];
	$st->on_eject_event;
	is($st->snapshot->{status}, 'empty', 'eject_event, nema diska -> empty');

	# tokom kesiranja: bez ioctl-a, provera odlozena
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	my $calls = $w->{drive_calls};
	$st->on_eject_event;
	is($w->{drive_calls}, $calls, 'eject_event tokom kesiranja: nema ioctl-a');
	is($st->snapshot->{status}, 'ready', 'eject_event tokom kesiranja: odlozeno');
	$w->{cache}{busy} = 0;    # pesme pukle, kes stao
	$st->on_drive_status(1, undef);
	is($st->snapshot->{status}, 'empty', 'odlozena provera: disk izvadjen -> empty');

	# odlozena provera, a u drajvu je (drugi) disk: ponovo se cita
	$w = loaded();
	$st = $w->{state};
	$st->on_drive_status(4, undef);
	$st->request_play('aa:bb', 1);
	$st->on_eject_event;
	$w->{cache}{busy} = 0;
	$w->{toc} = $TOC2;
	$st->on_drive_status(4, undef);
	isnt($st->snapshot->{discid}, $ID, 'odlozena provera: novi disk se cita');

	# rip sa eject_after: cyanrip -Q otvara fioku -> eject_event ne prekida zavrsen rip
	$w = loaded();
	$st = $w->{state};
	$st->on_drive_status(4, undef);
	$st->request_rip(eject => 1);
	$st->on_eject_event;
	is_deeply($w->{ripper}{aborts}, [], 'eject_event tokom ripa sa eject_after: rip se ne prekida');
	is($st->snapshot->{status}, 'ready', 'eject_event tokom ripa sa eject_after: stanje ostaje');
	$w->{ripper}{current} = undef;    # rip zavrsen
	$st->on_drive_status(2, undef);
	is($st->snapshot->{status}, 'empty', 'posle ripa: fioka otvorena -> empty');

	# rip bez eject_after: provera odlozena, rip se ne prekida dogadjajem
	$w = loaded();
	$st = $w->{state};
	$st->request_rip(eject => 0);
	$calls = $w->{drive_calls};
	$st->on_eject_event;
	is_deeply($w->{ripper}{aborts}, [], 'eject_event tokom ripa: bez prekida (cyanrip sam pada ako je disk izvadjen)');
	is($w->{drive_calls}, $calls, 'eject_event tokom ripa: nema ioctl-a');
}

# ---------- sitnice ----------
{
	# posle on_eject novi DISC_OK cita disk
	my $w = loaded();
	my $st = $w->{state};
	$st->on_drive_status(4, undef);
	$st->on_eject;
	my $r0 = $w->{reads};
	$st->on_drive_status(4, undef);
	is($w->{reads}, $r0 + 1, 'posle eject-a DISC_OK ponovo cita disk');
	is($st->snapshot->{discid}, $ID, 'posle eject-a disk ponovo ucitan');

	# edit: n mora biti broj (bez upozorenja)
	$w = loaded();
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my ($ok) = $w->{state}->edit({ tracks => [ { n => 'abc', title => 'X' }, { n => '2', title => 'Dva' } ] });
	ok($ok, 'edit sa losim n');
	is($w->{state}->snapshot->{metadata}{tracks}[1]{title}, 'Dva', 'edit: ispravan n primenjen');
	is_deeply(\@warn, [], 'edit: bez upozorenja za n koji nije broj');

	# rip folder sa ..
	$w = loaded();
	my ($ok2, $err) = $w->{state}->request_rip(dir => '/mnt/../etc');
	is($err->{error}, 'bad_args', 'rip: folder sa .. odbijen');
	($ok2, $err) = $w->{state}->request_rip(dir => '/mnt/x/..');
	is($err->{error}, 'bad_args', 'rip: folder koji se zavrsava sa .. odbijen');
}

done_testing;
