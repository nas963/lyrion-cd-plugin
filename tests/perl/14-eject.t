use strict;
use warnings;
use utf8;
use Test::More;

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Eject') }

# ---- eject_async: alat eject preko spawn-a; rezerva (ioctl) ide u pomocni proces, asinhrono ----
{
    my (@spawns, @warns, $dones, @fallback);
    my $spawn = sub { my %a = @_; push @spawns, {%a}; return bless {}, 'FakeJob' };
    my %base = (spawn => $spawn, warn => sub { push @warns, @_ }, fallback => sub { push @fallback, [@_] });
    my $run = sub { @spawns = @warns = @fallback = (); $dones = 0; Plugins::AudioCD::Eject::eject_async('/dev/sr0', %base, done => sub { $dones++ }, @_) };

    $run->(tool => '/usr/bin/eject');
    is(scalar @spawns, 1, 'eject_async: alat se pokrece');
    is(scalar @fallback, 0, 'eject_async: rezerva se ne zove kad alat postoji');
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

    # bez alata: rezerva (CDROMEJECT u pomocnom procesu), done tek kad ona javi
    $run->(tool => undef);
    is(scalar @spawns, 0, 'eject_async: bez alata nema spawn-a');
    is(scalar @fallback, 1, 'eject_async: bez alata rezerva');
    is($fallback[0][0], '/dev/sr0', 'rezerva dobija uredjaj');
    is($dones, 0, 'rezerva: done tek posle odgovora');
    $fallback[0][1]->(0, 'io');
    is($dones, 1, 'rezerva: done posle odgovora');
    like($warns[0], qr/izbacivanje nije uspelo \(io\)/, 'rezerva: greska se loguje');
    $fallback[0][1]->(1, undef);
    is($dones, 1, 'rezerva: done tacno jednom');

    # bez alata i bez rezerve: samo upozorenje i done
    @warns = ();
    $dones = 0;
    Plugins::AudioCD::Eject::eject_async('/dev/sr0', tool => undef, warn => sub { push @warns, @_ }, done => sub { $dones++ });
    is($dones, 1, 'bez alata i rezerve: done');
    like($warns[0], qr/nije uspelo/, 'bez alata i rezerve: upozorenje');

    $run->(tool => '/usr/bin/eject', spawn => sub { die "nema\n" });
    is($dones, 1, 'eject_async: spawn greska -> done');
    like($warns[0], qr/nije uspelo/, 'eject_async: spawn greska se loguje');
}

# Drive.pm (ioctl biblioteka) se ne koristi u LMS procesu za izbacivanje
ok(!Plugins::AudioCD::Eject->can('ioctl'), 'Eject ne radi ioctl');
ok(!$INC{'Plugins/AudioCD/Drive.pm'}, 'Eject ne ucitava Drive.pm');

done_testing;
