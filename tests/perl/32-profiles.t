use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Profiles') }

my $P = 'Plugins::AudioCD::Profiles';
sub rip_argv    { $P->can('rip_argv')->(@_) }
sub parse_prog  { $P->can('parse_progress')->(@_) }
sub summary     { $P->can('summary')->(@_) }

is_deeply(\@Plugins::AudioCD::Profiles::NAMES, [qw(fast balanced secure)], 'NAMES');

my $disc = {
	discid => 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', cddbid => '6a0a1f09', source => 'musicbrainz',
	release_id => '11111111-1111-1111-1111-111111111111',
	release_group_id => '33333333-3333-3333-3333-333333333333',
	artist => 'Bobby McFerrin', album_artist_id => '44444444-4444-4444-4444-444444444444',
	album => 'The Story: Of Jazz', year => '1991', disc_number => 1, disc_total => 2,
	tracks => [
		{ n => 1, title => 'Moon: Ćao=x', artist => 'Bobby McFerrin',
		  artist_id => '55555555-5555-5555-5555-555555555555',
		  recording_id => '22222222-2222-2222-2222-222222222222' },
		{ n => 2, title => "It's a \\ test", artist => 'Čajkovski: Ž' },
	],
};

my %base = (cyanrip => '/usr/bin/cyanrip', device => '/dev/cdrom', flac_level => 5,
	out_dir => '/tmp/out dir', disc => $disc);

