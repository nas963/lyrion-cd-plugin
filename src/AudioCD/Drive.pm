package Plugins::AudioCD::Drive;

# Status drajva, TOC i izbacivanje diska preko ioctl-a (cist Perl, bez Slim zavisnosti).
#
# TOC: { first, last, leadout, tracks => [ { n, lba, data } ] }, LBA BEZ +150 ofseta.
# Struktura cdrom_tocentry (x86_64, little-endian), 12 bajtova:
#   C track, C adr:4|ctrl:4 (adr = donji nibl), C format, C pad, l addr (union msf/lba), C datamode, x3

use strict;
use warnings;
use utf8;

use Fcntl qw(O_RDONLY O_NONBLOCK);
use Errno ();

use constant {
	CDROMREADTOCHDR    => 0x5305,
	CDROMREADTOCENTRY  => 0x5306,
	CDROMEJECT         => 0x5309,
	CDROM_DRIVE_STATUS => 0x5326,
	CDROM_LBA          => 0x01,
	CDSL_CURRENT       => 0x7fffffff,
	CDROM_LEADOUT      => 0xAA,
	CDS_NO_INFO        => 0,
	CDS_NO_DISC        => 1,
	CDS_TRAY_OPEN      => 2,
	CDS_DRIVE_NOT_READY => 3,
	CDS_DISC_OK        => 4,
};

use constant ENOMEDIUM => 123;    # Errno ga ne izvozi svuda

sub unpack_tochdr {
	my ($bytes) = @_;
	return unpack('C C', $bytes);
}

sub pack_tocentry_req {
	my ($track) = @_;
	return pack('C C C C l C x3', $track, 0, CDROM_LBA, 0, 0, 0);
}

sub unpack_tocentry {
	my ($bytes) = @_;
	my ($n, $adr_ctrl, $format, undef, $lba) = unpack('C C C C l', $bytes);
	return { n => $n, adr_ctrl => $adr_ctrl, data => (($adr_ctrl >> 4) & 0x04) ? 1 : 0, lba => $lba };
}

sub _errname {
	my ($errno) = @_;
	return 'permission' if $errno == Errno::EACCES() || $errno == Errno::EPERM();
	return 'no_device'  if $errno == Errno::ENOENT() || $errno == Errno::ENXIO() || $errno == Errno::ENODEV();
	return 'no_disc'    if $errno == ENOMEDIUM;
	return 'io';
}

sub _open {
	my ($dev) = @_;
	my $fh;
	if (!sysopen($fh, $dev, O_RDONLY | O_NONBLOCK)) {
		return (undef, _errname($! + 0));
	}
	return ($fh, undef);
}

# ($code, $err): code je CDS_* ili undef pri gresci.
sub drive_status {
	my ($dev) = @_;
	my ($fh, $err) = _open($dev);
	return (undef, $err) unless $fh;
	my $r = ioctl($fh, CDROM_DRIVE_STATUS, CDSL_CURRENT);
	if (!defined $r) {
		my $e = _errname($! + 0);
		close $fh;
		return (undef, $e);
	}
	close $fh;
	return (0 + $r, undef);
}

# ($toc, $err)
sub read_toc {
	my ($dev) = @_;
	my ($fh, $err) = _open($dev);
	return (undef, $err) unless $fh;

	my $fail = sub { my $e = _errname($! + 0); close $fh; return (undef, $e) };

	my $hdr = "\0\0";
	return $fail->() unless defined ioctl($fh, CDROMREADTOCHDR, $hdr);
	my ($first, $last) = unpack_tochdr($hdr);
	return (undef, 'no_disc') if !$first || $last < $first;

	my @tracks;
	for my $n ($first .. $last) {
		my $buf = pack_tocentry_req($n);
		return $fail->() unless defined ioctl($fh, CDROMREADTOCENTRY, $buf);
		my $e = unpack_tocentry($buf);
		push @tracks, { n => $n, lba => $e->{lba}, data => $e->{data} };
	}

	my $buf = pack_tocentry_req(CDROM_LEADOUT);
	return $fail->() unless defined ioctl($fh, CDROMREADTOCENTRY, $buf);
	my $leadout = unpack_tocentry($buf)->{lba};
	close $fh;

	return ({ first => $first, last => $last, leadout => $leadout, tracks => \@tracks }, undef);
}

# ($ok, $err): samo ioctl CDROMEJECT.
sub eject {
	my ($dev) = @_;
	my ($fh, $err) = _open($dev);
	return (undef, $err) unless $fh;
	my $r = ioctl($fh, CDROMEJECT, 0);
	my $e = defined $r ? undef : _errname($! + 0);
	close $fh;
	return (defined $r ? 1 : undef, $e);
}

# Izbacivanje bez blokiranja LMS-a: alat `eject` preko Jobs-a (low_prio, asinhrono); USB slim
# drajvovi ignorisu CDROMEJECT ioctl. Samo ako alata nema, pada se na ioctl (eject()).
# eject_async($dev, done => sub, [tool => $putanja|undef, spawn => sub(%a), ioctl => sub($dev), warn => sub($msg)])
# $done se zove tacno jednom: kad alat izadje (status != 0 se upozorava sa izlazom alata),
# kad spawn ne uspe, ili odmah posle ioctl rezerve.
sub eject_async {
	my ($dev, %o) = @_;
	my $fired = 0;
	my $warn = sub { $o{warn}->(@_) if $o{warn} };
	my $finish = sub { return if $fired++; eval { $o{done}->() if $o{done}; 1 } or $warn->("eject done: $@") };
	my $tool = exists $o{tool} ? $o{tool} : do { require Plugins::AudioCD::Tools; Plugins::AudioCD::Tools::find('eject') };
	unless ($tool) {
		my ($ok, $err) = ($o{ioctl} || \&eject)->($dev);
		$warn->('izbacivanje nije uspelo (' . ($err // 'ioctl') . '), alat eject ne postoji') unless $ok;
		return $finish->();
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

1;
