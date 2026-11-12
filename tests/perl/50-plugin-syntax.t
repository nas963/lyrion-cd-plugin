use strict;
use warnings;
use utf8;
use Test::More;
use File::Find;
use File::Basename qw(dirname);

use lib dirname(__FILE__) . '/lib';
use LMSBoot;

my $dir = 'lib/Plugins/AudioCD';

ok -f "$dir/install.xml", 'install.xml postoji';
my $read = q{import sys,xml.etree.ElementTree as E; r=E.parse(sys.argv[1]).getroot(); print(r.find('module').text, r.find('name').text, r.find('optionsURL').text)};
my $out = `python3 -c "$read" $dir/install.xml`;
is $?, 0, 'install.xml je ispravan XML';
like $out, qr{^Plugins::AudioCD::Plugin PLUGIN_AUDIOCD plugins/AudioCD/settings/basic\.html}, 'modul, naziv i podesavanja';

open my $strings, '<', "$dir/strings.txt" or die $!;
my $text = do { local $/; <$strings> };
like $text, qr/^PLUGIN_AUDIOCD\n\tEN\t/m, 'string naziva plugina';

my @files;
find({ wanted => sub { push @files, $File::Find::name if /\.pm$/ }, no_chdir => 1 }, $dir);
ok scalar(@files), 'ima .pm fajlova';
for my $file (sort @files) {
	my $res = LMSBoot::syntax($file);
	like $res, qr/syntax OK/, "$file: syntax OK" or diag $res;
}
done_testing;
