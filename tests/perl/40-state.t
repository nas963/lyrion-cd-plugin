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
	sub new { bless { discid => undef, done => {}, failed => {}, busy => 0, starts => [], stops => 0, clears => 0, forgets => 0 }, shift }
	sub start {
		my ($s, $disc, $toc, $n, %o) = @_;
		push @{ $s->{starts} }, { disc => $disc, toc => $toc, n => $n, opt => {%o} };
		return 0 if $s->{fail};
		if (!defined $s->{discid} || $s->{discid} ne $disc->{discid}) { $s->{done} = {} }
		$s->{discid} = $disc->{discid};
		$s->{busy}   = 1;
		$s->{started} = 1;
		return 1;
	}
	sub stop   { my $s = shift; $s->{stops}++; $s->{busy} = 0 }
	sub clear  { my $s = shift; $s->{clears}++; $s->{busy} = 0; $s->{discid} = undef; $s->{done} = {}; $s->{started} = 0 }
	sub busy   { $_[0]{busy} }
	sub resumable { my ($s, $id) = @_; return defined $s->{discid} && $s->{discid} eq $id && $s->{started} && !$s->{busy} && !$s->{complete} ? 1 : 0 }
	sub forget_failed { my $s = shift; $s->{forgets}++; $s->{failed} = {} }
	sub last_error { $_[0]{fail} }
	sub discid { $_[0]{discid} }
	sub ready  { my ($s, $n) = @_; $s->{done}{$n} ? 1 : 0 }
	sub status { my $s = shift; { done => [ sort { $a <=> $b } keys %{ $s->{done} } ], failed => [ sort { $a <=> $b } keys %{ $s->{failed} } ], current => undef, percent => 0 } }
	sub complete_all { my ($s, $n) = @_; $s->{done} = { map { $_ => 1 } 1 .. $n }; $s->{busy} = 0; $s->{complete} = 1 }
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
	sub shutdown  { my ($s, $r) = @_; push @{ $s->{shutdowns} }, $r; push @{ $s->{order} }, 'ripper'; 1 }
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
		procs   => 0,
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
		# asinhroni drajv (pomocni proces): bez $w->{async} odgovor stize odmah (sinhrono),
		# sa njim se callback-ovi cuvaju u toc_cbs / status_cbs i test ih zove kad hoce
		request_toc => sub {
			my ($dev, $cb) = @_;
			$w->{reads}++;
			return push @{ $w->{toc_cbs} }, $cb if $w->{async};
			return $w->{toc_err} ? $cb->(undef, $w->{toc_err}) : $cb->($w->{toc}, undef);
		},
		lookup      => $w->{lookup},
		metacache   => $w->{meta},
		cache       => $w->{cache},
		ripper      => $w->{ripper},
		rips_dir    => sub { "$w->{dir}/rips" },
		media_dirs  => sub { $o{media} // ['/mnt'] },
		fetch_cover => sub { push @{ $w->{covers} }, [@_] },
		play        => sub { push @{ $w->{plays} }, [@_]; return (1, undef) },
		eject       => sub { $w->{ejects}++; push @{ $w->{eject_args} }, $_[0]; $w->{eject_done} = $_[1] },
		missing_tools => sub { @{ $w->{missing} } },
		notify      => sub { push @{ $w->{notes} }, $_[0] },
		kill_all    => sub { $w->{kills}++; push @{ $w->{ripper}{order} }, 'kill_all' },
		request_status => sub {
			my ($dev, $cb) = @_;
			$w->{drive_calls}++;
			return push @{ $w->{status_cbs} }, $cb if $w->{async};
			$cb->(@{ $w->{drive} });
		},
		lookup_busy => sub { $w->{cdinfo} },
		drive_procs => sub { $w->{procs} },
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
	is($w->{state}->snapshot->{cover_url}, "/plugins/AudioCD/cover/cd.$ID.jpg", 'cover_url posle preuzimanja');
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

	# rucna izmena, pa izbor izdanja: poslednji izbor korisnika pobedjuje (i posle ponovnog ucitavanja)
	($ok, $err) = $st->select_release(1);
	ok($ok, 'select_release posle edit-a');
	is($st->snapshot->{metadata}{album}, 'Drugo izdanje 2', 'select_release: izabrano izdanje');
	is($w->{meta}->get($ID)->{disc}{album}, 'Drugo izdanje 2', 'select_release posle edit-a: kes ima izdanje, ne rucnu izmenu');
	is($w->{meta}->get($ID)->{disc}{source}, 'musicbrainz', 'select_release brise rucnu izmenu');
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

	# dir: samo ispod foldera za rip-ove ili LMS muzickog foldera
	$w = loaded();
	($ok, $err) = $w->{state}->request_rip(dir => '/etc/cron.d');
	ok(!$ok, 'rip: folder van rips/muzickih foldera odbijen');
	is($err->{error}, 'rip_dir_outside', 'rip: rip_dir_outside');
	is($err->{field}, 'dir', 'rip: polje dir');
	($ok, $err) = $w->{state}->request_rip(dir => '/mntx/a');
	is($err->{error}, 'rip_dir_outside', 'rip: /mntx nije ispod /mnt');
	is(scalar @{ $w->{ripper}{enq} }, 0, 'rip: nista u redu');
	($ok, $err) = $w->{state}->request_rip(dir => "$w->{dir}/rips/Posebno");
	ok($ok, 'rip: podfolder foldera za rip-ove radi') or diag explain $err;
	$w = loaded(media => []);
	($ok, $err) = $w->{state}->request_rip(dir => '/mnt/x');
	is($err->{error}, 'rip_dir_outside', 'rip: bez muzickih foldera samo rips folder');

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
	is($w->{cache}{clears}, 0, 'eject: Cache::clear se NE zove (kes ostaje)');
	is($w->{cache}->discid, $ID, 'eject: kes diska ostaje');
	is($s->{cache}{discid}, $ID, 'eject: snapshot nosi cache.discid');

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

# ---------- kes ostaje posle izbacivanja ----------
{
	# eject komanda: izvlacenje se zaustavlja, kes se ne brise
	my $w = loaded();
	my $st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}{done} = { 1 => 1 };
	$st->eject;
	is($w->{cache}{clears}, 0, 'eject komanda: kes nije obrisan');
	ok($w->{cache}{stops} >= 1, 'eject komanda: izvlacenje zaustavljeno');
	my $s = $st->snapshot;
	is($s->{status}, 'empty', 'eject komanda: empty');
	is($s->{cache}{discid}, $ID, 'eject komanda: cache.discid u snapshot-u');
	is_deeply($s->{cache}{done}, [1], 'eject komanda: done lista u snapshot-u');

	# eject_event i polling: isto
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}{busy} = 0;
	$w->{drive} = [ 2, undef ];
	$st->on_eject_event;
	is($w->{cache}{clears}, 0, 'eject_event: kes nije obrisan');
	is($w->{cache}->discid, $ID, 'eject_event: kes diska ostaje');
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}{busy} = 0;
	$st->on_drive_status(2, undef);
	is($w->{cache}{clears}, 0, 'polling bez diska: kes nije obrisan');

	# isti disk ponovo: nastavlja izvlacenje preostalih pesama, bez brisanja
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}{done} = { 1 => 1 };
	$st->eject;
	$w->{eject_done}->();
	my $starts = scalar @{ $w->{cache}{starts} };
	$st->on_drive_status(4, undef);
	$w->{lookup}->last_cb->(mkresult());
	is($w->{cache}{clears}, 0, 'isti disk ponovo: kes nije obrisan');
	is(scalar @{ $w->{cache}{starts} }, $starts + 1, 'isti disk ponovo: izvlacenje nastavljeno');
	is_deeply($w->{cache}{done}, { 1 => 1 }, 'isti disk ponovo: gotove pesme ostaju');

	# isti disk, kes kompletan: nema novog start-a
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}->complete_all(9);
	$st->on_eject;
	my $s0 = scalar @{ $w->{cache}{starts} };
	$st->on_load;
	$w->{lookup}->last_cb->(mkresult());
	is(scalar @{ $w->{cache}{starts} }, $s0, 'isti disk ponovo sa kompletnim kesom: nema novog start-a');

	# drugi disk: kes starog se brise tek tada
	$w = loaded();
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$st->eject;
	$w->{eject_done}->();
	is($w->{cache}{clears}, 0, 'drugi disk: pre ubacivanja kes jos postoji');
	$w->{toc} = $TOC2;
	$st->on_load;
	ok($w->{cache}{clears} >= 1, 'drugi disk: kes starog diska obrisan');
	ok(!defined $w->{cache}->discid, 'drugi disk: nema starog discid-a u kesu');
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
	is_deeply($w->{ripper}{shutdowns}, ['shutdown'], 'shutdown: istorija ripa pre kill_all');
	is_deeply($w->{ripper}{order}, [qw(ripper kill_all)], 'shutdown: ripper pa kill_all');
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

