use strict;
use warnings;
use utf8;
use Test::More;

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Drive') }

is(Plugins::AudioCD::Drive::CDROMREADTOCHDR(),   0x5305, 'ioctl READTOCHDR');
is(Plugins::AudioCD::Drive::CDROMREADTOCENTRY(), 0x5306, 'ioctl READTOCENTRY');
is(Plugins::AudioCD::Drive::CDROM_DRIVE_STATUS(), 0x5326, 'ioctl DRIVE_STATUS');
is(Plugins::AudioCD::Drive::CDROMEJECT(),        0x5309, 'ioctl EJECT');
is(Plugins::AudioCD::Drive::CDS_DISC_OK(), 4, 'CDS_DISC_OK');

my @h = Plugins::AudioCD::Drive::unpack_tochdr("\x01\x09");
is_deeply(\@h, [1, 9], 'tochdr');

is(length Plugins::AudioCD::Drive::pack_tocentry_req(3), 12, 'zahtev je 12 bajtova');
is(unpack('C', Plugins::AudioCD::Drive::pack_tocentry_req(3)), 3, 'zahtev nosi broj pesme');
is(unpack('x2 C', Plugins::AudioCD::Drive::pack_tocentry_req(3)), 0x01, 'format CDROM_LBA');

my $data = pack('C C C C l C x3', 2, 0x41, 1, 0, 201234, 0);
my $e = Plugins::AudioCD::Drive::unpack_tocentry($data);
is_deeply($e, { n => 2, adr_ctrl => 0x41, data => 1, lba => 201234 }, 'data entry');

my $audio = pack('C C C C l C x3', 1, 0x10, 1, 0, 0, 0);
$e = Plugins::AudioCD::Drive::unpack_tocentry($audio);
is($e->{data}, 0, 'audio entry nije data');
is($e->{lba}, 0, 'lba 0');

my $neg = pack('C C C C l C x3', 1, 0x10, 1, 0, -150, 0);
is(Plugins::AudioCD::Drive::unpack_tocentry($neg)->{lba}, -150, 'lba je oznacen');

my ($code, $err) = Plugins::AudioCD::Drive::drive_status('/nema');
is($code, undef, 'nema uredjaja: bez koda');
is($err, 'no_device', 'nema uredjaja: no_device');

my ($toc, $terr) = Plugins::AudioCD::Drive::read_toc('/nema');
is($toc, undef, 'read_toc bez uredjaja');
is($terr, 'no_device', 'read_toc no_device');

my ($ok, $eerr) = Plugins::AudioCD::Drive::eject('/nema');
ok(!$ok, 'eject bez uredjaja ne uspeva');
is($eerr, 'no_device', 'eject no_device');

done_testing;
