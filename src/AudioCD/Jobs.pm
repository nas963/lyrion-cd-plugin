package Plugins::AudioCD::Jobs;

# Pokretanje spoljnih procesa niskog prioriteta: fork u sopstvenoj grupi procesa,
# stdout+stderr u pipe koji se cita neblokirajuce (linije se dele i po \n i po \r),
# ubijanje cele grupe. Cist Perl; LMS-ov event loop se ubacuje preko set_io_backend().
#
# Backend: { add_read => sub($fh, $cb), remove_read => sub($fh),
#            timer => sub($sekundi, $cb) -> $handle, cancel_timer => sub($handle) (opciono) }
#   child => sub($pid, $cb->($wait_status)) (opciono): event loop koji sam pokuplja decu (LMS-ov EV
#   ima SIGCHLD handler pa bi waitpid vratio -1) javlja sirov wait status; bez njega Jobs radi waitpid.
# Podrazumevani backend je mali select() loop koji pokrece run_loop_for_tests().

use strict;
use warnings;
use utf8;

use POSIX ();
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Encode ();
use Time::HiRes ();
use Plugins::AudioCD::Tools;

my %JOBS;    # pid => $job (zivi poslovi)
my $BACKEND;

# ---------- komanda ----------

sub low_prio {
	my (@argv) = @_;
	my @prefix = ('nice', '-n', '10');
	push @prefix, 'ionice', '-c3' if defined Plugins::AudioCD::Tools::find('ionice');
	return (@prefix, @argv);
}

sub shell_quote {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/'/'\\''/g;
	return "'$s'";
}

# pipeline(\@a, \@b) -> argv za bash koji vraca gresku i kad prvi stepen padne
sub pipeline {
	my ($a, $b) = @_;
	my $cmd = join(' ', map { shell_quote($_) } @$a) . ' | ' . join(' ', map { shell_quote($_) } @$b);
	return ('/bin/bash', '-c', "set -o pipefail; $cmd");
}

# ---------- backend ----------

sub set_io_backend {
	my ($b) = @_;
	$BACKEND = $b;
	return;
}

sub _backend { $BACKEND ||= _default_backend() }

my (%T_READ, @T_TIMERS, $T_SEQ);

sub _default_backend {
	return {
		add_read    => sub { my ($fh, $cb) = @_; $T_READ{ fileno $fh } = [ $fh, $cb ] },
		remove_read => sub { my ($fh) = @_; my $n = fileno $fh; delete $T_READ{$n} if defined $n },
		timer       => sub {
			my ($secs, $cb) = @_;
			my $t = { id => ++$T_SEQ, due => Time::HiRes::time() + $secs, cb => $cb };
			push @T_TIMERS, $t;
			return $t;
		},
		cancel_timer => sub { my ($t) = @_; @T_TIMERS = grep { $_ != $t } @T_TIMERS },
	};
}

sub _run_once {
	my ($max) = @_;
	my $now  = Time::HiRes::time();
	my $wait = $max;
	for my $t (@T_TIMERS) {
		my $d = $t->{due} - $now;
		$d = 0 if $d < 0;
		$wait = $d if $d < $wait;
	}
	my $rin = '';
	vec($rin, $_, 1) = 1 for keys %T_READ;
	if ($rin ne '') {
		my $n = select(my $rout = $rin, undef, undef, $wait);
		if ($n && $n > 0) {
			for my $fn (keys %T_READ) {
				next unless vec($rout, $fn, 1);
				my $e = $T_READ{$fn} or next;
				$e->[1]->($e->[0]);
			}
		}
	}
	else {
		Time::HiRes::sleep($wait) if $wait > 0;
	}
	$now = Time::HiRes::time();
	my @due = grep { $_->{due} <= $now } @T_TIMERS;
	@T_TIMERS = grep { $_->{due} > $now } @T_TIMERS;
	$_->{cb}->() for @due;
	return;
}

# Pumpa citanja i tajmere dok svi poslovi ne zavrse ili istekne $timeout. Vraca 1 ako su svi zavrseni.
sub run_loop_for_tests {
	my ($timeout) = @_;
	$timeout = 10 unless defined $timeout;
	my $deadline = Time::HiRes::time() + $timeout;
	while (%JOBS) {
		my $left = $deadline - Time::HiRes::time();
		return 0 if $left <= 0;
		_run_once($left < 0.1 ? $left : 0.1);
	}
	return 1;
}