# ---------- fix round 2: eject_pending, procesi na drajvu, recheck bez polling-a ----------
{
	# Eject tokom ripa: dok odlozeni CDROMEJECT ne zavrsi, polling/load/autoRip ne vracaju disk
	my $w = loaded(prefs => { autoRip => 1 });
	my $st = $w->{state};
	$st->on_drive_status(4, undef);
	is(scalar @{ $w->{ripper}{enq} }, 1, 'autoRip pokrenuo rip');
	$st->eject;
	is_deeply($w->{eject_args}, [1], 'eject tokom ripa: odlozen');
	is(ref $w->{eject_done}, 'CODE', 'eject dobija callback za kraj');
	$w->{ripper}{current} = undef;    # cyanrip umro, drajv "slobodan" pre CDROMEJECT-a
	my $reads = $w->{reads};
	$st->on_drive_status(4, undef);
	is($w->{reads}, $reads, 'eject_pending: polling ne cita disk');
	is($st->snapshot->{status}, 'empty', 'eject_pending: ostaje empty');
	my ($ok, $err) = $st->on_load(force => 1);
	is($err->{error}, 'eject_pending', 'eject_pending: load odbijen');
	is($w->{reads}, $reads, 'eject_pending: load bez ioctl-a');
	is(scalar @{ $w->{ripper}{enq} }, 1, 'eject_pending: otkazan rip se ne pokrece ponovo');
	$w->{eject_done}->();
	$st->on_drive_status(2, undef);    # fioka otvorena
	is($st->snapshot->{status}, 'empty', 'posle eject-a: empty');
	$st->on_drive_status(4, undef);    # novi disk
	is($w->{reads}, $reads + 1, 'posle zavrsenog eject-a disk se ponovo cita');

	# eject bez posla: callback takodje gasi eject_pending
	$w = loaded();
	$w->{state}->eject;
	is_deeply($w->{eject_args}, [0], 'eject bez posla: odmah');
	$w->{eject_done}->();
	($ok, $err) = $w->{state}->on_load;
	ok($ok, 'posle eject callback-a load radi');
}

