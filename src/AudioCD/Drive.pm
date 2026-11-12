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

1;
