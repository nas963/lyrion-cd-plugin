package Plugins::AudioCD::Metadata::MusicBrainz;

# Parsiranje MusicBrainz discid odgovora u normalizovan oblik diska. Cist Perl, bez Slim zavisnosti.
# HTTP radi Lookup; ovde su samo URL-ovi i parsiranje.
#
# Normalizovan disk:
#   { discid, cddbid, source => 'musicbrainz', release_id, release_group_id, artist,
#     album_artist_id, album, year, disc_number, disc_total, compilation => 0|1,
#     tracks => [ { n, title, artist, artist_id, recording_id, length } ], cover_url }
# `length` i `cddbid` popunjava Lookup iz TOC-a; `cover_url` takodje Lookup (vidi cover_urls).

use strict;
use warnings;
use utf8;

use JSON::PP ();

use constant VARIOUS_ARTISTS => '89ad4ac3-39f7-470e-963a-56509c546377';
use constant MB_BASE         => 'https://musicbrainz.org/ws/2';
use constant CAA_BASE        => 'https://coverartarchive.org';

# Napomena: "media" nije dozvoljen inc za discid resurs (API vraca 400); medije vraca podrazumevano.
use constant DISCID_INC => 'recordings+artist-credits+release-groups+labels';

sub _esc {
	my ($s) = @_;
	$s =~ s/([^A-Za-z0-9\-._~+])/sprintf('%%%02X', ord($1))/ge;
	return $s;
}

# $toc_string je MusicBrainz toc ("1 9 194526 150 ..."); razmaci postaju '+'.
sub discid_url {
	my ($discid, $toc_string) = @_;
	my $url = MB_BASE . '/discid/' . _esc($discid);
	my @q;
	if (defined $toc_string && length $toc_string) {
		(my $toc = $toc_string) =~ s/^\s+|\s+$//g;
		$toc = join('+', map { _esc($_) } split /\s+/, $toc);
		push @q, "toc=$toc";
	}
	push @q, 'inc=' . DISCID_INC, 'fmt=json';
	return $url . '?' . join('&', @q);
}

# "Ime" + joinphrase za svaki deo kredita.
sub _credit_name {
	my ($credit) = @_;
	return '' unless ref $credit eq 'ARRAY';
	return join('', map {
		my $c = $_;
		ref $c eq 'HASH'
			? (defined $c->{name} ? $c->{name} : ($c->{artist} || {})->{name} // '') . ($c->{joinphrase} // '')
			: ''
	} @$credit);
}

sub _credit_first_id {
	my ($credit) = @_;
	return undef unless ref $credit eq 'ARRAY' && ref $credit->[0] eq 'HASH';
	my $a = $credit->[0]{artist};
	return ref $a eq 'HASH' ? $a->{id} : undef;
}

sub _pick_medium {
	my ($release, $discid, $track_count) = @_;
	my $media = $release->{media};
	return unless ref $media eq 'ARRAY';

	if (defined $discid) {
		for my $i (0 .. $#$media) {
			my $m = $media->[$i];
			next unless ref $m eq 'HASH' && ref $m->{discs} eq 'ARRAY';
			return ($m, $i) if grep { ref $_ eq 'HASH' && defined $_->{id} && $_->{id} eq $discid } @{ $m->{discs} };
		}
	}
	if (defined $track_count) {
		for my $i (0 .. $#$media) {
			my $m = $media->[$i];
			return ($m, $i) if ref $m eq 'HASH' && defined $m->{'track-count'} && $m->{'track-count'} == $track_count;
		}
	}
	return;
}

sub _normalize {
	my ($release, $medium, $idx, $discid) = @_;

	my $album_credit = $release->{'artist-credit'};
	my $artist       = _credit_name($album_credit);
	my $artist_id    = _credit_first_id($album_credit);
	my $date         = $release->{date};
	my $year         = (defined $date && $date =~ /^(\d{4})/) ? $1 : undef;
	my $rg           = ref $release->{'release-group'} eq 'HASH' ? $release->{'release-group'}{id} : undef;

	my @tracks;
	my $tracks_in = ref $medium->{tracks} eq 'ARRAY' ? $medium->{tracks} : [];
	my $i = 0;
	for my $t (@$tracks_in) {
		next unless ref $t eq 'HASH';
		$i++;
		my $rec    = ref $t->{recording} eq 'HASH' ? $t->{recording} : {};
		my $credit = $t->{'artist-credit'} || $rec->{'artist-credit'} || $album_credit;
		push @tracks, {
			n            => defined $t->{position} ? $t->{position} + 0 : $i,
			title        => $t->{title} // $rec->{title},
			artist       => _credit_name($credit),
			artist_id    => _credit_first_id($credit),
			recording_id => $rec->{id},
			length       => undef,
		};
	}

	return {
		discid           => $discid,
		cddbid           => undef,
		source           => 'musicbrainz',
		release_id       => $release->{id},
		release_group_id => $rg,
		artist           => $artist,
		album_artist_id  => $artist_id,
		album            => $release->{title},
		year             => $year,
		disc_number      => defined $medium->{position} ? $medium->{position} + 0 : $idx + 1,
		disc_total       => scalar @{ $release->{media} },
		compilation      => (defined $artist_id && $artist_id eq VARIOUS_ARTISTS) ? 1 : 0,
		tracks           => \@tracks,
		cover_url        => undef,
	};
}

# Vraca \@kandidata; nikad ne umire (los JSON, 404 telo, nepoznat oblik -> []).
sub parse_releases {
	my ($json_text, $discid, $track_count) = @_;

	my $data = eval { JSON::PP->new->utf8->decode(defined $json_text ? $json_text : '') };
	return [] unless ref $data eq 'HASH' && ref $data->{releases} eq 'ARRAY';

	my @out;
	for my $release (@{ $data->{releases} }) {
		next unless ref $release eq 'HASH' && defined $release->{id};
		my ($medium, $idx) = _pick_medium($release, $discid, $track_count);
		next unless $medium;

		my $label_info = ref $release->{'label-info'} eq 'ARRAY' ? $release->{'label-info'} : [];
		my ($label) = grep { defined $_ && length $_ }
			map { ref $_ eq 'HASH' && ref $_->{label} eq 'HASH' ? $_->{label}{name} : undef } @$label_info;

		my $disc = _normalize($release, $medium, $idx, $discid);
		push @out, {
			release_id      => $release->{id},
			title           => $release->{title},
			artist          => $disc->{artist},
			country         => $release->{country},
			date            => $release->{date},
			label           => $label,
			format          => $medium->{format},
			disc_count      => $disc->{disc_total},
			medium_position => $disc->{disc_number},
			disc            => $disc,
		};
	}
	return \@out;
}

# (release front, release-group front) -- Lookup probava redom.
sub cover_urls {
	my ($candidate) = @_;
	my @urls;
	my $rid  = $candidate->{release_id};
	my $rgid = ref $candidate->{disc} eq 'HASH' ? $candidate->{disc}{release_group_id} : undef;
	push @urls, CAA_BASE . "/release/$rid/front-500" if defined $rid;
	push @urls, CAA_BASE . "/release-group/$rgid/front-500" if defined $rgid;
	return @urls;
}

1;