{
	# proces na drajvu jos umire (npr. ubijen cd-paranoia): drajv zauzet, nema ioctl-a
	my $w = loaded();
	my $st = $w->{state};
	$w->{procs} = 1;
	is($st->drive_busy, 'process', 'ziv proces na drajvu -> drive_busy process');
	my $calls = $w->{drive_calls};
	$st->on_eject_event;
	is($w->{drive_calls}, $calls, 'eject_event dok proces umire: nema ioctl-a');
	my $reads = $w->{reads};
	my ($ok, $err) = $st->on_load(force => 1);
	is($err->{error}, 'drive_busy', 'load dok proces umire -> drive_busy');
	is($w->{reads}, $reads, 'load dok proces umire: nema ioctl-a');
	$w->{procs} = 0;
	$w->{drive} = [ 2, undef ];
	$st->on_jobs_changed;
	is($st->snapshot->{status}, 'empty', 'odlozena provera posle smrti procesa');
}

{
	# odlozena provera radi i bez polling-a: okida je kraj posla (on_jobs_changed)
	my $w = loaded(prefs => { polling => 0 });
	my $st = $w->{state};
	$st->request_play('aa:bb', 1);
	$st->on_eject_event;
	my $calls = $w->{drive_calls};
	$w->{drive} = [ 2, undef ];
	$st->on_jobs_changed;
	is($w->{drive_calls}, $calls, 'on_jobs_changed dok kes radi: nista');
	is($st->snapshot->{status}, 'ready', 'kes jos radi: stanje ostaje');
	$w->{cache}{busy} = 0;
	$st->on_jobs_changed;
	is($w->{drive_calls}, $calls + 1, 'kraj posla: jedna provera drajva');
	is($st->snapshot->{status}, 'empty', 'kraj posla: disk izvadjen -> empty');
	$st->on_jobs_changed;
	is($w->{drive_calls}, $calls + 1, 'provera samo jednom');

	# bez odlozene provere on_jobs_changed ne dira drajv
	$w = loaded();
	$calls = $w->{drive_calls};
	$w->{state}->on_jobs_changed;
	is($w->{drive_calls}, $calls, 'bez odlozene provere: nema ioctl-a');
}

