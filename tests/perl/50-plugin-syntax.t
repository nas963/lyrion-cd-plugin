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

# Verzija ima jedan izvor istine: Plugin.pm $VERSION (User-Agent, hello) mora biti ista kao u install.xml
{
	open my $x, '<', "$dir/install.xml" or die $!;
	my ($xml_ver) = do { local $/; <$x> } =~ m{<version>([^<]+)</version>};
	open my $p, '<', "$dir/Plugin.pm" or die $!;
	my ($pm_ver) = do { local $/; <$p> } =~ m{our \$VERSION = '([^']+)';};
	ok(defined $xml_ver && defined $pm_ver, 'verzija u install.xml i Plugin.pm');
	is($pm_ver, $xml_ver, 'Plugin.pm $VERSION == install.xml version');
}

# Cache i Lookup citaju device/secureCache pri svakoj upotrebi (promena podesavanja bez restarta)
{
	open my $p, '<', "$dir/Plugin.pm" or die $!;
	my $src = do { local $/; <$p> };
	ok($src !~ qr/device\s*=>\s*_device\(\)/, 'Plugin.pm: device se ne zamrzava pri startu');
	ok($src !~ qr/secure\s*=>\s*\$prefs->get/, 'Plugin.pm: secureCache se ne zamrzava pri startu');
	ok($src =~ qr/device\s*=>\s*\\&_device/, 'Plugin.pm: device kao code ref');
}

# LMS daje muzicke foldere kao bajtove (encode_locale), a prefs su karakteri: dekoduju se pre poredjenja
{
	for my $f (qw(Plugin.pm Settings.pm)) {
		open my $p, '<', "$dir/$f" or die $!;
		my $src = do { local $/; <$p> };
		my @raw = $src =~ /(=>\s*Slim::Utils::Misc::getMediaDirs|,\s*\n?\s*Slim::Utils::Misc::getMediaDirs\('audio'\)\))/g;
		is(scalar @raw, 0, "$f: getMediaDirs se ne prosledjuje nedekodovan");
	}
	open my $p, '<', "$dir/Plugin.pm" or die $!;
	my $src = do { local $/; <$p> };
	ok($src =~ /sub media_dirs \{[^}]*utf8decode_locale/s, 'Plugin::media_dirs dekoduje (utf8decode_locale)');
}

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
