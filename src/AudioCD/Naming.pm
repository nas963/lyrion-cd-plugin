package Plugins::AudioCD::Naming;

# Nazivi fajlova i foldera bezbedni za Windows/Sambu. Cist Perl, bez Slim zavisnosti.
# Svi ulazi su Perl karakter stringovi; fs_bytes daje UTF-8 bajtove za fajl sistem.

use strict;
use warnings;
use utf8;

use Encode ();

use constant MAX_BYTES => 200;

my %RESERVED = map { (uc($_) => 1) } (qw(CON PRN AUX NUL), (map { ("COM$_", "LPT$_") } 1 .. 9));

sub sanitize {
    my ($str) = @_;
    $str = '' unless defined $str;

    $str =~ s{[:/]}{-}g;
    $str =~ s/[?*"<>|\\]//g;
    $str =~ s{[\x00-\x1f\x7f]}{}g;

    $str = _trim($str);
    $str = _cut($str);
    $str = _trim($str);
    return 'Unknown' if $str eq '';

    # Rezervisano ime vazi i sa ekstenzijom: CON.txt -> CON_.txt
    if ($str =~ /\A([^.]*)(.*)\z/s && $RESERVED{ uc $1 }) {
        $str = $1 . '_' . $2;
    }
    return $str;
}

# Skida razmake i tacke sa kraja (Windows ih ne dozvoljava) i razmake sa pocetka.
sub _trim {
    my ($s) = @_;
    $s =~ s{\A\s+}{};
    $s =~ s{[\s.]+\z}{};
    return $s;
}

# Najvise MAX_BYTES bajtova UTF-8, sece se na granici znaka.
sub _cut {
    my ($s) = @_;
    return $s if length(Encode::encode('UTF-8', $s)) <= MAX_BYTES;
    my $out = '';
    my $len = 0;
    for my $ch (split //, $s) {
        my $l = length(Encode::encode('UTF-8', $ch));
        last if $len + $l > MAX_BYTES;
        $out .= $ch;
        $len += $l;
    }
    return $out;
}

sub album_dir {
    my ($root, $disc) = @_;
    my $artist = $disc->{compilation} ? 'Various Artists' : $disc->{artist};
    return join('/', $root, sanitize($artist), sanitize($disc->{album}));
}

sub track_file {
    my ($disc, $track) = @_;
    my $nn = sprintf('%02d', $track->{n} || 0);
    my $title = sanitize($track->{title});
    if ($disc->{compilation}) {
        my $artist = defined $track->{artist} && length $track->{artist} ? $track->{artist} : $disc->{artist};
        return "$nn - " . sanitize($artist) . " - $title.flac";
    }
    return "$nn - $title.flac";
}

sub disc_subdir {
    my ($disc) = @_;
    return '' if !$disc->{disc_total} || $disc->{disc_total} <= 1;
    return 'Disc ' . ($disc->{disc_number} || 1);
}

sub unique_dir {
    my ($path, $exists_cb) = @_;
    return $path unless $exists_cb->($path);
    my $i = 2;
    $i++ while $exists_cb->("$path ($i)");
    return "$path ($i)";
}

sub fs_bytes {
    my ($str) = @_;
    return Encode::encode('UTF-8', defined $str ? $str : '');
}

1;
