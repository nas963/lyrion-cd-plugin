package Plugins::AudioCD::DriveClient;

# LMS strana pomocnog procesa za drajv (DriveHelper.pm): pokretanje preko Jobs-a (stdin pipe),
# zahtevi sa id-om i rokom, dogadjaji statusa, pauza dok drajv cita drugi proces, restart sa
# backoff-om ako pomocnik umre. Nijedan ioctl ne radi ovde: LMS petlja nikad ne ceka na drajv.
# Cist Perl; spawn i tajmeri se ubacuju (Plugin: Jobs + LMS tajmeri, testovi: lazni).
#
# new(argv => sub($paused) -> [argv], spawn => sub(%a) -> $job, timer => sub($s, $cb) -> $h,
#     cancel_timer => sub($h), on_status => sub($code, $err), log => sub($nivo, $poruka),
#     [timeout => 45, backoff => [1, 2, 5, 10, 30, 60], stable => 60, now => sub])
# Callback-ovi zahteva: toc -> ($toc, $err), status -> ($code, $err), eject -> ($ok, $err).
# Greske koje ne dolaze od drajva: 'helper' (pomocnik ne radi ili je umro), 'drive_timeout'.

use strict;
use warnings;
use utf8;

use JSON::PP ();
use Time::HiRes ();

use constant TIMEOUT => 45;    # s; TOC na disku koji se zavrce traje par sekundi, ne minut

my $JSON = JSON::PP->new->ascii->canonical;

sub new {
	my ($class, %o) = @_;
	for (qw(argv spawn timer)) { die "DriveClient: $_ je obavezan\n" unless $o{$_} }
	return bless {
		%o,
		timeout  => $o{timeout} // TIMEOUT,
		backoff  => $o{backoff} || [ 1, 2, 5, 10, 30, 60 ],
		stable   => $o{stable} // 60,
		now      => $o{now} || \&Time::HiRes::time,
		job      => undef,
		pending  => {},    # id => { cb, timer }
		seq      => 0,
		paused   => 0,
		fails    => 0,
		stopped  => 0,
		restart  => undef,
	}, $class;
}

sub _log {
	my ($self, $lvl, $msg) = @_;
	eval { $self->{log}->($lvl, $msg) if $self->{log}; 1 };
	return;
}

sub running { my ($self) = @_; return $self->{job} && $self->{job}->is_running ? 1 : 0 }
sub paused  { $_[0]{paused} }
sub pid     { my ($self) = @_; return $self->{job} ? $self->{job}->pid : undef }

# Pid pomocnika dok proces postoji (i dok umire posle kill-a): Plugin ga ne broji u procese na drajvu.
sub job { $_[0]{job} }

sub start {
	my ($self) = @_;
	return if $self->{stopped} || $self->{job};
	$self->_cancel_restart;
	my $job;
	$job = eval {
		$self->{spawn}->(
			argv    => $self->{argv}->($self->{paused}),
			stdin   => 'pipe',
			on_line => sub { $self->_line($_[0]) },
			on_exit => sub { $self->_exited($job, $_[0]) },
		);
	};
	unless ($job) {
		$self->_log(warn => 'audiocd-drive nije pokrenut: ' . ($@ || 'nema posla'));
		$self->_schedule_restart;
		return;
	}
	$self->{job}     = $job;
	$self->{started} = $self->{now}->();
	return;
}

# Gasenje plugina: quit + EOF + kill, bez restarta; zahtevi u toku dobijaju 'helper'.
sub stop {
	my ($self) = @_;
	$self->{stopped} = 1;
	$self->_cancel_restart;
	$self->_fail_all('helper');
	my $job = $self->{job} or return;
	$job->write_stdin($JSON->encode({ cmd => 'quit' }) . "\n");
	$job->close_stdin;
	$job->kill;
	return;
}

sub _send {
	my ($self, $msg) = @_;
	my $job = $self->{job};
	return 0 unless $job && $job->is_running;
	return $job->write_stdin($JSON->encode($msg) . "\n") ? 1 : 0;
}

# Pauza: samo promena se salje. Pomocnik koji se restartuje pocinje u istom stanju (argv).
sub set_paused {
	my ($self, $p) = @_;
	$p = $p ? 1 : 0;
	return if $p == $self->{paused};
	$self->{paused} = $p;
	$self->_send({ cmd => $p ? 'pause' : 'resume' });
	return;
}

sub configure {
	my ($self, %c) = @_;
	$self->_send({ cmd => 'config', %c });
	return;
}

