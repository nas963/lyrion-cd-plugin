package Plugins::AudioCD::DriveHelper;

# Pomocni proces za drajv (audiocd-drive): SVI ioctl-ovi na drajvu (CDROM_DRIVE_STATUS, citanje TOC-a,
# rezervni CDROMEJECT) rade ovde, nikad u LMS procesu. Citanje TOC-a na disku koji se tek zavrce zna
# da blokira sekundama (USB slim drajv); blokira se ovaj proces, a LMS petlja radi dalje.
#
# Pokretanje (Plugin, preko Jobs::spawn, nice 10 / ionice idle):
#   perl -I<plugins_root> -MPlugins::AudioCD::DriveHelper -e 'Plugins::AudioCD::DriveHelper::main()' \
#        -- --dev /dev/cdrom --poll 2 [--paused]
#
# Protokol: jedna JSON poruka po liniji (ASCII).
#   stdin (komande):  {"cmd":"pause"} {"cmd":"resume"} {"cmd":"config","dev":..,"poll":N}
#                     {"cmd":"toc","id":N[,"dev":..]} {"cmd":"status","id":N} {"cmd":"eject","id":N} {"cmd":"quit"}
#   stdout (dogadjaji): {"ev":"status","code":N|null[,"err":..]}           polling: na startu i na promenu
#                       {"ev":"status","id":N,"code":..[,"err":..]}       odgovor na status
#                       {"ev":"toc","id":N,"toc":{...}|null[,"err":..]}   odgovor na toc
#                       {"ev":"eject","id":N,"ok":0|1[,"err":..]}         odgovor na eject
#                       {"ev":"error","err":"bad_cmd"|"bad_json"}
# Pauza (dok drajv cita drugi proces: cd-paranoia, cyanrip, cd-info, eject): nema polling-a; posle
# resume se status salje ponovo i bez promene (promena tokom posla je mozda propustena). Poll 0:
# status samo jednom na startu, zahtevi i dalje rade. Uredjaj se otvara za svaku operaciju
# (O_RDONLY|O_NONBLOCK) i odmah zatvara. EOF na stdin-u (LMS ugasen ili pao) gasi pomocnika.

use strict;
use warnings;
use utf8;

use JSON::PP ();
use Time::HiRes ();

my $JSON = JSON::PP->new->ascii->canonical;

# new(dev, poll, paused, status => sub($dev), toc => sub($dev), eject => sub($dev), out => sub($linija))
sub new {
	my ($class, %o) = @_;
	my %io;
	for my $k (qw(status toc eject)) {
		next if $o{$k};
		require Plugins::AudioCD::Drive;
		%io = (status => \&Plugins::AudioCD::Drive::drive_status, toc => \&Plugins::AudioCD::Drive::read_toc,
			eject => \&Plugins::AudioCD::Drive::eject);
		last;
	}
	return bless {
		dev    => defined $o{dev} && length $o{dev} ? $o{dev} : '/dev/cdrom',
		poll   => _poll($o{poll}),
		paused => $o{paused} ? 1 : 0,
		status => $o{status} || $io{status},
		toc    => $o{toc} || $io{toc},
		eject  => $o{eject} || $io{eject},
		out    => $o{out} || sub { print STDOUT $_[0] },
		last   => undef,
		force  => 1,    # status na startu
	}, $class;
}

sub _poll { my ($p) = @_; return defined $p && $p =~ /^\d+(?:\.\d+)?\z/ && $p > 0 ? $p + 0 : 0 }

sub paused { $_[0]{paused} }

# Interval polling-a u sekundama, ili undef (bez periodicnog tick-a).
sub interval { my ($self) = @_; return $self->{poll} > 0 ? $self->{poll} : undef }

sub _emit {
	my ($self, %ev) = @_;
	delete $ev{err} unless defined $ev{err};
	$self->{out}->($JSON->encode(\%ev) . "\n");
	return;
}

# Poziv ioctl funkcije: izuzetak (ne bi smeo da se desi) postaje 'io', pomocnik ne pada.
sub _call {
	my ($self, $what, $dev) = @_;
	my @r = eval { $self->{$what}->($dev) };
	return (undef, 'io') if $@;
	return @r;
}

