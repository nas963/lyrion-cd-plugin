use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Config') }

my $dir = tempdir(CLEANUP => 1);

sub write_conf {
	my ($name, $text) = @_;
	my $path = "$dir/$name";
	open my $fh, '>', $path or die "$path: $!";
	print $fh $text;
	close $fh;
	return $path;
}

# parse_env_file
is_deeply(Plugins::AudioCD::Config::parse_env_file("$dir/nema-me"), {}, 'nepostojeci fajl daje {}');

my $p = write_conf('a.conf', "CD_RIPS_DIR=/data/CD-Rips # komentar\n");
is(Plugins::AudioCD::Config::parse_env_file($p)->{CD_RIPS_DIR}, '/data/CD-Rips', 'komentar na kraju linije se odbacuje');

$p = write_conf('b.conf', qq{CD_RIPS_DIR="/data/My Rips"\n});
is(Plugins::AudioCD::Config::parse_env_file($p)->{CD_RIPS_DIR}, '/data/My Rips', 'dvostruki navodnici se skidaju');

$p = write_conf('c.conf', "CD_RIPS_DIR='/x'\n");
is(Plugins::AudioCD::Config::parse_env_file($p)->{CD_RIPS_DIR}, '/x', 'jednostruki navodnici se skidaju');

$p = write_conf('d.conf', "\n# samo komentar\n   \nexport A=1\nB=2\n");
is_deeply(Plugins::AudioCD::Config::parse_env_file($p), { A => 1, B => 2 }, 'prazne i # linije se ignorisu, export se prihvata');

# default_rips_dir
my $audioos  = "$dir/audioos.conf";
my $defaults = "$dir/defaults.conf";
my %opt = (audioos_conf => $audioos, defaults_conf => $defaults);

is(Plugins::AudioCD::Config::default_rips_dir(%opt), '/var/lib/squeezeboxserver/CD-Rips', 'bez oba fajla: ugradjeni podrazumevani');

write_conf('defaults.conf', "CD_RIPS_DIR=/from/defaults\n");
is(Plugins::AudioCD::Config::default_rips_dir(%opt), '/from/defaults', 'defaults.conf se koristi');

write_conf('audioos.conf', "CD_RIPS_DIR=/from/audioos\n");
is(Plugins::AudioCD::Config::default_rips_dir(%opt), '/from/audioos', 'audioos.conf ima prednost nad defaults.conf');

write_conf('audioos.conf', "OTHER=1\n");
is(Plugins::AudioCD::Config::default_rips_dir(%opt), '/from/defaults', 'audioos.conf bez kljuca: pada na defaults.conf');

# rips_dir
is(Plugins::AudioCD::Config::rips_dir('/moj', %opt), '/moj', 'neprazan pref pobedjuje');
is(Plugins::AudioCD::Config::rips_dir('', %opt), '/from/defaults', 'prazan pref daje podrazumevani');
is(Plugins::AudioCD::Config::rips_dir(undef, %opt), '/from/defaults', 'undef pref daje podrazumevani');

# DEFAULTS
my %d = %Plugins::AudioCD::Config::DEFAULTS;
is_deeply(\%d, {
	device => '/dev/cdrom', profile => 'balanced', flacLevel => 5,
	quietDrive => 0, quietSpeed => 8, driveOffset => '',
	autoLoad => 1, autoRip => 0, autoRipProfile => 'balanced',
	ejectAfterRip => 0, notify => 1, polling => 1, secureCache => 0,
	libraryDir => '', ripsDir => '', noRipWhileLocalPlays => 0,
}, 'DEFAULTS prema spec-u');

done_testing;