# ---------- poslovi ----------

# spawn(argv => [...], on_line => sub($line), on_exit => sub($status), cwd => $dir, umask => 022) -> $job
# $status je izlazni kod, 128+signal ako je proces ubijen signalom, a 255 ako se status ne moze
# saznati (waitpid je vratio -1, npr. ECHILD zbog SIGCHLD=IGNORE).
sub spawn {
	my ($class, %a) = @_;
	my @argv = @{ $a{argv} || [] };
	die "Jobs->spawn: argv je prazan\n" unless @argv;
	for (@argv) {
		$_ = '' unless defined $_;
		utf8::encode($_) if utf8::is_utf8($_);    # exec bi inace spustio znakove < 256 na latin-1
		s/\0//g;                                  # NUL bi tiho presekao argument u exec-u
	}
	my $be = _backend();

	STDOUT->flush;    # da dete ne udvostruci neispraznjen bafer
	STDERR->flush;
	pipe(my $rd, my $wr) or die "pipe: $!\n";
	my $pid = fork();
	die "fork: $!\n" unless defined $pid;

	if (!$pid) {
		# dete: sopstvena grupa, stdin /dev/null, stdout+stderr u pipe
		eval {
			POSIX::setpgid(0, 0);
			$SIG{PIPE} = 'DEFAULT';    # LMS moze da ih ignorise, a ignorisanje se nasledjuje kroz exec
			$SIG{CHLD} = 'DEFAULT';
			# LMS vezuje STDOUT/STDERR za svoj logger (tie bez OPEN): open na njima bi pukao
			for my $h (\*STDIN, \*STDOUT, \*STDERR) { untie *$h if tied *$h }
			close $rd;
			open(STDIN, '<', '/dev/null');
			open(STDOUT, '>&', $wr) or die "dup stdout: $!\n";
			open(STDERR, '>&', $wr) or die "dup stderr: $!\n";
			close $wr;
			chdir $a{cwd} or die "chdir: $!\n" if defined $a{cwd};
			umask($a{umask}) if defined $a{umask};
			exec { $argv[0] } @argv;
			die "exec $argv[0]: $!\n";
		};
		print STDERR $@ if $@;
		POSIX::_exit(127);
	}

	POSIX::setpgid($pid, $pid);    # trka sa detetom: kill odmah posle spawn-a mora da pogodi grupu
	close $wr;
	my $fl = fcntl($rd, F_GETFL, 0);
	fcntl($rd, F_SETFL, $fl | O_NONBLOCK) if defined $fl;

	my $job = bless {
		pid     => $pid,
		fh      => $rd,
		buf     => '',
		on_line => $a{on_line},
		on_exit => $a{on_exit},
		eof     => 0,
		done    => 0,
	}, $class;
	$JOBS{$pid} = $job;
	$be->{add_read}->($rd, sub { $job->_on_readable });
	if ($be->{child}) {
		$job->{child_watch} = 1;
		$be->{child}->($pid, sub { $job->_on_child($_[0]) });
	}
	return $job;
}

sub pid { $_[0]{pid} }

sub _emit {
	my ($self, $line) = @_;
	return unless length $line && $self->{on_line};
	eval { $self->{on_line}->(Encode::decode('UTF-8', $line)); 1 } or warn "Jobs on_line: $@";
	return;
}

sub _on_readable {
	my ($self) = @_;
	return if $self->{eof};
	while (1) {
		my $n = sysread($self->{fh}, my $chunk, 65536);
		if (!defined $n) {
			last if $!{EAGAIN} || $!{EWOULDBLOCK};
			next if $!{EINTR};
			$self->_on_eof;
			return;
		}
		if ($n == 0) {
			$self->_on_eof;
			return;
		}
		$self->{buf} .= $chunk;
		while ($self->{buf} =~ s/\A([^\r\n]*)[\r\n]//) {
			$self->_emit($1);
		}
	}
	return;
}

sub _on_eof {
	my ($self) = @_;
	return if $self->{eof}++;
	_backend()->{remove_read}->($self->{fh});
	close $self->{fh};
	$self->_emit(delete $self->{buf});
	$self->{buf} = '';
	$self->_try_reap;
	return;
}

