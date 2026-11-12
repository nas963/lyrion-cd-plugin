use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use JSON::PP ();
use Encode ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Metadata::Lookup') }

my $L   = 'Plugins::AudioCD::Metadata::Lookup';
my $dir = dirname($0) . '/fixtures';

sub slurp {
	my ($name) = @_;
	open my $fh, '<:raw', "$dir/$name" or die "$name: $!";
	local $/;
	return scalar <$fh>;
}

my $toc = JSON::PP->new->utf8->decode(slurp('real-disc-toc.json'))->{toc};

# Lazni svet: $routes { mb => [status, body]|'err', query => ..., read => ..., cdinfo => text }
sub world {
	my (%r) = @_;
	my $w = { urls => [], mb_times => [], clock => 100, delays => [], argv => [] };
	$w->{http_get} = sub {
		my ($url, $ok, $err) = @_;
		push @{ $w->{urls} }, $url;
		my $key = $url =~ m{musicbrainz\.org} ? 'mb' : $url =~ /cmd=cddb\+query/ ? 'query' : $url =~ /cmd=cddb\+read/ ? 'read' : 'other';
		push @{ $w->{mb_times} }, $w->{clock} if $key eq 'mb';
		my $v = $r{$key};
		return $err->('mreza') if !defined $v || $v eq 'err';
		$ok->($v->[1], $v->[0]);
	};
	$w->{timer} = sub { my ($s, $cb) = @_; push @{ $w->{delays} }, $s; $w->{clock} += $s; $cb->() };
	$w->{now}   = sub { $w->{clock} };
	$w->{run_cmd} = sub { my ($argv, $cb) = @_; $w->{argv} = $argv; $cb->($r{cdinfo}) };
	$w->{lookup} = $L->can('new')->($L,
		http_get => $w->{http_get}, run_cmd => $w->{run_cmd}, timer => $w->{timer}, now => $w->{now},
		version => '0.1.0', device => '/dev/cdrom');
	return $w;
}

sub run {
	my ($w) = @_;
	my $res;
	$w->{lookup}->lookup($toc, sub { $res = $_[0] });
	return $res;
}

# --- generic_disc / fill_lengths ---
{
	my $d = $L->can('generic_disc')->($toc);
	is($d->{source}, 'generic', 'generic: source');
	is(scalar @{ $d->{tracks} }, 9, 'generic: 9 pesama');
	is($d->{tracks}[0]{title}, 'Track 1', 'generic: Track 1');
	is($d->{tracks}[8]{title}, 'Track 9', 'generic: Track 9');
	is($d->{artist}, 'Unknown Artist', 'generic: artist');
	is($d->{album}, 'Audio CD', 'generic: album');
	is($d->{tracks}[0]{length}, 292, 'generic: length iz TOC-a (21913/75)');

	my $disc = { tracks => [ { n => 1, length => undef }, { n => 2, length => 5 } ] };
	$L->can('fill_lengths')->($disc, $toc);
	is($disc->{tracks}[0]{length}, 292, 'fill_lengths: popunjeno');
	is($disc->{tracks}[1]{length}, 5, 'fill_lengths: postojece ostaje');
}