# ---------- M5: Play dok proces na drajvu jos umire ----------
{
	my $w = loaded();
	$w->{procs} = 1;
	is($w->{state}->drive_busy, 'process', 'drive_busy process');
	my ($ok, $err) = $w->{state}->request_play('aa:bb', 1);
	ok(!$ok, 'Play dok proces umire odbijen');
	is($err->{error}, 'drive_busy', 'Play dok proces umire: drive_busy');
	is($err->{busy}, 'process', 'Play dok proces umire: busy process');
	is(scalar @{ $w->{cache}{starts} }, 0, 'kes nije pokrenut dok proces umire');
	is(scalar @{ $w->{plays} }, 0, 'plejer nije dirnut');
	$w->{procs} = 0;
	($ok, $err) = $w->{state}->request_play('aa:bb', 1);
	ok($ok, 'Play posle procesa radi');
}

# ---------- request_cache: audiocd:// pesma pustena bez audiocd play (lista posle restarta, Add, ...) ----------
{
	my $w = loaded();
	my $st = $w->{state};
	my ($ok, $err) = $st->request_cache($ID, 4);
	ok($ok, 'request_cache: disk u drajvu') or diag explain $err;
	is(scalar @{ $w->{cache}{starts} }, 1, 'request_cache pokrece kes');
	is($w->{cache}{starts}[0]{n}, 4, 'request_cache: od trazene pesme');
	is(scalar @{ $w->{plays} }, 0, 'request_cache ne dira listu plejera');

	# kes kompletan: nista novo
	$w->{cache}->complete_all(9);
	($ok, $err) = $st->request_cache($ID, 2);
	ok($ok, 'request_cache: kes kompletan -> ok');
	is(scalar @{ $w->{cache}{starts} }, 1, 'kompletan kes se ne pokrece ponovo');

	# drugi disk u drajvu: brzo odbijanje
	($ok, $err) = $st->request_cache('xBFBpdDGyUnu4ofAwN5ZrxozKwM-', 1);
	is($err->{error}, 'wrong_disc', 'drugi disk -> wrong_disc');
	($ok, $err) = $st->request_cache($ID, 42);
	is($err->{error}, 'bad_track', 'nepostojeca pesma -> bad_track');
}
{
	# isto pravilo za zauzet drajv kao request_play
	my $w = loaded();
	my $st = $w->{state};
	$st->request_rip(profile => 'fast');
	my ($ok, $err) = $st->request_cache($ID, 1);
	is($err->{error}, 'drive_busy', 'request_cache tokom ripa -> drive_busy');
	is($err->{busy}, 'rip', 'request_cache tokom ripa: busy rip');
	is(scalar @{ $w->{cache}{starts} }, 0, 'kes nije pokrenut tokom ripa');

	$w = loaded();
	$w->{cdinfo} = 1;
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{error}, 'drive_busy', 'request_cache dok cd-info zivi -> drive_busy');
	is($err->{busy}, 'lookup', 'request_cache: busy lookup');
	ok($w->{lookup_kills} >= 1, 'request_cache ubija cd-info');

	$w = loaded();
	$w->{procs} = 1;
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{busy}, 'process', 'request_cache dok proces umire: busy process');

	$w = loaded(missing => ['flac']);
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{error}, 'missing_tools', 'request_cache bez flac-a');

	# disk se jos cita (lookup u toku): not_ready (ProtocolHandler ponavlja)
	$w = world();
	$w->{state}->on_load;
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{error}, 'not_ready', 'disk se cita -> not_ready');

	# prazan drajv
	$w = world();
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{error}, 'wrong_disc', 'prazan drajv -> wrong_disc');
}

# ---------- kes bez mesta: jasna greska (cache_no_space) ----------
{
	my $w = loaded();
	$w->{cache}{fail} = { error => 'cache_no_space', needed => 123 };
	my ($ok, $err) = $w->{state}->request_play('aa:bb', 1);
	ok(!$ok, 'Play bez mesta za kes odbijen');
	is($err->{error}, 'cache_no_space', 'Play: cache_no_space');
	is($err->{needed}, 123, 'Play: potrebno');
	is(scalar @{ $w->{plays} }, 0, 'plejer nije dirnut');
	($ok, $err) = $w->{state}->request_cache($ID, 1);
	is($err->{error}, 'cache_no_space', 'request_cache: cache_no_space');
}

