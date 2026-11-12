use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Metadata::MusicBrainz') }

my $MB = 'Plugins::AudioCD::Metadata::MusicBrainz';

# Disc ID-jevi korisceni za fixture-e (MusicBrainz API, ws/2/discid/<id>?inc=recordings+artist-credits+release-groups+labels):
#   mb-single.json        n5_jIEg0jYtxLe_N7x39y_GnJow-   Bobby McFerrin, Don't Worry Be Happy! (NL 1997), jedno izdanje
#   mb-multi-release.json .MaqDLotP30XHeibu5Neig4bQNg-   The Beatles, Abbey Road (23 izdanja; fixture sece na prvih 5)
#   mb-multidisc.json     uDAm7lKUREWYqiy5SA5BJ.OI6QM-   Pink Floyd, The Wall disc 2 (8 izdanja; fixture sece na prva 3)
#   mb-various.json       0jxZYvCBRZAfszZOf_kpFzV8rGM-   Now That's What I Call Music (2018) disc 2, Various Artists
#   mb-notfound.json      AAAAAAAAAAAAAAAAAAAAAAAAAAA-   404 telo
#   mb-fuzzy-real.json    dBFBpdDGyUnu4ofAwN5ZrxozKwM-   pravi disk sa servera, nema tacnog pogotka: toc= daje priblizne rezultate
my $dir = dirname($0) . '/fixtures';

sub slurp {
	my ($name) = @_;
	open my $fh, '<:raw', "$dir/$name" or die "$name: $!";
	local $/;
	return scalar <$fh>;
}

sub parse { return $MB->can('parse_releases')->(@_) }

# --- discid_url ---
my $toc = '1 9 194526 150 22063 38162 57206 86997 97725 115508 133129 158574';
is(
	$MB->can('discid_url')->('dBFBpdDGyUnu4ofAwN5ZrxozKwM-', $toc),
	'https://musicbrainz.org/ws/2/discid/dBFBpdDGyUnu4ofAwN5ZrxozKwM-'
		. '?toc=1+9+194526+150+22063+38162+57206+86997+97725+115508+133129+158574'
		. '&inc=recordings+artist-credits+release-groups+labels&fmt=json',
	'discid_url sa toc-om, + umesto razmaka'
);
unlike($MB->can('discid_url')->('x-'), qr/toc=/, 'bez toc-a nema toc parametra');

# --- single ---
{
	my $c = parse(slurp('mb-single.json'), 'n5_jIEg0jYtxLe_N7x39y_GnJow-', 9);
	is(scalar @$c, 1, 'single: jedan kandidat');
	my $r = $c->[0];
	is($r->{release_id}, '4c4bbf1a-ff44-4d2e-8de7-7c21cd90ddf9', 'release_id');
	is($r->{title},      "Don't Worry Be Happy!",                'title');
	is($r->{artist},     'Bobby McFerrin',                       'kandidat artist');
	is($r->{country},    'NL',                                   'country');
	is($r->{date},       '1997',                                 'date');
	is($r->{format},     'CD',                                   'format');
	is($r->{disc_count}, 1,                                      'disc_count');
	is($r->{medium_position}, 1,                                 'medium_position');
	ok(defined $r->{label} && length $r->{label}, 'label postoji') or diag explain $r;

	my $d = $r->{disc};
	is($d->{discid},           'n5_jIEg0jYtxLe_N7x39y_GnJow-', 'discid');
	is($d->{source},           'musicbrainz',                  'source');
	is($d->{artist},           'Bobby McFerrin',               'artist');
	is($d->{album_artist_id},  'a996b5bd-db99-4257-b036-336f63448aa2', 'album_artist_id');
	is($d->{album},            "Don't Worry Be Happy!",        'album');
	is($d->{year},             '1997',                         'year');
	is($d->{disc_number},      1,                              'disc_number');
	is($d->{disc_total},       1,                              'disc_total');
	is($d->{compilation},      0,                              'nije kompilacija');
	ok($d->{release_group_id} && $d->{release_group_id} =~ /^[0-9a-f-]{36}$/, 'release_group_id je MBID');
	is(scalar @{ $d->{tracks} }, 9, '9 pesama');
	is_deeply(
		[ map { $_->{title} } @{ $d->{tracks} } ],
		[ 'Don’t Worry, Be Happy', 'Turtle Shoes', 'Another Night in Tunisia', 'Even for Me (live)',
		  'Manana Iguana (live)', 'Drive', 'I Hear Music (live)', 'Walkin’ (live)', '’Round Midnight (live)' ],
		'naslovi svih pesama (dekodirani karakteri)'
	);
	is_deeply([ map { $_->{n} } @{ $d->{tracks} } ], [ 1 .. 9 ], 'brojevi pesama');
	is($d->{tracks}[0]{recording_id}, '6b74f878-6c0b-4625-a878-cbabd81d0db2', 'recording_id prve pesme');
	ok((!grep { !($_->{recording_id} && $_->{artist_id}) } @{ $d->{tracks} }), 'sve pesme imaju recording_id i artist_id');
	is($d->{tracks}[0]{artist}, 'Bobby McFerrin', 'izvodjac pesme');
	ok(!defined $d->{tracks}[0]{length}, 'length ostaje undef (Lookup popunjava)');
	ok(utf8::is_utf8($d->{tracks}[0]{title}), 'string je dekodiran');

	is_deeply(
		[ $MB->can('cover_urls')->($r) ],
		[ 'https://coverartarchive.org/release/4c4bbf1a-ff44-4d2e-8de7-7c21cd90ddf9/front-500',
		  "https://coverartarchive.org/release-group/$d->{release_group_id}/front-500" ],
		'cover_urls'
	);
}

