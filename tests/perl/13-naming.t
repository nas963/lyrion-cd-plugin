use strict;
use warnings;
use utf8;
use Test::More;
use Encode ();

binmode(Test::More->builder->output,         ':encoding(UTF-8)');
binmode(Test::More->builder->failure_output, ':encoding(UTF-8)');
binmode(Test::More->builder->todo_output,    ':encoding(UTF-8)');

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Naming') }

my $N = 'Plugins::AudioCD::Naming';

is($N->can('sanitize')->('AC/DC: Live?'), 'AC-DC- Live', 'dve tacke i kosa crta');
is($N->can('sanitize')->('a*b"c<d>e|f\g'), 'abcdefg', 'zabranjeni znaci se brisu');
is($N->can('sanitize')->("a\x00b\x1fc\x7fd"), 'abcd', 'kontrolni znaci uklonjeni');
is($N->can('sanitize')->('Album. '), 'Album', 'tacke i razmaci na kraju');
is($N->can('sanitize')->('CON'), 'CON_', 'rezervisano ime');
is($N->can('sanitize')->('nul'), 'nul_', 'rezervisano ime, mala slova');
is($N->can('sanitize')->('COM1'), 'COM1_', 'COM1');
is($N->can('sanitize')->('LPT9.txt'), 'LPT9_.txt', 'rezervisano ime sa ekstenzijom');
is($N->can('sanitize')->('CONSOLE'), 'CONSOLE', 'nije rezervisano');
is($N->can('sanitize')->(''), 'Unknown', 'prazno');
is($N->can('sanitize')->('...'), 'Unknown', 'samo tacke');
is($N->can('sanitize')->(undef), 'Unknown', 'undef');
is($N->can('sanitize')->('.hack'), '_hack', 'tacka na pocetku -> _ (skriven folder u Sambi/LMS-u)');
is($N->can('sanitize')->('...And Justice for All'), '___And Justice for All', 'svaka tacka na pocetku -> _');
is($N->can('sanitize')->(' .x'), '_x', 'razmak pa tacka na pocetku');
is($N->can('sanitize')->('a.b'), 'a.b', 'tacka u sredini ostaje');
is($N->can('sanitize')->('Đorđe Balašević – Čovek'), 'Đorđe Balašević – Čovek', 'unicode ostaje');

my $jp = "\x{65e5}" x 120;    # 360 bajtova
my $s = $N->can('sanitize')->($jp);
my $bytes = Encode::encode('UTF-8', $s);
cmp_ok(length($bytes), '<=', 200, 'najvise 200 bajtova');
my $ok = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK); 1 };
ok($ok, 'validan UTF-8');
is(length($s), 66, 'seceno na granici znaka');

is($N->can('album_dir')->('/r', { artist => 'A', album => 'B', compilation => 0, disc_total => 1 }),
    '/r/A/B', 'album_dir');
is($N->can('album_dir')->('/r', { artist => 'A', album => 'B', compilation => 1, disc_total => 1 }),
    '/r/Various Artists/B', 'album_dir kompilacija');

is($N->can('track_file')->({ artist => 'A', compilation => 0 }, { n => 3, title => 'Naslov' }),
    '03 - Naslov.flac', 'track_file');
is($N->can('track_file')->({ artist => 'A', compilation => 1 }, { n => 3, title => 'Naslov', artist => 'Izvođač' }),
    '03 - Izvođač - Naslov.flac', 'track_file kompilacija');
is($N->can('track_file')->({ compilation => 0 }, { n => 12, title => 'A/B' }),
    '12 - A-B.flac', 'sanitizacija naslova');

is($N->can('disc_subdir')->({ disc_number => 2, disc_total => 2 }), 'Disc 2', 'disc_subdir');
is($N->can('disc_subdir')->({ disc_number => 1, disc_total => 1 }), '', 'jedan disk');

is($N->can('unique_dir')->('/r/A/B', sub { $_[0] eq '/r/A/B' || $_[0] eq '/r/A/B (2)' }),
    '/r/A/B (3)', 'unique_dir');
is($N->can('unique_dir')->('/r/A/B', sub { 0 }), '/r/A/B', 'unique_dir slobodan');

is($N->can('fs_bytes')->('Č'), "\xc4\x8c", 'fs_bytes');

my $cjk = "\x{65e5}" x 120;
my $valid = sub { eval { Encode::decode('UTF-8', Encode::encode('UTF-8', $_[0]), Encode::FB_CROAK); 1 } };
for my $comp (0, 1) {
    my $f = $N->can('track_file')->({ artist => $cjk, compilation => $comp }, { n => 3, title => $cjk, artist => $cjk });
    cmp_ok(length(Encode::encode('UTF-8', $f)), '<=', 200, "track_file cela duzina <= 200 (compilation=$comp)");
    ok($valid->($f), "track_file validan UTF-8 (compilation=$comp)");
    like($f, qr/\.flac\z/, "ekstenzija ostaje (compilation=$comp)");
}
my $cf = $N->can('track_file')->({ compilation => 1 }, { n => 3, title => $cjk, artist => 'X' });
like($cf, qr/\A03 - X - \x{65e5}+\.flac\z/, 'kratak izvodjac se ne seca');
my $long = '/r/A/' . ("\x{65e5}" x 66);    # 198 bajtova
my $u = $N->can('unique_dir')->($long, sub { $_[0] eq $long });
my ($ucomp) = $u =~ m{([^/]+)\z};
cmp_ok(length(Encode::encode('UTF-8', $ucomp)), '<=', 200, 'unique_dir komponenta <= 200');
ok($valid->($ucomp), 'unique_dir validan UTF-8');
like($u, qr/ \(2\)\z/, 'unique_dir sufiks');

done_testing;