# ---------- 1.0.1: drajv u zasebnom procesu, TOC i status stizu asinhrono ----------
{
	# load odmah odgovara (started), stanje 'reading'; rezultat stize kasnije
	my $w = world();
	$w->{async} = 1;
	my $st = $w->{state};
	my ($ok, $err, $what) = $st->on_load;
	ok($ok, 'async load: ok');
	is($what, 'started', 'async load: started');
	is($st->snapshot->{status}, 'reading', 'async load: odmah reading');
	is(scalar @{ $w->{toc_cbs} }, 1, 'async load: jedan TOC zahtev');
	is(scalar @{ $w->{lookup}{calls} }, 0, 'async load: lookup tek posle TOC-a');
	$w->{toc_cbs}[0]->($TOC, undef);
	is($st->snapshot->{discid}, $ID, 'TOC stigao: discid');
	is(scalar @{ $w->{lookup}{calls} }, 1, 'TOC stigao: lookup');

	# zakasneli TOC zamenjenog zahteva se ignorise
	$w = world();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_load;
	$st->on_load(force => 1);
	is(scalar @{ $w->{toc_cbs} }, 2, 'dva TOC zahteva');
	$w->{toc_cbs}[1]->($TOC2, undef);
	my $id2 = $st->snapshot->{discid};
	ok(defined $id2 && $id2 ne $ID, 'noviji zahtev primenjen');
	$w->{toc_cbs}[0]->($TOC, undef);
	is($st->snapshot->{discid}, $id2, 'zakasneli TOC starog zahteva ignorisan');
	is(scalar @{ $w->{lookup}{calls} }, 1, 'zakasneli TOC: nema drugog lookup-a');
	$w->{toc_cbs}[1]->($TOC, undef);
	is(scalar @{ $w->{lookup}{calls} }, 1, 'ponovljen odgovor istog zahteva ignorisan');

	# izbacivanje dok TOC putuje: rezultat se ignorise
	$w = world();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_load;
	$st->on_eject;
	is($st->snapshot->{status}, 'empty', 'eject dok se cita TOC: empty');
	$w->{toc_cbs}[0]->($TOC, undef);
	is($st->snapshot->{status}, 'empty', 'TOC posle eject-a ignorisan');
	ok(!defined $st->snapshot->{discid}, 'TOC posle eject-a: nema discid');

	# polling: fioka otvorena dok TOC putuje -> empty, TOC se ignorise
	$w = world();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_drive_status(4, undef);
	is($st->snapshot->{status}, 'reading', 'DISC_OK: citanje');
	$st->on_drive_status(2, undef);
	is($st->snapshot->{status}, 'empty', 'fioka otvorena dok se cita: empty');
	$w->{toc_cbs}[0]->($TOC, undef);
	is($st->snapshot->{status}, 'empty', 'zakasneli TOC posle otvorene fioke ignorisan');

	# zauzet drajv: nema TOC zahteva
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	($ok, $err) = $st->on_load(force => 1);
	is($err->{error}, 'drive_busy', 'busy: load odbijen');
	ok(!$w->{toc_cbs}, 'busy: TOC zahtev se ne salje');

	# offline load: lookup dobija offline kad TOC stigne
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	($ok, $err, $what) = $st->on_load(offline => 1);
	is($what, 'started', 'offline: started');
	is($st->snapshot->{status}, 'reading', 'offline: odmah reading');
	ok(!$st->_ready, 'offline: disk nije spreman dok se cita');
	$w->{toc_cbs}[0]->($TOC, undef);
	is(scalar @{ $w->{lookup}{calls} }, 2, 'offline: novi lookup');
	ok($w->{lookup}{calls}[-1]{opt}{offline}, 'offline: lookup offline');

	# force load istog diska: novi lookup
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_load(force => 1);
	is($st->snapshot->{status}, 'reading', 'force: odmah reading');
	$w->{toc_cbs}[0]->($TOC, undef);
	is(scalar @{ $w->{lookup}{calls} }, 2, 'force: novi lookup');
	is($st->snapshot->{discid}, $ID, 'force: isti disk');

	# load bez force-a na spremnom disku: stanje ostaje ready dok TOC putuje, isti disk -> nista
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_load;
	is($st->snapshot->{status}, 'ready', 'load bez force-a: ready dok se cita TOC');
	$w->{toc_cbs}[0]->($TOC, undef);
	is($st->snapshot->{status}, 'ready', 'isti disk: ready');
	is(scalar @{ $w->{lookup}{calls} }, 1, 'isti disk: nema novog lookup-a');

	# pomocnik ne radi: greska 'helper', drajv nije "prazan"
	$w = world(toc_err => 'helper');
	$w->{state}->on_load;
	is($w->{state}->snapshot->{status}, 'error', 'helper greska -> error');
	is($w->{state}->snapshot->{errors}[0]{code}, 'helper', 'helper greska: kod');
	# izuzetak u request_toc: io greska, bez visenja u 'reading'
	$w = world();
	$w->{state}{d}{request_toc} = sub { die "puklo\n" };
	$w->{state}->on_load;
	is($w->{state}->snapshot->{status}, 'error', 'request_toc puca: error');
}