# --- MusicBrainz fuzzy + GnuDB preselekcija (pravi disk) ---
{
	my $w = world(
		mb    => [ 200, slurp('mb-fuzzy-real.json') ],
		query => [ 200, slurp('gnudb-query-210.txt') ],
		read  => [ 200, slurp('gnudb-read.txt') ],
	);
	my $r = run($w);
	is($r->{disc}{source}, 'musicbrainz', 'fuzzy: source musicbrainz');
	is(scalar @{ $r->{candidates} }, 4, 'fuzzy: 4 kandidata');
	is($r->{candidates}[ $r->{selected} ]{title}, 'The Story of Jazz', 'fuzzy: preselektovan The Story of Jazz');
	is($r->{selected}, 2, 'fuzzy: indeks 2');
	is($r->{fuzzy}, 1, 'fuzzy: result.fuzzy');
	ok((!grep { !$_->{fuzzy} } @{ $r->{candidates} }), 'fuzzy: svaki kandidat fuzzy');
	is($r->{disc}{tracks}[0]{length}, 292, 'fuzzy: length popunjen');
	is($r->{discid}, 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 'fuzzy: discid');
	is($r->{cddbid}, '6a0a1f09', 'fuzzy: cddbid');
	is($r->{disc}{discid}, $r->{discid}, 'disc nosi discid');
	like($r->{cover_urls}[0], qr{^https://coverartarchive\.org/release/}, 'cover_urls popunjen');
	is(scalar(grep { /cddb\+query/ } @{ $w->{urls} }), 1, 'fuzzy: jedan GnuDB query');
}

# --- preselekcija: velika/mala slova, akcenti, razmaci ---
{
	my $read = Encode::decode('UTF-8', slurp('gnudb-read.txt'));
	$read =~ s{^DTITLE=.*$}{DTITLE=Bobby McFerrin /   THE  Story of J\x{e0}zz  }m;
	my $w = world(
		mb    => [ 200, slurp('mb-fuzzy-real.json') ],
		query => [ 200, slurp('gnudb-query-210.txt') ],
		read  => [ 200, Encode::encode('UTF-8', $read) ],
	);
	my $r = run($w);
	is($r->{selected}, 2, 'preselekcija: akcenti/velika slova/razmaci');
}

# --- fuzzy, GnuDB ne uspeva -> indeks 0 ---
{
	my $w = world(mb => [ 200, slurp('mb-fuzzy-real.json') ], query => [ 200, slurp('gnudb-query-202.txt') ]);
	my $r = run($w);
	is($r->{selected}, 0, 'fuzzy bez GnuDB: indeks 0');
	is($r->{fuzzy}, 1, 'fuzzy bez GnuDB: ipak fuzzy');
}

# --- tacan pogodak: bez GnuDB, fuzzy 0 ---
{
	# fixture sa tacnim ID-jem: koristimo mb-single sa njegovim TOC-om nije dostupno, pa proveravamo
	# preko parsera: telo sa tacnim ID-jem iz pravog diska pravimo od fuzzy fixture-a.
	my $body = JSON::PP->new->utf8->decode(slurp('mb-fuzzy-real.json'));
	push @{ $body->{releases}[2]{media}[0]{discs} }, { id => 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-' };
	my $w = world(mb => [ 200, JSON::PP->new->utf8->encode($body) ]);
	my $r = run($w);
	is($r->{disc}{source}, 'musicbrainz', 'tacan: musicbrainz');
	is($r->{fuzzy}, 0, 'tacan: nije fuzzy');
	is($r->{selected}, 0, 'tacan: indeks 0');
	ok(!(grep { /cddb/ } @{ $w->{urls} }), 'tacan: GnuDB se ne pita');
	ok(!$r->{candidates}[0]{fuzzy}, 'tacan: kandidat nije fuzzy');
}

# --- MB 404 + GnuDB 200 ---
{
	my $w = world(mb => [ 404, slurp('mb-notfound.json') ], query => [ 200, slurp('gnudb-query-210.txt') ], read => [ 200, slurp('gnudb-read.txt') ]);
	my $r = run($w);
	is($r->{disc}{source}, 'gnudb', 'MB 404 + GnuDB -> gnudb');
	is($r->{disc}{album}, 'The Story of Jazz', 'gnudb album');
	is($r->{disc}{artist}, 'Bobby McFerrin', 'gnudb artist');
	is($r->{disc}{tracks}[0]{length}, 292, 'gnudb: length popunjen');
	is($r->{disc}{discid}, 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 'gnudb: discid');
	is($r->{fuzzy}, 0, 'gnudb: nije fuzzy');
}

# --- (1) UTF-8 bajtovi iz GnuDB se dekodiraju ---
{
	my $w = world(mb => 'err', query => [ 200, slurp('gnudb-query-200.txt') ], read => [ 200, slurp('gnudb-read-utf8.txt') ]);
	my $r = run($w);
	is($r->{disc}{source}, 'gnudb', 'utf8: gnudb');
	ok(utf8::is_utf8($r->{disc}{album}) && $r->{disc}{album} =~ /[^\x00-\x7f]/, 'utf8: album dekodiran u znakove');
	is($r->{disc}{album}, 'Sigue la l' . "\x{ed}" . 'nea morada', 'utf8: tacan naslov');
}

# --- (2) GnuDB read sa greskom (prazan disk) -> promasaj, ide dalje ---
{
	my $w = world(mb => 'err', query => [ 200, slurp('gnudb-query-210.txt') ], read => [ 200, "401 Specified CDDB entry not found.\n" ],
		cdinfo => slurp('cdinfo-cdtext.txt'));
	my $r = run($w);
	is($r->{disc}{source}, 'cdtext', 'garbage read -> CD-Text');
}

# --- MB i GnuDB greska + CD-Text ---
{
	my $w = world(mb => 'err', query => 'err', cdinfo => slurp('cdinfo-cdtext.txt'));
	my $r = run($w);
	is($r->{disc}{source}, 'cdtext', 'CD-Text');
	is($r->{disc}{tracks}[0]{length}, 292, 'cdtext: length');
	is($w->{argv}[0], 'nice', 'cd-info ide kroz nice');
	ok((grep { $_ eq '/dev/cdrom' } @{ $w->{argv} }), 'cd-info dobija device');
}

# --- sve prazno -> generic ---
{
	my $w = world(mb => [ 404, slurp('mb-notfound.json') ], query => [ 200, slurp('gnudb-query-202.txt') ], cdinfo => slurp('cdinfo-none.txt'));
	my $r = run($w);
	is($r->{disc}{source}, 'generic', 'generic fallback');
	is(scalar @{ $r->{disc}{tracks} }, 9, 'generic: 9 pesama');
	is_deeply([ map { $_->{title} } @{ $r->{disc}{tracks} } ], [ map { "Track $_" } 1 .. 9 ], 'Track 1..9');
	is($r->{selected}, 0, 'generic: selected 0');
}

# --- rate limit: dva uzastopna lookup-a ---
{
	my $w = world(mb => [ 200, slurp('mb-fuzzy-real.json') ], query => [ 202, "202 No match\n" ]);
	run($w);
	run($w);
	is(scalar @{ $w->{mb_times} }, 2, 'dva MB zahteva');
	cmp_ok($w->{mb_times}[1] - $w->{mb_times}[0], '>=', 1, 'MB zahtevi najmanje 1 s razmaka');
	cmp_ok($w->{delays}[0], '>=', 1, 'drugi zahtev zakazan tajmerom');
}

# --- privatnost: URL-ovi sadrze samo discid/toc/cddb i staticki hello ---
{
	my $w = world(mb => [ 200, slurp('mb-fuzzy-real.json') ], query => [ 200, slurp('gnudb-query-210.txt') ], read => [ 200, slurp('gnudb-read.txt') ]);
	run($w);
	ok(scalar @{ $w->{urls} } >= 3, 'ima URL-ova');
	for my $u (@{ $w->{urls} }) {
		if ($u =~ m{^https://musicbrainz\.org/ws/2/discid/[A-Za-z0-9._-]{28}\?toc=[0-9+]+&inc=[a-z+-]+&fmt=json$}) { pass("MB URL cist: $u") }
		elsif ($u =~ m{^https://gnudb\.gnudb\.org/~cddb/cddb\.cgi\?cmd=cddb\+(query|read)\+[0-9a-z+]+&hello=audiocd\+lyrion-cd-plugin\+AudioCD\+0\.1\.0&proto=6$}) { pass("GnuDB URL cist: $u") }
		else { fail("neocekivan URL: $u") }
	}
}

done_testing();
