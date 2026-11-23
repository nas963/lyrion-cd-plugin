use strict;
use warnings;
use utf8;
use Test::More;

# Premesti u biblioteku sa izborom odredista: pregled foldera biblioteke, nov folder, odrediste.

use File::Temp ();
use Plugins::AudioCD::Library;
use Plugins::AudioCD::Naming;

my $root = File::Temp::tempdir(CLEANUP => 1);
my $fs = \&Plugins::AudioCD::Naming::fs_bytes;
my $mk = sub { my $p = $fs->($_[0]); my @parts = split m{/}, $p; my $acc = ''; for (@parts) { next unless length; $acc .= "/$_"; mkdir $acc } };
my ($cd, $sacd) = ("$root/Muzika/CD", "$root/Muzika/SACD");
$mk->("$cd/$_") for ('Enigma', 'enya', 'Đorđe Balašević', 'AC-DC', '.hidden');
$mk->("$sacd/Pink Floyd");
open(my $f, '>', $fs->("$cd/notes.txt")) or die; close $f;
my @media = ($cd, $sacd);

# koreni
my ($b, $e) = Plugins::AudioCD::Library::browse('', \@media);
is_deeply([ map { $_->{path} } @{ $b->{dirs} } ], \@media, 'bez putanje: muzicki folderi');
ok(!defined $b->{parent}, 'koren nema roditelja');

($b) = Plugins::AudioCD::Library::browse($cd, \@media);
is_deeply([ map { $_->{name} } @{ $b->{dirs} } ], [ 'AC-DC', 'Enigma', 'enya', 'Đorđe Balašević' ], 'izvodjaci: sortirano bez obzira na velika slova, bez skrivenih i fajlova');
ok(!defined $b->{parent}, 'muzicki folder: nema roditelja (ne ide iznad biblioteke)');
($b) = Plugins::AudioCD::Library::browse("$cd/Enigma", \@media);
is($b->{parent}, $cd, 'roditelj izvodjaca');
is_deeply($b->{dirs}, [], 'prazan folder izvodjaca');

(undef, $e) = Plugins::AudioCD::Library::browse("$root/Muzika", \@media);
is($e, 'outside_library', 'iznad muzickog foldera: odbijeno');
(undef, $e) = Plugins::AudioCD::Library::browse("$cd/../..", \@media);
is($e, 'outside_library', '.. odbijeno');
(undef, $e) = Plugins::AudioCD::Library::browse("$cd/Nema", \@media);
is($e, 'not_found', 'nepostojeci folder');
($b) = Plugins::AudioCD::Library::browse($cd, \@media, limit => 2);
ok($b->{truncated} && @{ $b->{dirs} } == 2, 'ogranicenje broja foldera');

# nov folder
my ($nd, $ne) = Plugins::AudioCD::Library::make_dir($cd, 'Bob Marley: Live?', \@media);
is($nd, "$cd/Bob Marley- Live", 'nov folder: bezbedno ime');
ok(-d $fs->($nd), 'nov folder napravljen');
($nd) = Plugins::AudioCD::Library::make_dir($cd, 'Enigma', \@media);
is($nd, "$cd/Enigma", 'postojeci folder: vraca se');
(undef, $ne) = Plugins::AudioCD::Library::make_dir($cd, 'notes.txt', \@media);
is($ne, 'exists', 'ime fajla: exists');
(undef, $ne) = Plugins::AudioCD::Library::make_dir($cd, '  ', \@media);
is($ne, 'bad_name', 'prazno ime');
(undef, $ne) = Plugins::AudioCD::Library::make_dir("$root/x", 'A', \@media);
is($ne, 'outside_library', 'van biblioteke');

# odrediste premestanja
my $rips = "$root/CD-Rips";
$mk->("$rips/Enigma/The Cross of Changes");
my ($dest, $err) = Plugins::AudioCD::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", undef, $rips, \@media);
is($dest, "$cd/Enigma/The Cross of Changes", 'podrazumevano ime = ime foldera rip-a');
($dest) = Plugins::AudioCD::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", 'Enigma - The Cross of Changes (1993)', $rips, \@media);
is($dest, "$cd/Enigma/Enigma - The Cross of Changes (1993)", 'zadato ime');
$mk->("$cd/Enigma/Taken");
(undef, $err) = Plugins::AudioCD::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/Enigma", 'Taken', $rips, \@media);
is($err, 'exists', 'postoji: nikad se ne prepisuje');
(undef, $err) = Plugins::AudioCD::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$root/Muzika", undef, $rips, \@media);
is($err, 'outside_library', 'odrediste van biblioteke');
(undef, $err) = Plugins::AudioCD::Library::plan_move_to("$root/x/y", "$cd/Enigma", undef, $rips, \@media);
is($err, 'outside_rips', 'izvor van rip foldera');
# odrediste samo za citanje (npr. mrezno deljenje montirano ro): not_writable pre kopiranja
$mk->("$cd/RO");
chmod 0555, "$cd/RO";
SKIP: {
	skip 'folder 0555 je i dalje upisiv (root ili FS bez prava)', 1 if -w "$cd/RO";
	(undef, $err) = Plugins::AudioCD::Library::plan_move_to("$rips/Enigma/The Cross of Changes", "$cd/RO", undef, $rips, \@media);
	is($err, 'not_writable', 'odrediste samo za citanje: not_writable');
}
chmod 0755, "$cd/RO";

# celo premestanje (isti FS)
my ($ok, $merr) = Plugins::AudioCD::Library::move("$rips/Enigma/The Cross of Changes", "$cd/Enigma/The Cross of Changes", rips_root => $rips);
ok($ok, 'premesteno') or diag $merr;
ok(-d $fs->("$cd/Enigma/The Cross of Changes"), 'na odredistu');
ok(!-d $fs->("$rips/Enigma"), 'prazan folder izvodjaca u rip folderu uklonjen');
done_testing;