{
	# status bez informacije (pomocnik pao, rok) ne znaci da je disk izvadjen
	my $w = loaded();
	my $st = $w->{state};
	$st->on_drive_status(4, undef);
	$st->on_drive_status(undef, 'helper');
	is($st->snapshot->{status}, 'ready', 'helper greska u statusu: disk ostaje');
	$st->on_drive_status(undef, 'drive_timeout');
	is($st->snapshot->{status}, 'ready', 'drive_timeout u statusu: disk ostaje');

	# eject_event asinhrono: odgovor 'checking', provera stize kasnije
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	my ($ok, $err, $what) = $st->on_eject_event;
	is($what, 'checking', 'eject_event: provera u toku');
	is($st->snapshot->{status}, 'ready', 'eject_event: stanje ostaje dok provera traje');
	$w->{status_cbs}[0]->(4, undef);
	is($st->snapshot->{status}, 'ready', 'eject_event: disk unutra -> ignorisan');
	$st->on_eject_event;
	$w->{status_cbs}[1]->(2, undef);
	is($st->snapshot->{status}, 'empty', 'eject_event: nema diska -> empty');

	# eject_event: posao poceo dok provera putuje -> provera se odlaze (recheck)
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_eject_event;
	$st->request_play('aa:bb', 1);
	$w->{status_cbs}[0]->(2, undef);
	is($st->snapshot->{status}, 'ready', 'provera stigla tokom posla: bez izbacivanja');
	$w->{cache}{busy} = 0;
	$st->on_jobs_changed;
	is(scalar @{ $w->{status_cbs} }, 2, 'kraj posla: nova provera');
	$w->{status_cbs}[1]->(2, undef);
	is($st->snapshot->{status}, 'empty', 'odlozena provera: empty');

	# on_jobs_changed: najvise jedna provera u letu
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->request_play('aa:bb', 1);
	$st->on_eject_event;
	$w->{cache}{busy} = 0;
	$st->on_jobs_changed;
	$st->on_jobs_changed;
	is(scalar @{ $w->{status_cbs} || [] }, 1, 'recheck: jedna provera u letu');
	$w->{status_cbs}[0]->(undef, 'helper');
	is($st->snapshot->{status}, 'ready', 'recheck bez informacije: disk ostaje');
	$st->on_jobs_changed;
	is(scalar @{ $w->{status_cbs} }, 2, 'recheck ostaje posle helper greske: nova provera');

	# eject_pending je vidljiv Plugin-u (pomocnik se pauzira dok traje izbacivanje)
	$w = loaded();
	ok(!$w->{state}->eject_pending, 'eject_pending 0');
	$w->{state}->eject;
	ok($w->{state}->eject_pending, 'eject_pending 1 posle eject-a');
	$w->{eject_done}->();
	ok(!$w->{state}->eject_pending, 'eject_pending 0 posle izbacivanja');
}

