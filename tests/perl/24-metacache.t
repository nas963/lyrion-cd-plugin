use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::MetaCache') }

my $dir = tempdir(CLEANUP => 1);
my $c   = Plugins::AudioCD::MetaCache->new(dir => "$dir/cache");
my $id  = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';

is($c->get($id), undef, 'prazan kes');
my $res = { discid => $id, candidates => [ { title => 'A' }, { title => 'B' } ], selected => 1,
	disc => { source => 'musicbrainz', album => "\x{10c}okolada", tracks => [] }, cover_urls => [] };
$c->put($id, $res);
is_deeply($c->get($id), $res, 'put/get, i UTF-8');

$c->put_manual($id, { album => 'Moje', tracks => [], source => 'musicbrainz' });
my $g = $c->get($id);
is($g->{disc}{album}, 'Moje', 'rucna izmena pobedjuje');
is($g->{disc}{source}, 'manual', 'source manual');
is(scalar @{ $g->{candidates} }, 2, 'kandidati ostaju');

my $id2 = 'AAAAAAAAAAAAAAAAAAAAAAAAAAA-';
$c->put_manual($id2, { album => 'Samo ruka', tracks => [] });
is($c->get($id2)->{disc}{source}, 'manual', 'samo rucna izmena, bez rezultata');

is($c->cover_path($id), "$dir/cache/$id.jpg", 'cover_path');

for my $bad ('../x', '../../etc/passwd', '', undef, 'a' x 29) {
	my $b = defined $bad ? $bad : 'undef';
	is($c->get($bad), undef, "get neispravan '$b' -> undef");
	ok(!eval { $c->put($bad, {}); 1 }, "put neispravan '$b' umire");
	ok(!eval { $c->cover_path($bad); 1 }, "cover_path neispravan '$b' umire");
}
ok(!-e "$dir/x.json" && !-e "$dir/../x.json", 'nista van foldera');

open my $fh, '>', "$dir/cache/$id2.json" or die; print $fh '{ pokvaren'; close $fh;
open $fh, '>', "$dir/cache/$id2.manual.json" or die; print $fh 'xx'; close $fh;
is($c->get($id2), undef, 'ostecen JSON -> undef');

done_testing();
