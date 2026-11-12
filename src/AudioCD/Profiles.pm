package Plugins::AudioCD::Profiles;

# cyanrip: argumenti po profilu kvaliteta, parsiranje napretka i sazetak loga.
# Cist Perl, bez Slim zavisnosti. Proveren na cyanrip 0.9.0 (Ubuntu paket 0.9.2);
# opcije koje se koriste vidi u tests/fixtures/cyanrip-help.txt.

use strict;
use warnings;
use utf8;

use Plugins::AudioCD::Jobs;

our @NAMES = qw(fast balanced secure);

# paranoia: undef = podrazumevana (cyanrip: max), retries: undef = cyanrip podrazumevano
# speed: undef = bez -S
my %PROFILE = (
	fast     => { paranoia => 0,     retries => undef, speed => undef },
	balanced => { paranoia => undef, retries => 1,     speed => undef },
	secure   => { paranoia => 3,     retries => 5,     speed => 8 },
);

# Vrednost u cyanrip -a/-t sintaksi. Pre-parser cyanrip-a ne zna za escape,
# ali sam parser znakova (av_dict) zna: \ : = ' se escape-uju obrnutom kosom crtom.
sub _esc {
	my ($v) = @_;
	$v = '' unless defined $v;
	$v =~ s/[\x00-\x1f\x7f]+/ /g;
	$v =~ s/([\\:='])/\\$1/g;
	utf8::upgrade($v);    # Jobs kodira u UTF-8 samo stringove sa utf8 flagom
	return $v;
}

# Lista key=value parova -> "k=v:k=v"; prazne vrednosti se izostavljaju.
# cyanrip pre-parser deli po SVAKOM ':' (i escape-ovanom) i trazi '=' u prva dva segmenta;
# zato prva dva para moraju biti bezbedna (bez ':' u vrednosti) i uvek prisutna.
sub _pairs {
	my (@kv) = @_;
	my @out;
	while (@kv) {
		my ($k, $v) = splice @kv, 0, 2;
		next unless defined $v && $v ne '';
		push @out, "$k=" . _esc($v);
	}
	return join ':', @out;
}

sub _album_tags {
	my ($disc, $total) = @_;
	my $dn = $disc->{disc_number} || 1;
	my $dt = $disc->{disc_total}  || 1;
	return _pairs(
		media_type                 => 'CD',
		discid                     => $disc->{discid},
		album                      => $disc->{album},
		album_artist               => $disc->{artist},
		date                       => $disc->{year},
		disc                       => $dn,
		totaldiscs                 => $dt,
		disctotal                  => $dt,
		musicbrainz_discid         => $disc->{discid},
		musicbrainz_albumid        => $disc->{release_id},
		musicbrainz_releasegroupid => $disc->{release_group_id},
		musicbrainz_albumartistid  => $disc->{album_artist_id},
	);
}

sub _track_tags {
	my ($t, $total) = @_;
	return $t->{n} . '=' . _pairs(
		track                => $t->{n},
		tracktotal           => $total,
		title                => $t->{title},
		artist               => $t->{artist},
		musicbrainz_trackid  => $t->{recording_id},
		musicbrainz_artistid => $t->{artist_id},
	);
}

sub rip_argv {
	my (%a) = @_;
	my $name = exists $PROFILE{ $a{profile} // '' } ? $a{profile} : 'balanced';
	my $p    = $PROFILE{$name};
	my $disc = $a{disc} || {};

	my @c = ($a{cyanrip} || 'cyanrip', '-N');    # -N: bez cyanrip MusicBrainz lookup-a, metapodatke dajemo mi
	push @c, '-s', defined $a{offset} ? $a{offset} : 0;    # cyanrip bez -s odbija da radi
	push @c, '-d', $a{device} if defined $a{device};
	push @c, '-P', $p->{paranoia} if defined $p->{paranoia};
	push @c, '-r', $p->{retries} if defined $p->{retries};
	my $speed = defined $a{quiet_speed} ? $a{quiet_speed} : $p->{speed};
	push @c, '-S', $speed if defined $speed;
	push @c, '-o', 'flac';    # flac_level se ne prosledjuje: cyanrip flac uvek koristi maksimalnu kompresiju
	push @c, '-D', $a{out_dir}, '-F', '{track}';    # <out_dir>/<N>.flac, log i cue u istom folderu
	push @c, '-c', ($disc->{disc_number} || 1) . '/' . $disc->{disc_total}
		if ($disc->{disc_total} || 1) > 1;
	push @c, '-C', 'Front=' . $a{cover} if defined $a{cover} && $a{cover} ne '';

	my @tracks = @{ $disc->{tracks} || [] };
	push @c, '-a', _album_tags($disc);
	push @c, '-t', _track_tags($_, scalar @tracks) for @tracks;

	return Plugins::AudioCD::Jobs::low_prio(@c);
}

# Jedna linija cyanrip izlaza (podeljena po \r i \n):
#   "Ripping and encoding track 3, progress - 42.50%, ETA - 12s"  -> { track, percent }
#   "Track 3 ripped and encoded successfully!"                    -> { done_track }
#   "Accurip v1/v2: XXXX (accurately ripped, ...)"                -> { accurip => 'match' }
#   "Accurip v1/v2: XXXX (not found, ...)"                        -> { accurip => 'mismatch' }
#   "Accurip:  disc not found in database"                        -> { accurip => 'notfound' }
# Linije Accurip stizu u sazetku POSLE linije zavrsene pesme; pripada joj poslednji done_track.
sub parse_progress {
	my ($line) = @_;
	return undef unless defined $line;
	if ($line =~ /Ripping and encoding track (\d+), progress - ([\d.]+)%/) {
		return { track => $1 + 0, percent => $2 + 0 };
	}
	if ($line =~ /\bTrack (\d+) ripped and encoded successfully/) {
		return { done_track => $1 + 0 };
	}
	if ($line =~ /Accurip:\s+disc not found in database/i) {
		return { accurip => 'notfound' };
	}
	if ($line =~ /Accurip v[12]:\s+\S+\s+\((.*)\)/i) {
		return { accurip => ($1 =~ /^accurately ripped/i ? 'match' : 'mismatch') };
	}
	return undef;
}

sub summary {
	my ($log) = @_;
	my %s = (tracks_ok => 0, tracks_total => 0, accurip_ok => 0, accurip_total => 0);
	return \%s unless defined $log && length $log;

	my $all_tracks;
	$s{tracks_total} = $1 + 0 if $log =~ /^Tracks to rip:\s+(\d+)\s*$/m;
	$all_tracks = $1 + 0 if $log =~ /^Disc tracks:\s+(\d+)\s*$/m;
	$s{tracks_total} = $all_tracks || 0 if $log =~ /^Tracks to rip:\s+all\s*$/m;
	$s{tracks_ok} = () = $log =~ /^Track \d+ ripped and encoded successfully/mg;
	if ($log =~ /^Tracks ripped accurately:\s+(\d+)\/(\d+)/m) {
		($s{accurip_ok}, $s{accurip_total}) = ($1 + 0, $2 + 0);
	}
	return \%s;
}

1;
