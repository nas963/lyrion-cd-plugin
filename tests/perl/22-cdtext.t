use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Metadata::CdText') }

my $C   = 'Plugins::AudioCD::Metadata::CdText';
my $dir = dirname($0) . '/fixtures';

# Fixture-i:
#   cdinfo-none.txt    PRAVI ispis /usr/bin/cd-info za disk u drajvu (nema CD-Text-a)
#   cdinfo-cdtext.txt  SINTETICKI: pravi disk nema CD-Text, pa je primer napravljen rucno po formatu koji
#                      libcdio cd-info ispisuje ("CD-TEXT for Disc:" / "CD-TEXT for Track  N:" + TAB polja)
sub slurp {
	my ($name) = @_;
	open my $fh, '<:raw', "$dir/$name" or die "$name: $!";
	local $/;
	my $raw = <$fh>;
	utf8::decode($raw);
	return $raw;
}

is_deeply(
	[ $C->can('command')->('/dev/cdrom') ],
	[ '/usr/bin/cd-info', '--no-header', '--no-device-info', '--no-disc-mode', '--no-cddb', '--no-vcd', '--no-ioctl', '--no-analyze', '-C', '/dev/cdrom' ],
	'command: opcije i eksplicitna putanja'
);

ok(!defined $C->can('parse')->(slurp('cdinfo-none.txt'), 9), 'pravi disk bez CD-Text-a -> undef');
ok(!defined $C->can('parse')->('No CD-TEXT on Disc.', 3), 'eksplicitna poruka -> undef');
ok(!defined $C->can('parse')->('', 3), 'prazan ispis -> undef');
ok(!defined $C->can('parse')->(undef, 3), 'undef -> undef');

my $d = $C->can('parse')->(slurp('cdinfo-cdtext.txt'), 3);
is($d->{source}, 'cdtext', 'source');
is($d->{artist}, 'Björk', 'izvodjac diska (UTF-8)');
is($d->{album}, 'Vespertine', 'album');
ok(!defined $d->{year}, 'godine nema u CD-Text-u');
is($d->{disc_number}, 1, 'disc_number');
is($d->{disc_total}, 1, 'disc_total');
is($d->{compilation}, 0, 'compilation');
is(scalar(@{ $d->{tracks} }), 3, '3 pesme');
is_deeply([ map { $_->{n} } @{ $d->{tracks} } ], [ 1, 2, 3 ], 'brojevi pesama');
is($d->{tracks}[0]{title}, 'Hidden Place', 'naslov 1');
is($d->{tracks}[1]{artist}, 'Björk feat. Matmos', 'izvodjac pesme 2');
is($d->{tracks}[2]{title}, "It's Not Up to You", 'naslov 3');
is($d->{tracks}[2]{artist}, 'Björk', 'pesma bez PERFORMER nasledjuje izvodjaca diska');
ok(!defined $d->{tracks}[0]{length}, 'length undef');

# samo prvi jezik
my $multi = "Language 0 'English':\nCD-TEXT for Disc:\n\tTITLE: One\nCD-TEXT for Track  1:\n\tTITLE: A\n"
	. "Language 1 'German':\nCD-TEXT for Disc:\n\tTITLE: Eins\nCD-TEXT for Track  1:\n\tTITLE: B\n";
$d = $C->can('parse')->($multi, 1);
is($d->{album}, 'One', 'prvi jezik: album');
is($d->{tracks}[0]{title}, 'A', 'prvi jezik: pesma');

done_testing;
