package Plugins::AudioCD::DiscId;

# MusicBrainz disc ID, CDDB ID i toc string iz TOC-a. Cist Perl, bez Slim zavisnosti.
#
# TOC: { first => 1, last => 9, leadout => LBA, tracks => [ { n, lba, data }, ... ] }
# Svi LBA su BEZ +150 ofseta; ofset se dodaje ovde.

use strict;
use warnings;
use utf8;

use Digest::SHA ();
use MIME::Base64 ();

use constant FRAMES_PER_SEC => 75;
use constant PREGAP         => 150;
use constant ENHANCED_GAP   => 11400;    # razmak izmedju poslednje audio i data sesije

# Audio pesme po redu (bez data pesama).
sub audio_tracks {
	my ($toc) = @_;
	return grep { !$_->{data} } sort { $a->{n} <=> $b->{n} } @{ $toc->{tracks} || [] };
}

# Leadout koji vazi za audio deo: kod enhanced CD-a (data pesma posle audio pesama)
# audio zavrsava 11400 frejmova pre prve data pesme, inace je to leadout diska.
sub _audio_leadout {
	my ($toc) = @_;
	my @audio = audio_tracks($toc);
	my $last_audio = @audio ? $audio[-1]{n} : 0;
	my ($data_after) = grep { $_->{data} && $_->{n} > $last_audio } sort { $a->{n} <=> $b->{n} } @{ $toc->{tracks} || [] };
	return $data_after ? $data_after->{lba} - ENHANCED_GAP : $toc->{leadout};
}

sub _mb_values {
	my ($toc) = @_;
	my @audio = audio_tracks($toc);
	die "TOC nema audio pesama\n" unless @audio;
	return ($audio[0]{n}, $audio[-1]{n}, _audio_leadout($toc), @audio);
}

sub musicbrainz_id {
	my ($toc) = @_;
	my ($first, $last, $leadout, @audio) = _mb_values($toc);
	my %off = map { $_->{n} => $_->{lba} + PREGAP } @audio;
	my $s = sprintf('%02X%02X%08X', $first, $last, $leadout + PREGAP);
	$s .= sprintf('%08X', $off{$_} // 0) for 1 .. 99;
	my $id = MIME::Base64::encode_base64(Digest::SHA::sha1($s), '');
	$id =~ tr{+/=}{._-};
	return $id;
}

sub mb_toc_string {
	my ($toc) = @_;
	my ($first, $last, $leadout, @audio) = _mb_values($toc);
	return join ' ', $first, $last, $leadout + PREGAP, map { $_->{lba} + PREGAP } @audio;
}

sub _digit_sum {
	my ($n) = @_;
	my $sum = 0;
	$sum += $1 while $n =~ /(\d)/g;
	return $sum;
}

# CDDB (freedb) ID: sve pesme, ukljucujuci data, i pravi leadout diska.
sub cddb_id {
	my ($toc) = @_;
	my @tracks = sort { $a->{n} <=> $b->{n} } @{ $toc->{tracks} || [] };
	die "TOC nema pesama\n" unless @tracks;
	my $n = 0;
	$n += _digit_sum(int(($_->{lba} + PREGAP) / FRAMES_PER_SEC)) for @tracks;
	my $t = int(($toc->{leadout} + PREGAP) / FRAMES_PER_SEC) - int(($tracks[0]{lba} + PREGAP) / FRAMES_PER_SEC);
	return sprintf('%08x', (($n % 255) << 24) | ($t << 8) | scalar(@tracks));
}

# { broj pesme => sekunde } za audio pesme, zaokruzeno na najblize; iz razlike LBA.
sub track_lengths {
	my ($toc) = @_;
	my @audio = audio_tracks($toc);
	my $end = _audio_leadout($toc);
	my %len;
	for my $i (0 .. $#audio) {
		my $next = $i < $#audio ? $audio[$i + 1]{lba} : $end;
		$len{ $audio[$i]{n} } = int(($next - $audio[$i]{lba}) / FRAMES_PER_SEC + 0.5);
	}
	return \%len;
}

1;