sub request_toc    { my ($self, $dev, $cb) = @_; return $self->_request('toc',    $dev, $cb, undef, 'helper') }
sub request_status { my ($self, $dev, $cb) = @_; return $self->_request('status', $dev, $cb, undef, 'helper') }
sub eject          { my ($self, $dev, $cb) = @_; return $self->_request('eject',  $dev, $cb, 0,     'helper') }

sub _call {
	my ($self, $cb, @a) = @_;
	eval { $cb->(@a); 1 } or $self->_log(warn => "audiocd-drive callback: $@");
	return;
}

sub _request {
	my ($self, $cmd, $dev, $cb, $fail_val, $err) = @_;
	my $id = ++$self->{seq};
	my $p = $self->{pending}{$id} = { cb => $cb, fail => $fail_val, cmd => $cmd };
	unless ($self->_send({ cmd => $cmd, id => $id, defined $dev ? (dev => $dev) : () })) {
		delete $self->{pending}{$id};
		$self->_call($cb, $fail_val, $err);
		return;
	}
	$p->{timer} = $self->{timer}->($self->{timeout}, sub {
		my $q = delete $self->{pending}{$id} or return;
		delete $q->{timer};
		$self->_log(warn => "audiocd-drive: $cmd bez odgovora $self->{timeout} s; pomocnik se restartuje");
		$self->_call($q->{cb}, $q->{fail}, 'drive_timeout');
		$self->{job}->kill if $self->{job};
	});
	return;
}

sub _done {
	my ($self, $id, @a) = @_;
	return unless defined $id && !ref $id;
	my $p = delete $self->{pending}{$id} or return;
	$self->{cancel_timer}->($p->{timer}) if $p->{timer} && $self->{cancel_timer};
	$self->_call($p->{cb}, @a);
	return;
}

sub _fail_all {
	my ($self, $err) = @_;
	my $pend = $self->{pending};
	$self->{pending} = {};
	for my $id (sort { $a <=> $b } keys %$pend) {
		my $p = $pend->{$id};
		$self->{cancel_timer}->($p->{timer}) if $p->{timer} && $self->{cancel_timer};
		$self->_call($p->{cb}, $p->{fail}, $err);
	}
	return;
}

sub _line {
	my ($self, $line) = @_;
	return unless defined $line && length $line;
	my $m = $line =~ /^\s*\{/ ? eval { JSON::PP->new->decode($line) } : undef;
	unless (ref $m eq 'HASH') {
		$self->_log(warn => "audiocd-drive: $line");
		return;
	}
	my $ev = $m->{ev} // '';
	if ($ev eq 'status') {
		if (defined $m->{id}) { $self->_done($m->{id}, $m->{code}, $m->{err}) }
		elsif ($self->{on_status}) { $self->_call($self->{on_status}, $m->{code}, $m->{err}) }
	}
	elsif ($ev eq 'toc') {
		$self->_done($m->{id}, ref $m->{toc} eq 'HASH' ? $m->{toc} : undef, ref $m->{toc} eq 'HASH' ? undef : ($m->{err} // 'io'));
	}
	elsif ($ev eq 'eject') {
		$self->_done($m->{id}, $m->{ok} ? 1 : 0, $m->{err});
	}
	else {
		$self->_log(warn => "audiocd-drive: $line");
	}
	return;
}

sub _exited {
	my ($self, $job, $status) = @_;
	return if $self->{job} && $job && $self->{job} != $job;
	$self->{job} = undef;
	$self->_fail_all('helper');
	return if $self->{stopped};
	$self->_log(warn => "audiocd-drive je izasao (status " . ($status // '?') . ')');
	$self->{fails} = 0 if defined $self->{started} && $self->{now}->() - $self->{started} >= $self->{stable};
	$self->_schedule_restart;
	return;
}

sub _schedule_restart {
	my ($self) = @_;
	return if $self->{stopped} || $self->{restart};
	my @b = @{ $self->{backoff} };
	my $secs = $b[ $self->{fails} < @b ? $self->{fails} : $#b ];
	$self->{fails}++;
	$self->{restart} = $self->{timer}->($secs, sub {
		$self->{restart} = undef;
		$self->start;
	});
	return;
}

sub _cancel_restart {
	my ($self) = @_;
	my $t = delete $self->{restart} or return;
	$self->{cancel_timer}->($t) if $self->{cancel_timer};
	return;
}

1;
