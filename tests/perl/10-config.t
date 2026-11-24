use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use Encode ();

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

# UTF-8 vrednosti se dekoduju (karakteri), da Naming::fs_bytes ne koduje dvaput
{
	my $path = "$dir/u.conf";
	open my $fh, '>:raw', $path or die;
	print $fh Encode::encode('UTF-8', "CD_RIPS_DIR=\"/srv/Muzika Đorđe\"\n");
	close $fh;
	my $v = Plugins::AudioCD::Config::parse_env_file($path)->{CD_RIPS_DIR};
	is($v, '/srv/Muzika Đorđe', 'UTF-8 vrednost dekodovana');
	is(length($v), 17, 'duzina u karakterima');
	require Plugins::AudioCD::Naming;
	is(Plugins::AudioCD::Naming::fs_bytes($v), Encode::encode('UTF-8', '/srv/Muzika Đorđe'), 'fs_bytes: kodovano jednom');

	open $fh, '>:raw', "$dir/l.conf" or die;
	print $fh "CD_RIPS_DIR=/srv/\xe9\n";    # Latin-1, nije UTF-8: ostaje kako jeste
	close $fh;
	is(Plugins::AudioCD::Config::parse_env_file("$dir/l.conf")->{CD_RIPS_DIR}, "/srv/\xe9", 'neispravan UTF-8: vrednost bez promene');
}

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
	autoLoad => 1, onInsert => 'none', autoPlayPlayer => '', autoRipProfile => 'balanced',
	ejectAfterRip => 0, notify => 1, polling => 1, secureCache => 0, earlyPlay => 1,
	libraryDir => '', ripsDir => '', noRipWhileLocalPlays => 0,
}, 'DEFAULTS prema spec-u');

is(Plugins::AudioCD::Config::migrate_on_insert(undef, 1), 'rip', 'migracija: ukljucen autoRip -> rip');
is(Plugins::AudioCD::Config::migrate_on_insert(undef, 0), undef, 'migracija: iskljucen autoRip -> podrazumevano');
is(Plugins::AudioCD::Config::migrate_on_insert('none', 1), undef, 'migracija: vec izabrano se ne menja');

done_testing;
