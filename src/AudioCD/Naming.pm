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

# Najvise $limit bajtova UTF-8 (podrazumevano MAX_BYTES), sece se na granici znaka.
sub _cut {
    my ($s, $limit) = @_;
    $limit = MAX_BYTES unless defined $limit;
    return $s if _blen($s) <= $limit;
    my $out = '';
    my $len = 0;
    for my $ch (split //, $s) {
        my $l = _blen($ch);
        last if $len + $l > $limit;
        $out .= $ch;
        $len += $l;
    }
    return $out;
}

sub _blen { return length(Encode::encode('UTF-8', $_[0])) }

# Seci na limit i ponovo skida tacke/razmake sa kraja; prazno -> Unknown.
sub _fit {
    my ($s, $limit) = @_;
    $s = _trim(_cut($s, $limit));
    return $s eq '' ? 'Unknown' : $s;
}

sub album_dir {
    my ($root, $disc) = @_;
    my $artist = $disc->{compilation} ? 'Various Artists' : $disc->{artist};
    return join('/', $root, sanitize($artist), sanitize($disc->{album}));
}

# Ceo naziv fajla (sa "NN - " i ".flac") staje u MAX_BYTES bajtova.
sub track_file {
    my ($disc, $track) = @_;
    my $nn  = sprintf('%02d - ', $track->{n} || 0);
    my $ext = '.flac';
    my $title = sanitize($track->{title});
    if ($disc->{compilation}) {
        my $artist = defined $track->{artist} && length $track->{artist} ? $track->{artist} : $disc->{artist};
        $artist = sanitize($artist);
        my $avail = MAX_BYTES - _blen($nn) - _blen($ext) - 3;    # 3 = " - "
        if (_blen($artist) + _blen($title) > $avail) {
            my $alimit = int($avail / 2);
            my $room   = $avail - _blen($title);
            $alimit = $room if $room > $alimit;
            $artist = _fit($artist, $alimit);
            $title  = _fit($title, $avail - _blen($artist));
        }
        return $nn . "$artist - $title" . $ext;
    }
    $title = _fit($title, MAX_BYTES - _blen($nn) - _blen($ext));
    return $nn . $title . $ext;
}

sub disc_subdir {
    my ($disc) = @_;
    return '' if !$disc->{disc_total} || $disc->{disc_total} <= 1;
    return 'Disc ' . ($disc->{disc_number} || 1);
}

# Dodaje " (N)" na poslednju komponentu; komponenta ostaje u MAX_BYTES bajtova.
sub unique_dir {
    my ($path, $exists_cb) = @_;
    return $path unless $exists_cb->($path);
    my ($dir, $comp) = $path =~ m{\A(.*/)?([^/]*)\z}s;
    $dir = '' unless defined $dir;
    my $i = 2;
    while (1) {
        my $suffix = " ($i)";
        my $cand = $dir . _fit($comp, MAX_BYTES - _blen($suffix)) . $suffix;
        return $cand unless $exists_cb->($cand);
        $i++;
    }
}

sub fs_bytes {
    my ($str) = @_;
    return Encode::encode('UTF-8', defined $str ? $str : '');
}

1;
