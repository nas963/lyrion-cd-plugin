use strict;
use warnings;
use utf8;
use Test::More;
use File::Find;

my $dir = 'lib/Plugins/AudioCD';
my $perlver = sprintf("%d.%d", $^V->{version}[0], $^V->{version}[1]);
my @inc = map { "-I $_" } ("lib", "/usr/share/squeezeboxserver/CPAN/arch/$perlver", "/usr/share/squeezeboxserver/CPAN/arch/$perlver/x86_64-linux-thread-multi", "/usr/share/squeezeboxserver/CPAN", "/usr/share/squeezeboxserver/lib", "/usr/share/squeezeboxserver", "/usr/share/perl5");

# Slim::* ocekuje konstante iz slimserver-a u main::, pa ih definisemo pre kompajliranja.
my $boot = q{BEGIN { require constant; constant->import({ SCANNER => 0, RESIZER => 0, ISWINDOWS => 0, ISMAC => 0, TRANSCODING => 1, PERFMON => 0, DEBUGLOG => 1, INFOLOG => 1, STATISTICS => 1, SB1SLIMP3SYNC => 0, WEBUI => 1, NOMYSB => 1, LOCALFILE => 0, NOBROWSECACHE => 0, SLIM_SERVICE => 0, NOUPNP => 0, ISACTIVEPERL => 0, HAS_AIO => 0 }) } require Slim::Utils::OSDetect; Slim::Utils::OSDetect::init(); my $f = shift; require "./$f"; print qq{$f syntax OK\n};};

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
	my $res = `perl @inc -e '$boot' $file 2>&1`;
	like $res, qr/syntax OK/, "$file: syntax OK" or diag $res;
}
done_testing;
