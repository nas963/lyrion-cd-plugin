package Plugins::AudioCD::Metadata::CdText;

# CD-Text iz ispisa `cd-info` (libcdio). Cist Perl, bez Slim zavisnosti.
# Format ispisa:
#   CD-TEXT for Disc:
#   <TAB>PERFORMER: ...
#   <TAB>TITLE: ...
#   CD-TEXT for Track  1:
#   <TAB>TITLE: ...
# Ako disk nosi vise jezika ("Language N 'xxx':"), koristi se samo prvi blok.

use strict;
use warnings;
use utf8;

# Uvek /usr/bin/cd-info: pokvarena kopija u /usr/local/bin zasenjuje pravu.
sub command {
	my ($dev) = @_;
	return (
		'/usr/bin/cd-info', '--no-header', '--no-device-info', '--no-disc-mode', '--no-cddb',
		'--no-vcd', '--no-ioctl', '--no-analyze', '-C', $dev,
	);
}

sub parse {
	my ($text, $track_count) = @_;
	return undef unless defined $text;

	my (%disc, %track);
	my $scope;     # 'disc' | n
	my $langs = 0;
	for my $l (split /\r?\n/, $text) {
		if ($l =~ /^Language\s+\d+\b/) {
			last if ++$langs > 1;
			undef $scope;
		}
		elsif ($l =~ /^CD-TEXT for Disc:/) {
			$scope = 'disc';
		}
		elsif ($l =~ /^CD-TEXT for Track\s+(\d+):/) {
			$scope = $1 + 0;
		}
		elsif (defined $scope && $l =~ /^\s+(TITLE|PERFORMER):\s?(.*)$/) {
			my ($k, $v) = ($1, $2);
			$v =~ s/\s+$//;
			if ($scope eq 'disc') { $disc{$k} = $v }
			else                  { $track{$scope}{$k} = $v }
		}
	}

	my $have = grep { length } map { $_ // '' } values %disc;
	$have ||= grep { grep { length } values %$_ } values %track;
	return undef unless $have;

	my $artist = $disc{PERFORMER} // '';
	my $album  = $disc{TITLE} // '';
	my @tracks;
	for my $n (1 .. ($track_count || 0)) {
		my $t = $track{$n} || {};
		my $ta = (defined $t->{PERFORMER} && length $t->{PERFORMER}) ? $t->{PERFORMER} : $artist;
		push @tracks, { n => $n, title => $t->{TITLE} // '', artist => $ta, length => undef };
	}

	return {
		discid      => undef,
		cddbid      => undef,
		source      => 'cdtext',
		artist      => $artist,
		album       => $album,
		year        => undef,
		disc_number => 1,
		disc_total  => 1,
		compilation => 0,
		tracks      => \@tracks,
	};
}

1;
