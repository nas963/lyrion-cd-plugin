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

# ---- eject_async: alat eject preko spawn-a, ioctl samo kao rezerva ----
{
    my (@spawns, @warns, $dones, $ioctls);
    my $spawn = sub { my %a = @_; push @spawns, {%a}; return bless {}, 'FakeJob' };
    my %base = (spawn => $spawn, warn => sub { push @warns, @_ }, ioctl => sub { $ioctls++; return (1, undef) });
    my $run = sub { @spawns = @warns = (); $dones = $ioctls = 0; Plugins::AudioCD::Drive::eject_async('/dev/sr0', %base, done => sub { $dones++ }, @_) };

    $run->(tool => '/usr/bin/eject');
    is(scalar @spawns, 1, 'eject_async: alat se pokrece');
    is($ioctls, 0, 'eject_async: ioctl se ne zove kad alat postoji');
    my @argv = @{ $spawns[0]{argv} };
    is_deeply([ @argv[-2, -1] ], ['/usr/bin/eject', '/dev/sr0'], 'eject_async: argv zavrsava alatom i uredjajem');
    is($argv[0], 'nice', 'eject_async: low_prio (nice)');
    is($dones, 0, 'eject_async: done tek posle izlaska alata');
    $spawns[0]{on_exit}->(0);
    is($dones, 1, 'eject_async: done posle statusa 0');
    is_deeply(\@warns, [], 'eject_async: status 0 bez upozorenja');
    $spawns[0]{on_exit}->(0);
    is($dones, 1, 'eject_async: done tacno jednom');

    $run->(tool => '/usr/bin/eject');
    $spawns[0]{on_line}->('eject: unable to eject');
    $spawns[0]{on_exit}->(1);
    is($dones, 1, 'eject_async: done i pri gresci');
    like($warns[0], qr/status 1.*unable to eject/, 'eject_async: upozorenje sa statusom i izlazom alata');

    $run->(tool => undef);
    is(scalar @spawns, 0, 'eject_async: bez alata nema spawn-a');
    is($ioctls, 1, 'eject_async: bez alata ioctl rezerva');
    is($dones, 1, 'eject_async: ioctl rezerva zove done');

    $run->(tool => '/usr/bin/eject', spawn => sub { die "nema\n" });
    is($dones, 1, 'eject_async: spawn greska -> done');
    like($warns[0], qr/nije uspelo/, 'eject_async: spawn greska se loguje');
}

done_testing;
