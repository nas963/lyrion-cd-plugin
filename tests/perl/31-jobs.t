use strict;
use warnings;
use utf8;
use Test::More;
use POSIX ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Jobs') }

my $J = 'Plugins::AudioCD::Jobs';
my @LEFTOVER;    # pid-ovi koje END mora da ubije ako test padne

END { kill 'KILL', @LEFTOVER if @LEFTOVER }

# ---- low_prio ----
my @lp = $J->can('low_prio')->('cyanrip', '-d', '/dev/cdrom');
if (Plugins::AudioCD::Tools::find('ionice')) {
	is_deeply(\@lp, [qw(nice -n 10 ionice -c3 cyanrip -d /dev/cdrom)], 'low_prio sa ionice');
}
else {
	is_deeply(\@lp, [qw(nice -n 10 cyanrip -d /dev/cdrom)], 'low_prio bez ionice');
}

# ---- shell_quote / pipeline ----
is($J->can('shell_quote')->("it's"), q{'it'\''s'}, 'shell_quote apostrof');
is($J->can('shell_quote')->(''), "''", 'shell_quote prazno');

my @pl = $J->can('pipeline')->(['printf', '%s\n', 'Čajkovski é "x" $HOME'], ['cat']);
is($pl[0], '/bin/bash', 'pipeline koristi bash');
is($pl[1], '-c', 'pipeline -c');
like($pl[2], qr/^set -o pipefail; /, 'pipeline pipefail');

sub run_job {
	my (%a) = @_;
	my (@lines, $status);
	my $job = $J->spawn(%a, on_line => sub { push @lines, $_[0] }, on_exit => sub { $status = $_[0] });
	push @LEFTOVER, $job->pid;
	ok($J->can('run_loop_for_tests')->(10), 'posao zavrsen u roku') or diag 'timeout';
	@LEFTOVER = grep { $_ != $job->pid } @LEFTOVER;
	return (\@lines, $status, $job);
}

# ne-ASCII argument prolazi kroz pipeline neokrnjen
{
	my ($lines, $status) = run_job(argv => \@pl);
	is_deeply($lines, ['Čajkovski é "x" $HOME'], 'pipeline: ne-ASCII i metaznaci neokrnjeni');
	is($status, 0, 'pipeline status 0');
}

# pipefail: pad prvog stepena daje ne-nulti status
{
	my (undef, $status) = run_job(argv => [ $J->can('pipeline')->(['sh', '-c', 'echo x; exit 4'], ['cat']) ]);
	is($status, 4, 'pipefail: status prvog stepena');
}

# ---- spawn: \r deli linije, status 3 ----
{
	my ($lines, $status) = run_job(argv => ['sh', '-c', q{printf 'a\rb\nc\n'; exit 3}]);
	is_deeply($lines, [qw(a b c)], 'linije podeljene po \\r i \\n');
	is($status, 3, 'izlazni kod 3');
}

# poslednja linija bez novog reda; stderr se hvata; \r\n ne daje prazne linije
{
	my ($lines, $status) = run_job(argv => ['sh', '-c', q{echo err >&2; printf 'x\r\ny'}]);
	is_deeply([ sort @$lines ], [qw(err x y)], 'stderr i poslednja linija bez \\n');
	is($status, 0, 'status 0');
}

# neuspeo exec -> 127
{
	my ($lines, $status) = run_job(argv => ['/nema/takvog/alata']);
	is($status, 127, 'neuspeo exec daje 127');
	ok(scalar(@$lines), 'poruka o gresci stigla kao linija');
}

# cwd i umask
{
	my ($lines) = run_job(argv => ['sh', '-c', 'pwd; umask; touch f$$; ls -l f$$ | cut -c1-10; rm -f f$$'], cwd => '/tmp', umask => 022);
	is($lines->[0], '/tmp', 'cwd');
	is($lines->[1], '0022', 'umask');
	is($lines->[2], '-rw-r--r--', 'fajl 0644 pod umask 022');
}

# bez zombija: posle zavrsetka waitpid ne nalazi dete
{
	my ($lines, $status, $job) = run_job(argv => ['true']);
	is(waitpid($job->pid, POSIX::WNOHANG()), -1, 'dete je pokupljeno (nema zombija)');
	is($J->can('running_count')->(), 0, 'nema zivih poslova');
}

# ---- kill: proces i unuk nestaju u <= 6 s ----
sub _zombie {
	my $p = shift;
	open my $fh, '<', "/proc/$p/stat" or return 0;
	my $s = <$fh>;
	return $s =~ /\) Z /;
}
sub alive { my $p = shift; return kill(0, $p) && !_zombie($p) }

{
	my ($grandchild, $status);
	my $job = $J->spawn(
		argv    => ['sh', '-c', 'sleep 60 & echo $!; wait'],
		on_line => sub { $grandchild //= $_[0] },
		on_exit => sub { $status = $_[0] },
	);
	push @LEFTOVER, $job->pid;
	my $t0 = time;
	$J->can('run_loop_for_tests')->(0.5);    # da unuk stigne da javi pid
	ok($grandchild && $grandchild =~ /^\d+$/, 'unuk javio pid') or diag "dobio: " . ($grandchild // 'nista');
	push @LEFTOVER, $grandchild if $grandchild;
	ok($job->is_running, 'posao jos radi');
	$job->kill;
	ok($J->can('run_loop_for_tests')->(6), 'kill: posao zavrsen u 6 s');
	ok(time - $t0 <= 7, 'kill brzo');
	is($status, 128 + 15, 'status 143 (SIGTERM)');
	my $gone = 0;
	for (1 .. 20) { if (!alive($grandchild)) { $gone = 1; last } select(undef, undef, undef, 0.1) }
	ok($gone, 'unuk (sleep 60) nestao');
	@LEFTOVER = ();
}

# kill: proces koji ignorise TERM dobija SIGKILL posle 5 s
{
	my $status;
	my $job = $J->spawn(argv => ['sh', '-c', q{trap '' TERM; while :; do sleep 1; done}], on_exit => sub { $status = $_[0] });
	push @LEFTOVER, $job->pid;
	$J->can('run_loop_for_tests')->(0.3);
	my $t0 = time;
	$job->kill;
	ok($J->can('run_loop_for_tests')->(8), 'kill ignorisanog TERM zavrsen');
	ok(time - $t0 >= 4, 'SIGKILL tek posle ~5 s');
	is($status, 128 + 9, 'status 137 (SIGKILL)');
	@LEFTOVER = ();
}

# ---- kill_all ----
{
	my @jobs = map { $J->spawn(argv => ['sh', '-c', 'sleep 60 & wait']) } 1 .. 3;
	push @LEFTOVER, map { $_->pid } @jobs;
	is($J->can('running_count')->(), 3, '3 zivih poslova');
	$J->can('kill_all')->();
	is($J->can('running_count')->(), 0, 'kill_all: nema zivih poslova');
	for my $j (@jobs) {
		is(waitpid($j->pid, POSIX::WNOHANG()), -1, 'kill_all: dete pokupljeno');
		ok(!kill(0, -$j->pid), 'kill_all: grupa nestala');
	}
	@LEFTOVER = ();
}

# kill_all: unuk koji ignorise TERM ne sme da ostane sirota (SIGKILL svim grupama)
{
	my $gc;
	my $job = $J->spawn(
		argv    => ['sh', '-c', q{(trap '' TERM; exec sleep 60) & echo $!; wait}],
		on_line => sub { $gc //= $_[0] },
	);
	push @LEFTOVER, $job->pid;
	$J->can('run_loop_for_tests')->(0.5);
	ok($gc && $gc =~ /^\d+$/, 'unuk (ignorise TERM) javio pid');
	push @LEFTOVER, $gc if $gc;
	my $t0 = time;
	$J->can('kill_all')->();
	ok(time - $t0 <= 4, 'kill_all ogranicen u vremenu');
	my $gone = 0;
	for (1 .. 20) { if (!alive($gc)) { $gone = 1; last } select(undef, undef, undef, 0.1) }
	ok($gone, 'kill_all: unuk koji ignorise TERM ubijen');
	@LEFTOVER = ();
}

# waitpid -1 (SIGCHLD=IGNORE) nije uspeh: status 255
{
	local $SIG{CHLD} = 'IGNORE';
	my (undef, $status) = run_job(argv => ['true']);
	is($status, 255, 'nepoznat status je 255, ne 0');
}

# dete dobija podrazumevani SIGPIPE iako ga roditelj ignorise: yes | head -n1 -> yes umire od SIGPIPE (141)
{
	local $SIG{PIPE} = 'IGNORE';
	my ($lines, $status) = run_job(argv => [ $J->can('pipeline')->(['yes'], ['head', '-n', '1']) ]);
	is_deeply($lines, ['y'], 'pipeline yes | head');
	is($status, 141, 'SIGPIPE podrazumevan u detetu (pipefail daje 141)');
}

# izuzetak u callback-u ne zaglavljuje posao u %JOBS
{
	my @warn;
	local $SIG{__WARN__} = sub { push @warn, @_ };
	my $exited;
	my $job = $J->spawn(
		argv    => ['sh', '-c', 'echo a; echo b'],
		on_line => sub { die "on_line puca\n" },
		on_exit => sub { $exited = $_[0]; die "on_exit puca\n" },
	);
	push @LEFTOVER, $job->pid;
	ok($J->can('run_loop_for_tests')->(5), 'callback koji baca ne zaglavljuje posao');
	is($exited, 0, 'on_exit ipak pozvan');
	is($J->can('running_count')->(), 0, 'nema zivih poslova');
	is(waitpid($job->pid, POSIX::WNOHANG()), -1, 'dete pokupljeno uprkos izuzecima');
	ok((grep { /on_line puca/ } @warn) && (grep { /on_exit puca/ } @warn), 'izuzeci prijavljeni upozorenjem');
	@LEFTOVER = ();
}

# NUL u argumentu se uklanja, ne seče argument
{
	my ($lines) = run_job(argv => ['printf', "%s\n", "ab\0cd"]);
	is_deeply($lines, ['abcd'], 'NUL izbacen iz argumenta');
}

# pipeline: apostrof, backtick, $(...), novi red u argumentu
{
	for my $arg ("it's", 'a`echo X`b', 'a$(echo X)b', "l1\nl2", q{"dq" \\ $HOME ; | &}) {
		my ($lines, $status) = run_job(argv => [ $J->can('pipeline')->(['printf', '%s', $arg], ['cat']) ]);
		is(join("\n", @$lines), join("\n", grep { length } split /[\r\n]/, $arg), "pipeline neokrnjen: " . ($arg =~ s/\n/\\n/gr));
		is($status, 0, 'pipeline status 0');
	}
}

# ---- ubacivanje backenda ----
{
	my (@added, @removed, @timers);
	my $orig = $J->can('_backend')->();
	$J->can('set_io_backend')->({
		add_read     => sub { push @added, $_[0]; $orig->{add_read}->(@_) },
		remove_read  => sub { push @removed, $_[0]; $orig->{remove_read}->(@_) },
		timer        => sub { push @timers, $_[0]; $orig->{timer}->(@_) },
		cancel_timer => $orig->{cancel_timer},
	});
	my ($lines) = run_job(argv => ['echo', 'hi']);
	is_deeply($lines, ['hi'], 'poslovi rade preko ubacenog backenda');
	is(scalar @added, 1, 'add_read pozvan');
	is(scalar @removed, 1, 'remove_read pozvan');
	$J->can('set_io_backend')->($orig);
}

# ---- LMS vezuje (tie) STDOUT/STDERR za svoj logger (Slim::Utils::Log::Trapper bez OPEN) ----
{
	package TiedNoOpen;
	sub TIEHANDLE { bless {}, shift }
	sub PRINT { 1 }
	sub PRINTF { 1 }
	package main;
	tie *STDERR, 'TiedNoOpen';
	tie *STDOUT, 'TiedNoOpen';
	my ($lines, $status) = run_job(argv => ['sh', '-c', 'echo out; echo err >&2']);
	untie *STDOUT;
	untie *STDERR;
	is($status, 0, 'vezan STDERR/STDOUT: dete radi (status 0)');
	is_deeply([ sort @$lines ], [ 'err', 'out' ], 'vezan STDERR/STDOUT: izlaz stize u pipe');
}

# ---- backend sa child hook-om (LMS/EV sam pokuplja decu, waitpid bi dao -1) ----
{
	my $orig = $J->can('_backend')->();
	my @watch;
	$J->can('set_io_backend')->({ %$orig, child => sub { push @watch, [@_]; return 'h' } });
	my ($status, @lines);
	my $job = $J->spawn(argv => ['sh', '-c', 'echo x; exit 3'], on_line => sub { push @lines, $_[0] }, on_exit => sub { $status = $_[0] });
	is(scalar @watch, 1, 'child hook pozvan jednom');
	is($watch[0][0], $job->pid, 'child hook dobija pid');
	# EOF stize, ali bez statusa iz hook-a posao jos nije gotov
	my $t0 = time;
	$J->can('_run_once')->(0.1) while !grep({ $_ eq 'x' } @lines) && time - $t0 < 5;
	$J->can('_run_once')->(0.2) for 1 .. 3;
	ok($job->is_running, 'posle EOF-a ceka status iz child hook-a');
	ok(!defined $status, 'on_exit jos nije pozvan');
	# "EV" pokuplja dete i javlja sirov wait status
	waitpid($job->pid, 0);
	$watch[0][1]->($?);
	is($status, 3, 'status iz child hook-a');
	ok(!$job->is_running, 'posao gotov');
	is_deeply(\@lines, ['x'], 'izlaz procitan');

	# status stigne pre EOF-a: posao se zavrsava tek na EOF (sav izlaz procitan)
	@watch = ();
	my @l2;
	my $st2;
	my $j2 = $J->spawn(argv => ['sh', '-c', 'echo y; exit 0'], on_line => sub { push @l2, $_[0] }, on_exit => sub { $st2 = $_[0] });
	waitpid($j2->pid, 0);
	$watch[0][1]->($?);
	ok(!defined $st2, 'status pre EOF-a: jos se cita izlaz');
	ok($J->can('run_loop_for_tests')->(5), 'posao zavrsen posle EOF-a');
	is($st2, 0, 'status 0');
	is_deeply(\@l2, ['y'], 'izlaz pre zavrsetka');
	$J->can('set_io_backend')->($orig);
}

done_testing;
