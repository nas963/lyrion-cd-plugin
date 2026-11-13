use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::DriveClient') }

my $C = 'Plugins::AudioCD::DriveClient';

{
	package FakeJob;
	my $PID = 100;
	sub new { my ($c, %a) = @_; bless { %a, pid => ++$PID, in => [], running => 1, closed => 0, killed => 0 }, $c }
	sub pid { $_[0]{pid} }
	sub write_stdin { my ($s, $d) = @_; return 0 unless $s->{running} && !$s->{closed}; push @{ $s->{in} }, $d; 1 }
	sub close_stdin { $_[0]{closed} = 1 }
	sub kill { $_[0]{killed}++ }
	sub is_running { $_[0]{running} }
	sub line { my ($s, $h) = @_; $s->{on_line}->(ref $h ? JSON::PP->new->encode($h) : $h) }
	sub die_now { my ($s, $st) = @_; $s->{running} = 0; $s->{on_exit}->($st // 1) }
	sub cmds { my ($s) = @_; return map { JSON::PP->new->decode($_) } @{ $s->{in} } }
}

sub mk {
	my (%o) = @_;
	my $w = { jobs => [], timers => [], status => [], logs => [], now => 1000, argv_paused => [] };
	$w->{c} = $C->new(
		argv => sub { push @{ $w->{argv_paused} }, $_[0]; return [ 'perl', 'helper', $_[0] ? '--paused' : () ] },
		spawn => sub {
			my %a = @_;
			die "spawn puca\n" if $w->{spawn_fail};
			my $j = FakeJob->new(%a);
			push @{ $w->{jobs} }, $j;
			return $j;
		},
		timer        => sub { my $t = { secs => $_[0], cb => $_[1] }; push @{ $w->{timers} }, $t; return $t },
		cancel_timer => sub { my ($t) = @_; $t->{cancelled} = 1 },
		on_status    => sub { push @{ $w->{status} }, [@_] },
		log          => sub { push @{ $w->{logs} }, [@_] },
		now          => sub { $w->{now} },
		%o,
	);
	return $w;
}
sub job { $_[0]{jobs}[-1] }
sub fire { my ($w, $secs) = @_; my @t = grep { !$_->{cancelled} && !$_->{fired} && (!defined $secs || $_->{secs} == $secs) } @{ $w->{timers} }; for (@t) { $_->{fired} = 1; $_->{cb}->() } return scalar @t }

# ---- pokretanje: stdin pipe, linije, status dogadjaji ----
{
	my $w = mk();
	ok(!$w->{c}->running, 'pre start-a ne radi');
	$w->{c}->start;
	ok($w->{c}->running, 'start: radi');
	is(scalar @{ $w->{jobs} }, 1, 'jedan proces');
	is(job($w)->{stdin}, 'pipe', 'spawn sa stdin => pipe');
	is_deeply(job($w)->{argv}, [ 'perl', 'helper' ], 'argv iz Plugin-a');
	is($w->{c}->pid, job($w)->pid, 'pid pomocnika');
	job($w)->line({ ev => 'status', code => 4 });
	is_deeply($w->{status}, [ [ 4, undef ] ], 'status dogadjaj -> on_status');
	job($w)->line({ ev => 'status', code => undef, err => 'permission' });
	is_deeply($w->{status}[-1], [ undef, 'permission' ], 'status greska -> on_status');
	job($w)->line('Use of uninitialized value at ...');
	is($w->{logs}[-1][0], 'warn', 'ne-JSON linija (stderr pomocnika) se loguje');
	$w->{c}->start;
	is(scalar @{ $w->{jobs} }, 1, 'drugi start dok radi: nista');
}

# ---- TOC zahtev: id, odgovor, zakasneli/nepoznat odgovor ----
{
	my $w = mk();
	$w->{c}->start;
	my @got;
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	my ($m) = job($w)->cmds;
	is($m->{cmd}, 'toc', 'toc komanda');
	is($m->{dev}, '/dev/sr0', 'toc: uredjaj');
	ok($m->{id}, 'toc: id');
	is(scalar @got, 0, 'odgovor jos nije stigao');
	my $toc = { first => 1, last => 1, leadout => 100, tracks => [ { n => 1, lba => 0, data => 0 } ] };
	job($w)->line({ ev => 'toc', id => $m->{id}, toc => $toc });
	is_deeply(\@got, [ [ $toc, undef ] ], 'toc: callback sa TOC-om');
	job($w)->line({ ev => 'toc', id => $m->{id}, toc => $toc });
	is(scalar @got, 1, 'ponovljen odgovor se ignorise');
	ok((grep { $_->{cancelled} } @{ $w->{timers} }), 'rok zahteva otkazan posle odgovora');

	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	my $id = (job($w)->cmds)[-1]{id};
	job($w)->line({ ev => 'toc', id => $id, toc => undef, err => 'no_disc' });
	is_deeply($got[-1], [ undef, 'no_disc' ], 'toc: greska');
}

# ---- status i eject na zahtev ----
{
	my $w = mk();
	$w->{c}->start;
	my (@st, @ej);
	$w->{c}->request_status('/dev/sr0', sub { push @st, [@_] });
	my $m = (job($w)->cmds)[-1];
	is($m->{cmd}, 'status', 'status komanda');
	job($w)->line({ ev => 'status', id => $m->{id}, code => 2 });
	is_deeply(\@st, [ [ 2, undef ] ], 'status na zahtev -> callback');
	is(scalar @{ $w->{status} }, 0, 'odgovor na zahtev ne ide u on_status');
	$w->{c}->eject('/dev/sr0', sub { push @ej, [@_] });
	$m = (job($w)->cmds)[-1];
	is($m->{cmd}, 'eject', 'eject komanda');
	job($w)->line({ ev => 'eject', id => $m->{id}, ok => 0, err => 'io' });
	is_deeply(\@ej, [ [ 0, 'io' ] ], 'eject odgovor');
}

# ---- pomocnik ne radi: zahtev odmah dobija gresku 'helper' ----
{
	my $w = mk();
	my @got;
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	is_deeply(\@got, [ [ undef, 'helper' ] ], 'bez pomocnika: toc -> helper');
	$w->{c}->eject('/dev/sr0', sub { push @got, [@_] });
	is_deeply($got[-1], [ 0, 'helper' ], 'bez pomocnika: eject -> helper');
}

# ---- rok zahteva: greska 'timeout' i pomocnik se ubija ----
{
	my $w = mk(timeout => 45);
	$w->{c}->start;
	my @got;
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	is(fire($w, 45), 1, 'rok zahteva istekao');
	is_deeply(\@got, [ [ undef, 'drive_timeout' ] ], 'timeout -> callback (drive_timeout)');
	is(job($w)->{killed}, 1, 'zaglavljen pomocnik se ubija');
	my $id = (job($w)->cmds)[-1]{id};
	job($w)->line({ ev => 'toc', id => $id, toc => undef, err => 'io' });
	is(scalar @got, 1, 'odgovor posle roka se ignorise');
}

# ---- pad pomocnika: zahtevi u toku dobijaju 'helper', restart sa backoff-om ----
{
	my $w = mk(backoff => [ 1, 5, 30 ], stable => 60);
	$w->{c}->start;
	my @got;
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	my @w;
	job($w)->die_now(9);
	is_deeply(\@got, [ [ undef, 'helper' ] ], 'pad: zahtev u toku dobija gresku');
	ok(!$w->{c}->running, 'pad: ne radi');
	ok((grep { $_->[0] eq 'warn' } @{ $w->{logs} }), 'pad se loguje');
	is(fire($w, 1), 1, 'restart posle 1 s');
	is(scalar @{ $w->{jobs} }, 2, 'restartovan');
	job($w)->die_now(1);
	is(fire($w, 5), 1, 'drugi pad: restart posle 5 s');
	job($w)->die_now(1);
	is(fire($w, 30), 1, 'treci pad: 30 s');
	job($w)->die_now(1);
	is(fire($w, 30), 1, 'backoff ostaje na poslednjoj vrednosti');
	$w->{now} += 100;    # radio je stabilno
	job($w)->die_now(1);
	is(fire($w, 1), 1, 'posle stabilnog rada backoff ispocetka');

	# spawn puca: isto kao pad, ponovni pokusaj
	$w->{spawn_fail} = 1;
	job($w)->die_now(1);
	my $n = @{ $w->{jobs} };
	fire($w);
	is(scalar @{ $w->{jobs} }, $n, 'spawn puca: nema procesa');
	ok(!$w->{c}->running, 'spawn puca: ne radi');
	$w->{spawn_fail} = 0;
	fire($w);
	ok($w->{c}->running, 'spawn ponovo radi: pomocnik pokrenut');
}

# ---- pauza: salje se samo promena; restart pocinje u pauzi ako je drajv zauzet ----
{
	my $w = mk();
	$w->{c}->start;
	$w->{c}->set_paused(1);
	$w->{c}->set_paused(1);
	is_deeply([ map { $_->{cmd} } job($w)->cmds ], ['pause'], 'pause samo jednom');
	ok($w->{c}->paused, 'paused');
	$w->{c}->set_paused(0);
	is_deeply([ map { $_->{cmd} } job($w)->cmds ], [ 'pause', 'resume' ], 'resume');
	$w->{c}->set_paused(1);
	job($w)->die_now(1);
	fire($w);
	is($w->{argv_paused}[-1], 1, 'restart u pauzi: argv dobija paused');
	is_deeply([ job($w)->cmds ], [], 'restart u pauzi: nema dodatne komande');
	$w->{c}->configure(dev => '/dev/sr1', poll => 0);
	is_deeply((job($w)->cmds)[-1], { cmd => 'config', dev => '/dev/sr1', poll => 0 }, 'config komanda');
}

# ---- stop: quit, EOF, kill; bez restarta ----
{
	my $w = mk();
	$w->{c}->start;
	my @got;
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	$w->{c}->stop;
	my $j = job($w);
	is((($j->cmds)[-1] // {})->{cmd}, 'quit', 'stop: quit');
	ok($j->{closed}, 'stop: stdin zatvoren');
	is($j->{killed}, 1, 'stop: kill');
	is_deeply(\@got, [ [ undef, 'helper' ] ], 'stop: zahtev u toku dobija gresku');
	$j->die_now(143);
	is(fire($w), 0, 'posle stop-a nema restarta');
	ok(!$w->{c}->running, 'stop: ne radi');
	$w->{c}->request_toc('/dev/sr0', sub { push @got, [@_] });
	is_deeply($got[-1], [ undef, 'helper' ], 'posle stop-a: zahtev -> helper');
}

# ---- pending_count: zahtevi u toku (Plugin ceka sa izbacivanjem dok TOC ioctl traje) ----
{
	my $w = mk();
	my $c = $w->{c};
	ok($c->can('pending_count'), 'pending_count postoji');
	my $pc = sub { $c->can('pending_count') ? $c->pending_count : -1 };
	is($pc->(), 0, 'pending_count: 0 pre zahteva');
	$c->start;
	$c->request_toc('/dev/sr0', sub { });
	$c->request_status('/dev/sr0', sub { });
	is($pc->(), 2, 'pending_count: dva zahteva u toku');
	my @ids = map { $_->{id} } job($w)->cmds;
	job($w)->line({ ev => 'toc', id => $ids[0], toc => undef, err => 'no_disc' });
	is($pc->(), 1, 'pending_count: posle odgovora');
	fire($w, 45);
	is($pc->(), 0, 'pending_count: posle roka');
	$c->request_toc('/dev/sr0', sub { });
	job($w)->die_now(1);
	is($pc->(), 0, 'pending_count: pomocnik umro -> 0');
	$c->request_toc('/dev/sr0', sub { });    # pomocnik ne radi: odmah 'helper', nista ne ceka
	is($pc->(), 0, 'pending_count: zahtev bez pomocnika ne ceka');
}

# ---- izuzetak u callback-u ne obara klijenta ----
{
	my $w = mk();
	$w->{c}->start;
	$w->{c}->request_toc('/dev/sr0', sub { die "puca\n" });
	my $id = (job($w)->cmds)[-1]{id};
	job($w)->line({ ev => 'toc', id => $id, toc => undef, err => 'io' });
	ok((grep { $_->[1] =~ /puca/ } @{ $w->{logs} }), 'izuzetak u callback-u se loguje');
	ok($w->{c}->running, 'klijent radi dalje');
}

done_testing;