# Polling korak: status drajva, dogadjaj samo na promenu (ili posle starta/resume).
sub tick {
	my ($self) = @_;
	return if $self->{paused};
	return unless $self->{force} || $self->{poll} > 0;
	my ($code, $err) = $self->_call(status => $self->{dev});
	$err = 'io' if !defined $code && !defined $err;
	my $key = defined $code ? "c$code" : "e$err";
	if ($self->{force} || !defined $self->{last} || $self->{last} ne $key) {
		$self->_emit(ev => 'status', code => defined $code ? $code + 0 : undef, err => defined $code ? undef : $err);
	}
	$self->{last}  = $key;
	$self->{force} = 0;
	return;
}

# Jedna linija sa stdin-a. Vraca 0 za quit (kraj petlje), inace 1.
sub handle_line {
	my ($self, $line) = @_;
	return 1 unless defined $line && $line =~ /\S/;
	my $m = eval { JSON::PP->new->decode($line) };
	unless (ref $m eq 'HASH') {
		$self->_emit(ev => 'error', err => 'bad_json');
		return 1;
	}
	my $cmd = $m->{cmd} // '';
	my $dev = defined $m->{dev} && !ref $m->{dev} && length $m->{dev} ? $m->{dev} : $self->{dev};
	my $id  = $m->{id};
	if ($cmd eq 'pause') {
		$self->{paused} = 1;
	}
	elsif ($cmd eq 'resume') {
		$self->{force} = 1 if $self->{paused} && $self->{poll} > 0;
		$self->{paused} = 0;
	}
	elsif ($cmd eq 'config') {
		$self->{dev} = $dev;
		if (exists $m->{poll}) {
			my $was = $self->{poll};
			$self->{poll} = _poll($m->{poll});
			$self->{force} = 1 if !$was && $self->{poll};    # polling ukljucen: javi trenutno stanje
		}
	}
	elsif ($cmd eq 'toc') {
		my ($toc, $err) = $self->_call(toc => $dev);
		$err = 'io' if !$toc && !defined $err;
		$self->_emit(ev => 'toc', id => $id, toc => $toc, err => $toc ? undef : $err);
	}
	elsif ($cmd eq 'status') {
		my ($code, $err) = $self->_call(status => $dev);
		$err = 'io' if !defined $code && !defined $err;
		$self->_emit(ev => 'status', id => $id, code => defined $code ? $code + 0 : undef, err => defined $code ? undef : $err);
	}
	elsif ($cmd eq 'eject') {
		my ($ok, $err) = $self->_call(eject => $dev);
		$self->_emit(ev => 'eject', id => $id, ok => $ok ? 1 : 0, err => $ok ? undef : ($err // 'io'));
	}
	elsif ($cmd eq 'quit') {
		return 0;
	}
	else {
		$self->_emit(ev => 'error', err => 'bad_cmd');
	}
	return 1;
}

# Glavna petlja procesa: select na stdin-u sa rokom za sledeci polling.
sub main {
	my %o = (dev => '/dev/cdrom', poll => 2, paused => 0);
	my @a = @ARGV;
	while (@a) {
		my $k = shift @a;
		if    ($k eq '--dev')    { $o{dev} = shift @a }
		elsif ($k eq '--poll')   { $o{poll} = shift @a }
		elsif ($k eq '--paused') { $o{paused} = 1 }
	}
	$0 = 'audiocd-drive';     # ime u ps / top
	$SIG{PIPE} = 'DEFAULT';    # LMS ugasen: upis na stdout gasi proces
	binmode STDOUT;
	STDOUT->autoflush(1);
	my $h = __PACKAGE__->new(%o);
	$h->tick;
	my $next = Time::HiRes::time() + ($h->interval // 0);
	my $buf = '';
	while (1) {
		my $iv = $h->interval;
		my $wait;
		if (defined $iv && !$h->paused) {
			$wait = $next - Time::HiRes::time();
			$wait = 0 if $wait < 0;
		}
		my $rin = '';
		vec($rin, fileno(STDIN), 1) = 1;
		my $n = select(my $rout = $rin, undef, undef, $wait);
		if ($n && $n > 0) {
			my $r = sysread(STDIN, my $chunk, 4096);
			if (!defined $r) {
				next if $!{EINTR} || $!{EAGAIN};
				last;
			}
			last if $r == 0;    # EOF: LMS vise ne postoji
			$buf .= $chunk;
			while ($buf =~ s/\A([^\n]*)\n//) {
				return 0 unless $h->handle_line($1);
			}
			$h->tick if $h->{force};    # resume / ukljucen polling: status odmah
		}
		$iv = $h->interval;
		if (defined $iv && !$h->paused && Time::HiRes::time() >= $next) {
			$h->tick;
			$next = Time::HiRes::time() + $iv;
		}
	}
	return 0;
}

1;