sub opt_val {    # vrednost opcije $o u argv (prva)
	my ($o, @a) = @_;
	for my $i (0 .. $#a - 1) { return $a[ $i + 1 ] if $a[$i] eq $o }
	return undef;
}
sub has_opt { my ($o, @a) = @_; return scalar grep { $_ eq $o } @a }

# ---- prefiks ----
my @f = rip_argv(%base, profile => 'fast');
is_deeply([ @f[ 0 .. 3 ] ], [qw(nice -n 10 ionice)], 'argv pocinje nice/ionice') if $f[3] eq 'ionice';
my ($ci) = grep { $f[$_] eq '/usr/bin/cyanrip' } 0 .. $#f;
ok(defined $ci && $ci >= 3, 'cyanrip posle nice prefiksa');
is_deeply([ @f[ 0 .. 2 ] ], [qw(nice -n 10)], 'nice -n 10');

# ---- zajednicke opcije ----
is(opt_val('-d', @f), '/dev/cdrom', 'uredjaj');
is(opt_val('-o', @f), 'flac', 'izlaz flac');
is(opt_val('-D', @f), '/tmp/out dir', 'izlazni folder kao jedan argument');
is(opt_val('-F', @f), '{track}', 'sema imena fajla je samo broj pesme');
ok(has_opt('-N', @f), 'bez cyanrip MusicBrainz lookup-a');
ok(!has_opt('-Q', @f), 'nema izbacivanja diska');
ok(!has_opt('-L', @f), 'flac_level se ne prosledjuje (cyanrip uvek koristi maksimum)');
is(opt_val('-s', @f), 0, 'ofset 0 kad nije zadat (cyanrip ga zahteva)');
is(opt_val('-s', rip_argv(%base, profile => 'fast', offset => 667)), 667, 'ofset iz podesavanja');
is(opt_val('-s', rip_argv(%base, profile => 'fast', offset => -6)), -6, 'negativan ofset');

# ---- profili ----
is(opt_val('-P', @f), 0, 'fast: paranoia 0');
ok(!has_opt('-S', @f), 'fast: bez -S');
ok(!has_opt('-r', @f), 'fast: bez ponavljanja');

my @b = rip_argv(%base, profile => 'balanced');
ok(!has_opt('-P', @b), 'balanced: podrazumevana paranoia');
is(opt_val('-r', @b), 1, 'balanced: -r 1');
ok(!has_opt('-S', @b), 'balanced: bez -S');

my @s = rip_argv(%base, profile => 'secure');
is(opt_val('-P', @s), 3, 'secure: puna paranoia');
is(opt_val('-r', @s), 5, 'secure: -r 5');
is(opt_val('-S', @s), 8, 'secure: -S 8');

for my $p (@Plugins::AudioCD::Profiles::NAMES) {
	is(opt_val('-S', rip_argv(%base, profile => $p, quiet_speed => 4)), 4, "quiet_speed 4 u profilu $p");
}
is(opt_val('-S', rip_argv(%base, profile => 'secure', quiet_speed => 4)), 4, 'quiet_speed pobedjuje 8x');

my @u = rip_argv(%base, profile => 'nepoznat');
is(opt_val('-r', @u), 1, 'nepoznat profil -> balanced');

# ---- tagovi ----
my $album_tags = opt_val('-a', @f);
my @tracks_t   = map { $f[$_ + 1] } grep { $f[$_] eq '-t' } 0 .. $#f - 1;
is(scalar @tracks_t, 2, 'po jedan -t za svaku pesmu');

# razlaz po ':' koji nije escape-ovan i po '=' prvom koji nije escape-ovan
sub parse_tags {
	my ($s) = @_;
	my @pairs = split /(?<!\\):/, $s;    # (ne rade \\: na kraju vrednosti, vidi escape test)
	my %h;
	for my $p (@pairs) {
		my ($k, $v) = split /=/, $p, 2;
		$v =~ s/\\(.)/$1/g if defined $v;
		$h{$k} = $v;
	}
	return \%h;
}
my $at = parse_tags($album_tags);
is($at->{album}, 'The Story: Of Jazz', 'album sa ":" (escape)');
is($at->{album_artist}, 'Bobby McFerrin', 'album_artist');
is($at->{date}, '1991', 'date');
is($at->{disc}, 1, 'disc');
is($at->{totaldiscs}, 2, 'totaldiscs');
is($at->{musicbrainz_albumid}, $disc->{release_id}, 'musicbrainz_albumid');
is($at->{musicbrainz_releasegroupid}, $disc->{release_group_id}, 'musicbrainz_releasegroupid');
is($at->{musicbrainz_albumartistid}, $disc->{album_artist_id}, 'musicbrainz_albumartistid');
is($at->{discid}, $disc->{discid}, 'discid (cyanrip ime za MUSICBRAINZ_DISCID)');
is($at->{musicbrainz_discid}, $disc->{discid}, 'musicbrainz_discid');

# Prva dva segmenta moraju imati kljuc i ne smeju sadrzati ':' (cyanrip pre-parser ne poznaje escape)
like($album_tags, qr/\A[a-z_]+=[^:\\]*:[a-z_]+=[^:\\]*:/, 'album: prva dva segmenta bez ":" u vrednosti');
like($tracks_t[0], qr/\A1=[a-z_]+=[^:\\]*:[a-z_]+=[^:\\]*:/, 'pesma: prva dva segmenta bez ":" u vrednosti');

my ($n1) = $tracks_t[0] =~ /\A(\d+)=/;
is($n1, 1, 'broj pesme ispred');
(my $t1 = $tracks_t[0]) =~ s/\A1=//;
my $t1h = parse_tags($t1);
is($t1h->{title}, 'Moon: Ćao=x', 'naslov sa ":", "=" i ne-ASCII');
is($t1h->{artist}, 'Bobby McFerrin', 'artist pesme');
is($t1h->{track}, 1, 'track');
is($t1h->{tracktotal}, 2, 'tracktotal');
is($t1h->{musicbrainz_trackid}, '22222222-2222-2222-2222-222222222222', 'musicbrainz_trackid');
is($t1h->{musicbrainz_artistid}, '55555555-5555-5555-5555-555555555555', 'musicbrainz_artistid');
like($tracks_t[0], qr/title=Moon\\: Ćao\\=x/, 'sirov oblik: \\: i \\= escape');

(my $t2 = $tracks_t[1]) =~ s/\A2=//;
like($t2, qr/title=It\\'s a \\\\ test/, 'apostrof i obrnuta kosa crta escape-ovani');
like($t2, qr/artist=Čajkovski\\: Ž/, 'artist sa ":"');
unlike($t2, qr/musicbrainz_trackid/, 'bez recording_id nema musicbrainz_trackid');

# Bez MB id-jeva nema tih kljuceva
my %gen = (%base, profile => 'fast', disc => { discid => 'x' x 28, artist => 'A', album => 'B', year => '',
	disc_number => 1, disc_total => 1, tracks => [ { n => 1, title => 'T', artist => 'A' } ] });
my @g = rip_argv(%gen);
unlike(opt_val('-a', @g), qr/musicbrainz_albumid|musicbrainz_releasegroupid|date=/, 'bez id-jeva i godine nema praznih kljuceva');
ok(!has_opt('-c', @g), 'jedan disk -> bez -c');
is(opt_val('-c', @f), '1/2', 'vise diskova -> -c disc/total');

# omot / release id
ok(!has_opt('-C', @f), 'bez omota nema -C');
is(opt_val('-C', rip_argv(%base, profile => 'fast', cover => '/tmp/c.jpg')), 'Front=/tmp/c.jpg', 'omot Front=putanja');
ok(!has_opt('-R', rip_argv(%base, profile => 'fast', release_id => 'abc')), 'release_id ne ide u -R (konflikt sa -N)');

# ---- parse_progress ----
{
	open my $fh, '<:encoding(UTF-8)', 't/fixtures/cyanrip-output.txt' or BAIL_OUT("fixture: $!");
	local $/;
	my $raw = <$fh>;
	close $fh;
	my @lines = split /[\r\n]+/, $raw;
	my @pct   = map { $_->{percent} } grep { ref $_ && defined $_->{percent} } map { parse_prog($_) } @lines;
	cmp_ok(scalar @pct, '>', 10, 'fixture sadrzi linije napretka');
	my $mono = 1;
	for my $i (1 .. $#pct) { $mono = 0 if $pct[$i] < $pct[ $i - 1 ] }
	ok($mono, 'procenti rastu');
	cmp_ok($pct[-1], '>=', 99, 'poslednji procenat blizu 100');
	my @ev   = grep { defined } map { parse_prog($_) } @lines;
	my @done = grep { defined $_->{done_track} } @ev;
	is_deeply(\@done, [ { done_track => 1 } ], 'zavrsena pesma 1 prepoznata');
	my @acc = grep { defined $_->{accurip} } @ev;
	is_deeply([ map { $_->{accurip} } @acc ], [qw(mismatch mismatch)], 'accurip v1 i v2 linije (nije potvrdjeno)');
}
# Pravi izlaz cyanrip-a sa ispravnim ofsetom (+6, ASUS SDRW-08U7M-U), pesme 1-2: AccurateRip match.
# Disk: Enigma "The Cross of Changes" (metapodaci u -a/-t su bili lazni "AR test"; linija DiscID pokazuje nasu -a oznaku).
{
	open my $fh, '<:encoding(UTF-8)', 't/fixtures/cyanrip-output-ar-match.txt' or BAIL_OUT("fixture: $!");
	my @lines = map { s/\r?\n\z//r } <$fh>;
	close $fh;
	my @ev = grep { defined } map { parse_prog($_) } @lines;
	is_deeply([ map { $_->{done_track} } grep { defined $_->{done_track} } @ev ], [ 1, 2 ], 'pravi match: pesme 1 i 2');
	is_deeply([ map { $_->{accurip} } grep { defined $_->{accurip} } @ev ], [qw(match match match match)], 'pravi match: v1 i v2 za obe pesme');
	is_deeply(parse_prog('    Accurip v1:  CB46B521 (accurately ripped, confidence 197)'), { accurip => 'match' }, 'accurip match (prava linija)');
	my $s = summary(join "\n", @lines);
	is($s->{accurip_ok}, 2, 'pravi match: summary accurip_ok');
	is($s->{accurip_total}, 9, 'pravi match: summary accurip_total');
	is($s->{tracks_total}, 2, 'pravi match: "Tracks to rip:  1, 2" -> 2');
	is($s->{tracks_ok}, 2, 'pravi match: tracks_ok');
}
is_deeply(parse_prog('  Accurip:       disc not found in database'), { accurip => 'notfound' }, 'accurip notfound');
is(parse_prog('    Accurip 450: 6B879E77 (not found)'), undef, 'Accurip 450 se ne racuna');
is(parse_prog('  Accurip:       disc found in database (max confidence: 15)'), undef, 'zaglavlje accurip se preskace');
is_deeply(parse_prog('Ripping and encoding track 3, progress - 42.50%, ETA - 12s   '),
	{ track => 3, percent => 42.5 }, 'parse_progress linija napretka');
is(parse_prog('Opening drive...'), undef, 'nepoznata linija -> undef');
is(parse_prog(''), undef, 'prazna linija -> undef');

# ---- summary ----
{
	open my $fh, '<:encoding(UTF-8)', 't/fixtures/cyanrip-log.txt' or BAIL_OUT("fixture: $!");
	local $/;
	my $log = <$fh>;
	close $fh;
	my $s = summary($log);
	is($s->{tracks_total}, 1, 'summary: tracks_total');
	is($s->{tracks_ok}, 1, 'summary: tracks_ok');
	is($s->{accurip_total}, 9, 'summary: accurip_total (cyanrip broji sve pesme diska)');
	is($s->{accurip_ok}, 0, 'summary: accurip_ok (fast profil, pesma nije potvrdjena)');
}
is_deeply(summary("Disc tracks:    9\nTracks to rip:  all\nTrack 1 ripped and encoded successfully!\nTrack 2 ripped and encoded successfully!\nTrack 3 failed to rip\nTracks ripped accurately: 8/9\n"),
	{ tracks_ok => 2, tracks_total => 9, accurip_ok => 8, accurip_total => 9 }, 'summary: sve pesme');
is_deeply(summary(''), { tracks_ok => 0, tracks_total => 0, accurip_ok => 0, accurip_total => 0 }, 'summary praznog loga');
is_deeply(summary(undef), { tracks_ok => 0, tracks_total => 0, accurip_ok => 0, accurip_total => 0 }, 'summary undef');

done_testing;