# Status iz child hook-a; posao se zavrsava kad je i izlaz procitan do kraja (EOF).
sub _on_child {
	my ($self, $raw) = @_;
	return if $self->{done};
	$self->{exit_raw} = defined $raw ? $raw : -1;
	$self->_try_reap if $self->{eof};
	return;
}

# EOF pipe-a ne znaci da je proces gotov (moze da zatvori stdout i nastavi): proveravamo tajmerom
sub _try_reap {
	my ($self) = @_;
	return if $self->{done};
	if ($self->{child_watch}) {
		$self->_finish($self->{exit_raw} < 0 ? 255 : _status($self->{exit_raw})) if defined $self->{exit_raw};
		return;    # status stize iz child hook-a
	}
	my $r = waitpid($self->{pid}, POSIX::WNOHANG());
	if ($r == $self->{pid}) {
		$self->_finish(_status($?));
	}
	elsif ($r == -1) {
		$self->_finish(255);    # status nepoznat: ne sme da prodje kao uspeh
	}
	else {
		$self->{reap_timer} = _backend()->{timer}->(0.05, sub { $self->_try_reap });
	}
	return;
}

sub _status {
	my ($st) = @_;
	return 128 + ($st & 127) if $st & 127;
	return $st >> 8;
}

sub _cancel_timers {
	my ($self) = @_;
	my $be = _backend();
	for my $k (qw(kill_timer reap_timer)) {
		my $t = delete $self->{$k};
		$be->{cancel_timer}->($t) if $t && $be->{cancel_timer};
	}
	return;
}

sub _finish {
	my ($self, $status) = @_;
	return if $self->{done}++;
	$self->_cancel_timers;
	delete $JOBS{ $self->{pid} };
	my $cb = delete $self->{on_exit};
	if ($cb) { eval { $cb->($status); 1 } or warn "Jobs on_exit: $@" }
	return;
}

sub is_running { !$_[0]{done} }

# SIGTERM grupi, posle 5 s SIGKILL
sub kill {
	my ($self) = @_;
	return if $self->{done} || $self->{killed}++;
	CORE::kill('TERM', -$self->{pid});
	$self->{kill_timer} = _backend()->{timer}->(5, sub {
		delete $self->{kill_timer};
		CORE::kill('KILL', -$self->{pid}) unless $self->{done};
	});
	return;
}

# Pokupi sto vise dece ($alive se skracuje), najvise $secs; nikad blokirajuci waitpid.
sub _reap_some {
	my ($alive, $secs) = @_;
	my $deadline = Time::HiRes::time() + $secs;
	while (@$alive && Time::HiRes::time() < $deadline) {
		@$alive = grep { my $r = waitpid($_->{pid}, POSIX::WNOHANG()); !($r == $_->{pid} || $r == -1) } @$alive;
		Time::HiRes::sleep(0.02) if @$alive;
	}
	return;
}

# Za shutdownPlugin: ubij sve grupe, pocisti ih bez pozivanja callback-ova. Ogranicen na ~2 s
# (proces u D stanju na losem disku ne sme da zaglavi gasenje LMS-a).
sub kill_all {
	my @jobs = values %JOBS;
	return unless @jobs;
	my $be = _backend();
	for my $j (@jobs) {
		$j->{on_line} = $j->{on_exit} = undef;
		CORE::kill('TERM', -$j->{pid});
	}
	my @alive = @jobs;
	_reap_some(\@alive, 1);
	# SIGKILL SVIM grupama (ESRCH se ignorise), i kad je vodja otisao: unuk koji ignorise TERM bi ostao sirota
	CORE::kill('KILL', -$_->{pid}) for @jobs;
	_reap_some(\@alive, 1);
	warn sprintf("Jobs::kill_all: nisu pokupljeni pid-ovi: %s\n", join(',', map { $_->{pid} } @alive)) if @alive;
	for my $j (@jobs) {
		unless ($j->{eof}) {
			$be->{remove_read}->($j->{fh});
			close $j->{fh};
		}
		$j->{eof} = $j->{done} = 1;
		$j->_cancel_timers;
		delete $JOBS{ $j->{pid} };
	}
	return;
}

sub running_count { scalar keys %JOBS }

1;
