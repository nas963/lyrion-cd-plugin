package Plugins::AudioCD::Eject;

# Izbacivanje diska bez blokiranja LMS-a: alat `eject` preko Jobs-a (low_prio, asinhrono); USB slim
# drajvovi ignorisu CDROMEJECT ioctl. Samo ako alata nema, rezerva je CDROMEJECT u pomocnom procesu
# (DriveClient::eject): u LMS procesu nema ioctl-a na drajvu.

use strict;
use warnings;
use utf8;

# eject_async($dev, done => sub, [tool => $putanja|undef, spawn => sub(%a),
#             fallback => sub($dev, $cb->($ok, $err)), warn => sub($msg)])
# $done se zove tacno jednom: kad alat izadje (status != 0 se upozorava sa izlazom alata),
# kad spawn ne uspe, ili kad rezerva javi rezultat.
sub eject_async {
	my ($dev, %o) = @_;
	my $fired = 0;
	my $warn = sub { $o{warn}->(@_) if $o{warn} };
	my $finish = sub { return if $fired++; eval { $o{done}->() if $o{done}; 1 } or $warn->("eject done: $@") };
	my $tool = exists $o{tool} ? $o{tool} : do { require Plugins::AudioCD::Tools; Plugins::AudioCD::Tools::find('eject') };
	unless ($tool) {
		unless ($o{fallback}) {
			$warn->('izbacivanje nije uspelo: alat eject ne postoji');
			return $finish->();
		}
		my $ok = eval {
			$o{fallback}->($dev, sub {
				my ($r, $err) = @_;
				$warn->('izbacivanje nije uspelo (' . ($err // 'ioctl') . '), alat eject ne postoji') unless $r;
				$finish->();
			});
			1;
		};
		unless ($ok) {
			$warn->("izbacivanje nije uspelo: $@");
			$finish->();
		}
		return;
	}
	require Plugins::AudioCD::Jobs;
	my $spawn = $o{spawn} || sub { Plugins::AudioCD::Jobs->spawn(@_) };
	my @tail;
	my $job = eval {
		$spawn->(
			argv    => [ Plugins::AudioCD::Jobs::low_prio($tool, $dev) ],
			on_line => sub { push @tail, $_[0]; shift @tail while @tail > 5 },
			on_exit => sub {
				my ($st) = @_;
				$warn->("eject $dev: status $st" . (@tail ? ': ' . join(' | ', @tail) : '')) if $st;
				$finish->();
			},
		);
	};
	unless ($job) {
		$warn->("eject $dev: pokretanje alata nije uspelo" . ($@ ? ": $@" : ''));
		$finish->();
	}
	return;
}

# when_drive_free(busy => sub -> 0|1, timer => sub($s, $cb), delay => $s, tries => N,
#                 run => sub, give_up => sub)
# Odlozeno izbacivanje: provera na svakih $delay s (prva posle pauze, jer prekinuti procesi umiru
# asinhrono); run kad drajv vise niko ne drzi (procesi, zahtev pomocnika u toku), give_up posle tries.
sub when_drive_free {
	my (%o) = @_;
	my $tries = 0;
	my $wait;
	$wait = sub {
		unless ($o{busy}->()) { undef $wait; return $o{run}->() }
		if (++$tries > $o{tries}) { undef $wait; return $o{give_up}->() }
		$o{timer}->($o{delay}, $wait);
	};
	$o{timer}->($o{delay}, $wait);
	return;
}

1;
