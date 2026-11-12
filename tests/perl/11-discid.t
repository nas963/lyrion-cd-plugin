use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use File::Basename qw(dirname);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::DiscId') }

sub toc {
	my ($leadout, @lbas) = @_;
	my @tracks;
	my $n = 0;
	for my $l (@lbas) {
		my $data = ref $l ? 1 : 0;
		$l = $l->[0] if ref $l;
		push @tracks, { n => ++$n, lba => $l, data => $data };
	}
	return { first => 1, last => $n, leadout => $leadout, tracks => \@tracks };
}

# Primer iz MusicBrainz dokumentacije (MB ofseti 150, 15363, ...; leadout 95462)
my $doc = toc(95312, 0, 15213, 32164, 46442, 63264, 80339);
is(Plugins::AudioCD::DiscId::musicbrainz_id($doc), '49HHV7Eb8UKF3aQiNmu1GR8vKTY-', 'MB dokumentacija: disc ID');
is(Plugins::AudioCD::DiscId::mb_toc_string($doc), '1 6 95462 150 15363 32314 46592 63414 80489', 'MB dokumentacija: toc string');
is(Plugins::AudioCD::DiscId::cddb_id($doc), '3404f606', 'MB dokumentacija: CDDB ID');
is(length Plugins::AudioCD::DiscId::musicbrainz_id($doc), 28, 'disc ID ima 28 znakova');

# TOC pravog diska
my $fixture = dirname($0) . '/fixtures/real-disc-toc.json';
open my $fh, '<', $fixture or die "$fixture: $!";
my $real = JSON::PP->new->decode(do { local $/; <$fh> });
close $fh;
is(Plugins::AudioCD::DiscId::musicbrainz_id($real->{toc}), $real->{musicbrainz_id}, 'pravi disk: MB ID');
is(Plugins::AudioCD::DiscId::cddb_id($real->{toc}), $real->{cddb_id}, 'pravi disk: CDDB ID');
is(Plugins::AudioCD::DiscId::mb_toc_string($real->{toc}), $real->{mb_toc_string}, 'pravi disk: toc string');
my $len = Plugins::AudioCD::DiscId::track_lengths($real->{toc});
is($len->{1}, 292, 'pravi disk: pesma 1 = 292 s (21913 frejmova)');
is($len->{9}, 479, 'pravi disk: poslednja pesma racuna do leadout-a');
is(scalar(keys %$len), 9, 'pravi disk: 9 duzina');

# Enhanced CD: poslednja pesma je data
my $enh = toc(75000, 0, 20000, 40000, [61400]);
is(Plugins::AudioCD::DiscId::musicbrainz_id($enh), 'w.ZIjOCQDoeCb0ivbxii4nSlsrM-', 'enhanced: MB ID koristi leadout = data LBA - 11400');
is(Plugins::AudioCD::DiscId::mb_toc_string($enh), '1 3 50150 150 20150 40150', 'enhanced: toc string bez data pesme');
is(Plugins::AudioCD::DiscId::cddb_id($enh), '2903e804', 'enhanced: CDDB ID racuna sve pesme i pravi leadout');
is_deeply([map { $_->{n} } Plugins::AudioCD::DiscId::audio_tracks($enh)], [1, 2, 3], 'enhanced: audio_tracks bez data pesme');
$len = Plugins::AudioCD::DiscId::track_lengths($enh);
is_deeply($len, { 1 => 267, 2 => 267, 3 => 133 }, 'enhanced: duzine bez data pesme i bez razmaka od 11400');

# HTOA: prva pesma ne pocinje od 0
my $htoa = toc(90000, 32000, 52000, 70000);
is(Plugins::AudioCD::DiscId::musicbrainz_id($htoa), 'OLyozWXYCc6Owhksaveb5pfv.CI-', 'HTOA: ID se racuna normalno');
is(Plugins::AudioCD::DiscId::mb_toc_string($htoa), '1 3 90150 32150 52150 70150', 'HTOA: ofset 32150');
is(Plugins::AudioCD::DiscId::cddb_id($htoa), '33030603', 'HTOA: CDDB ID');
$len = Plugins::AudioCD::DiscId::track_lengths($htoa);
is($len->{1}, 267, 'HTOA: pesma 1 ne ukljucuje pregap');
is($len->{3}, 267, 'HTOA: poslednja pesma');

done_testing;