# --- vise izdanja istog diska ---
{
	my $c = parse(slurp('mb-multi-release.json'), '.MaqDLotP30XHeibu5Neig4bQNg-', 17);
	is(scalar @$c, 5, 'multi-release: 5 kandidata');
	is($c->[0]{title}, 'Abbey Road', 'naslov');
	is($c->[0]{artist}, 'The Beatles', 'izvodjac');
	is($c->[0]{label}, 'Parlophone', 'label');
	is($c->[0]{disc}{year}, '1987', 'godina iz date');
	is_deeply([ map { $_->{country} } @$c ], [ qw(GB JP CA XE US) ], 'drzave po redu');
	is(scalar @{ $c->[0]{disc}{tracks} }, 17, '17 pesama');
	is($c->[0]{disc}{tracks}[0]{title}, 'Come Together', 'prva pesma');
	my %ids = map { $_->{release_id} => 1 } @$c;
	is(scalar keys %ids, 5, 'razliciti release_id');
	ok(!defined $c->[2]{disc}{year}, 'izdanje bez datuma nema godine');
}

# --- vise diskova: bira se medij sa tim disc ID-jem ---
{
	my $c = parse(slurp('mb-multidisc.json'), 'uDAm7lKUREWYqiy5SA5BJ.OI6QM-', 13);
	is(scalar @$c, 3, 'multidisc: 3 kandidata');
	my ($wall) = grep { $_->{release_id} eq 'b13b64f6-85fc-3c1c-8aae-e5adb94d7181' } @$c;
	ok($wall, 'nasao izdanje The Wall 1994') or BAIL_OUT('fixture');
	is($wall->{disc}{disc_number}, 2, 'disc_number = 2 (drugi medij, ne prvi sa 13 pesama)');
	is($wall->{disc}{disc_total},  2, 'disc_total = 2');
	is($wall->{medium_position},   2, 'medium_position');
	is($wall->{disc_count},        2, 'disc_count');
	is(scalar @{ $wall->{disc}{tracks} }, 13, '13 pesama');
	is($wall->{disc}{tracks}[0]{title}, 'Hey You', 'pesme sa pravog medija (disc 2 pocinje sa Hey You, disc 1 sa In the Flesh?)');
	is($wall->{disc}{tracks}[12]{title}, 'Outside the Wall', 'poslednja pesma');
	is($wall->{disc}{artist}, 'Pink Floyd', 'izvodjac');

	my ($box) = grep { $_->{release_id} eq 'af6d5943-1b91-42bd-90bb-2b7468c5c51e' } @$c;
	is($box->{disc}{disc_number}, 13, 'box set: isti disc ID je na medijumu 13');
	is($box->{disc}{disc_total}, 16, 'box set: 16 medija');
}

# --- razni izvodjaci ---
{
	my $c = parse(slurp('mb-various.json'), '0jxZYvCBRZAfszZOf_kpFzV8rGM-', 14);
	is(scalar @$c, 1, 'various: jedan kandidat');
	my $d = $c->[0]{disc};
	is($d->{compilation}, 1, 'compilation => 1');
	is($d->{artist}, 'Various Artists', 'album izvodjac');
	is($d->{album_artist_id}, '89ad4ac3-39f7-470e-963a-56509c546377', 'album_artist_id je Various Artists');
	is($d->{disc_number}, 2, 'disc_number');
	is($d->{disc_total}, 2, 'disc_total');
	is(scalar @{ $d->{tracks} }, 14, '14 pesama');
	is_deeply(
		[ map { $d->{tracks}[$_]{artist} } 0 .. 2 ],
		[ 'New Edition', 'Kajagoogoo', 'Tina Turner' ],
		'izvodjac po pesmi'
	);
	is($d->{tracks}[0]{title}, 'Candy Girl', 'naslov prve pesme');
	ok($d->{tracks}[0]{artist_id}, 'artist_id po pesmi');
	isnt($d->{tracks}[0]{artist_id}, $d->{album_artist_id}, 'artist_id pesme nije Various Artists');
}

# --- fuzzy (pravi disk, bez tacnog pogotka): medij po broju pesama ---
{
	my $c = parse(slurp('mb-fuzzy-real.json'), 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 9);
	is(scalar @$c, 4, 'fuzzy: 4 kandidata');
	is($c->[0]{title}, "Don't Worry Be Happy", 'prvi kandidat');
	is($c->[0]{disc}{discid}, 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 'discid je trazeni (ne iz odgovora)');
	is(scalar @{ $c->[0]{disc}{tracks} }, 9, '9 pesama');
	is($c->[0]{disc}{artist}, 'Bobby McFerrin', 'izvodjac');
	is($c->[0]{disc}{year}, '1993', 'godina');
	is_deeply(parse(slurp('mb-fuzzy-real.json'), 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 12), [],
		'fuzzy: nijedan medij sa 12 pesama -> []');
}

# --- nema pogotka / los ulaz ---
is_deeply(parse(slurp('mb-notfound.json'), 'AAAAAAAAAAAAAAAAAAAAAAAAAAA-', 9), [], 'notfound -> []');
{
	my $r = eval { parse('{ ovo nije json', 'x-', 9) };
	is($@, '', 'los JSON ne die');
	is_deeply($r, [], 'los JSON -> []');
	is_deeply(parse(undef, 'x-', 9), [], 'undef -> []');
	is_deeply(parse('', 'x-', 9), [], 'prazan string -> []');
	is_deeply(parse('[1,2]', 'x-', 9), [], 'JSON niz -> []');
	is_deeply(parse('{"releases":"x"}', 'x-', 9), [], 'releases nije niz -> []');
}

done_testing();
