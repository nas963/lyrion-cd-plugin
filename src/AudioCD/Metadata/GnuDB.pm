package Plugins::AudioCD::Metadata::GnuDB;

# GnuDB (CDDB protokol 6, UTF-8) kao rezerva kad MusicBrainz nema disk. Cist Perl, bez Slim zavisnosti.
# HTTP radi Lookup; ovde su samo URL-ovi i parsiranje. Ulazni tekst je vec dekodiran (Perl znakovi).
# Zahtevi ne nose nikakve licne podatke: hello string je staticki.

use strict;
use warnings;
use utf8;

use constant CDDB_BASE => 'https://gnudb.gnudb.org/~cddb/cddb.cgi';
use constant PREGAP    => 150;
use constant FPS       => 75;

sub _esc {
	my ($s) = @_;
	$s =~ s/([^A-Za-z0-9\-._~+])/sprintf('%%%02X', ord($1))/ge;
	return $s;
}

sub _hello {
	my ($version) = @_;
	$version = '0' unless defined $version && length $version;
	return 'hello=audiocd+lyrion-cd-plugin+AudioCD+' . _esc($version) . '&proto=6';
}

# cddb query <id> <n> <offset+150>... <sekunde>; sve pesme (i data), kao u DiscId::cddb_id.
sub query_url {
	my ($toc, $cddbid, $version) = @_;
	my @tracks = sort { $a->{n} <=> $b->{n} } @{ $toc->{tracks} || [] };
	my @offsets = map { $_->{lba} + PREGAP } @tracks;
	my $seconds = int(($toc->{leadout} + PREGAP) / FPS);
	my $cmd = join('+', 'cddb', 'query', _esc($cddbid), scalar(@tracks), @offsets, $seconds);
	return CDDB_BASE . "?cmd=$cmd&" . _hello($version);
}

sub read_url {
	my ($category, $id, $version) = @_;
	return CDDB_BASE . '?cmd=' . join('+', 'cddb', 'read', _esc($category), _esc($id)) . '&' . _hello($version);
}

sub _lines {
	my ($text) = @_;
	return () unless defined $text;
	return map { s/\r$//r } split /\n/, $text;
}

# 200: jedan pogodak u prvoj liniji; 210/211: lista do linije '.'; ostalo (202, 4xx, 5xx): nema pogodaka.
sub parse_query {
	my ($text) = @_;
	my @lines = _lines($text);
	return [] unless @lines;
	my $head = shift @lines;
	my @out;
	if ($head =~ /^200\s+(\S+)\s+([0-9a-fA-F]{8})\s*(.*)$/) {
		push @out, { category => $1, id => $2, title => $3 };
	}
	elsif ($head =~ /^21[01]\b/) {
		for my $l (@lines) {
			last if $l eq '.';
			next unless $l =~ /^(\S+)\s+([0-9a-fA-F]{8})\s*(.*)$/;
			push @out, { category => $1, id => $2, title => $3 };
		}
	}
	return \@out;
}

# Vrednosti istog kljuca (DTITLE, TTITLEn) mogu biti razbijene u vise linija; spajaju se redom.
sub parse_read {
	my ($text, $track_count) = @_;
	my (%f, $cddbid);
	for my $l (_lines($text)) {
		last if $l eq '.';
		next if $l =~ /^#/ || $l !~ /^([A-Z]+\d*)=(.*)$/;
		my ($k, $v) = ($1, $2);
		$f{$k} .= $v;
		$cddbid = lc $v if $k eq 'DISCID' && !defined $cddbid && $v =~ /^[0-9a-fA-F]{8}$/;
	}

	my ($artist, $album) = ('', '');
	my $dtitle = defined $f{DTITLE} ? $f{DTITLE} : '';
	if ($dtitle =~ /^(.*?)\s+\/\s+(.*)$/) {
		($artist, $album) = ($1, $2);
	}
	else {
		# bez ' / ': izvodjac je isti kao album
		($artist, $album) = ($dtitle, $dtitle);
	}

	my $year = (defined $f{DYEAR} && $f{DYEAR} =~ /^\s*(\d{4})\s*$/) ? $1 : undef;

	my @tracks;
	for my $i (0 .. ($track_count || 0) - 1) {
		my $t = defined $f{"TTITLE$i"} ? $f{"TTITLE$i"} : '';
		push @tracks, { n => $i + 1, title => $t, artist => $artist, length => undef };
	}

	return {
		discid      => undef,
		cddbid      => $cddbid,
		source      => 'gnudb',
		artist      => $artist,
		album       => $album,
		year        => $year,
		disc_number => 1,
		disc_total  => 1,
		compilation => 0,
		tracks      => \@tracks,
	};
}

1;