{
	# review 1: TOC greska helper/drive_timeout -> sledeci DISC_OK (pomocnik restartovan) ponovo cita
	my $w = world();
	$w->{async} = 1;
	my $st = $w->{state};
	$st->on_drive_status(4, undef);
	is($w->{reads}, 1, 'autoLoad: TOC zahtev');
	$w->{toc_cbs}[0]->(undef, 'helper');
	is($st->snapshot->{status}, 'error', 'TOC helper greska: error');
	$st->on_drive_status(4, undef);    # restartovan pomocnik ponovo javlja status
	is($w->{reads}, 2, 'posle helper greske DISC_OK ponovo trazi TOC');
	$w->{toc_cbs}[1]->($TOC, undef);
	is($st->snapshot->{discid}, $ID, 'disk ucitan posle restarta pomocnika');
	$w = world();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_drive_status(4, undef);
	$w->{toc_cbs}[0]->(undef, 'drive_timeout');
	$st->on_drive_status(4, undef);
	is($w->{reads}, 2, 'posle drive_timeout DISC_OK ponovo trazi TOC');

	# spreman disk + load bez force-a koji pukne na helper/drive_timeout: disk ostaje
	for my $e (qw(helper drive_timeout)) {
		$w = loaded();
		$w->{async} = 1;
		$st = $w->{state};
		$st->on_load;
		$w->{toc_cbs}[0]->(undef, $e);
		is($st->snapshot->{status}, 'ready', "ready + load ($e): disk ostaje");
		is($st->snapshot->{discid}, $ID, "ready + load ($e): discid ostaje");
		is($w->{cache}{stops}, 0, "ready + load ($e): kes nije zaustavljen");
	}
	# force load sa helper greskom: greska se prikazuje
	$w = loaded();
	$w->{async} = 1;
	$w->{state}->on_load(force => 1);
	$w->{toc_cbs}[0]->(undef, 'helper');
	is($w->{state}->snapshot->{status}, 'error', 'force load + helper greska: error');

	# review 5: sinhrona greska zahteva -> load vraca gresku (CLI ok:0)
	$w = world(toc_err => 'helper');
	my ($ok, $err) = $w->{state}->on_load;
	ok(!$ok, 'sinhrona helper greska: load nije ok');
	is($err->{error}, 'helper', 'sinhrona helper greska: kod');
	$w = world();
	$w->{state}{d}{request_toc} = sub { die "puklo\n" };
	($ok, $err) = $w->{state}->on_load;
	is($err->{error}, 'io', 'request_toc puca: load vraca io');
	$w = world();
	($ok, $err, my $what) = $w->{state}->on_load;
	ok($ok, 'sinhroni uspeh: ok');

	# review 6: gasenje -> zakasneli helper odgovori ne prave prolazno 'error' stanje
	$w = loaded();
	$w->{async} = 1;
	$st = $w->{state};
	$st->on_load(force => 1);
	$st->begin_shutdown;
	$w->{toc_cbs}[0]->(undef, 'helper');
	isnt($st->snapshot->{status}, 'error', 'gasenje: helper greska ne menja stanje u error');
	$st->on_drive_status(2, undef);
	isnt($st->snapshot->{status}, 'empty', 'gasenje: status dogadjaj se ignorise');
	$st->shutdown;
	is($w->{kills}, 1, 'shutdown posle begin_shutdown i dalje radi');
}

{
	# nastavak kesa: samo nedostajuce pesme (resume => 1), neuspele se preskacu
	my $w = loaded();
	my $st = $w->{state};
	$st->request_play('aa:bb', 1);
	$w->{cache}{done} = { 1 => 1, 3 => 1 };
	$st->eject;
	$w->{eject_done}->();
	ok($w->{cache}{forgets} >= 1, 'izbacivanje: Cache::forget_failed (greske zbog izvadjenog diska)');
	$w->{cache}{failed} = { 2 => 1 };    # npr. los sektor posle ponovnog ubacivanja
	my $s0 = @{ $w->{cache}{starts} };
	$st->on_drive_status(4, undef);
	$w->{lookup}->last_cb->(mkresult());
	is(scalar @{ $w->{cache}{starts} }, $s0 + 1, 'nastavak pokrenut');
	is($w->{cache}{starts}[-1]{n}, 4, 'nastavak: prva pesma koja nije gotova ni neuspela');
	ok($w->{cache}{starts}[-1]{opt}{resume}, 'nastavak: resume => 1');
	# eksplicitan Play: bez resume (Cache ponavlja neuspele)
	$w->{cache}{busy} = 0;
	$st->request_play('aa:bb', 2);
	ok(!$w->{cache}{starts}[-1]{opt}{resume}, 'Play: bez resume');
}

done_testing;
