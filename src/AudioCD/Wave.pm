package Plugins::AudioCD::Wave;

# Talasni oblik pesme iz kesa (prikaz kao kod Roon-a): POINTS tacaka kroz celu pesmu, za svaku vrh i
# RMS oba kanala (0..1000 od pune skale). Racuna se u posebnom procesu niskog prioriteta, iz gotovog
# NN.flac, posle izvlacenja; zvuk koji ide plejeru se ne dira.
#
#   flac -d -c -s --force-raw-format --endian=little --sign=signed NN.flac \
#     | perl -I<plugins_root> -MPlugins::AudioCD::Wave -e 'Plugins::AudioCD::Wave::main()' -- NN.flac NN.wave.json
#
# Cist Perl, bez Slim zavisnosti. Vrh je tacan (svaki uzorak), RMS se racuna iz svakog 8. okvira.

use strict;
use warnings;

use JSON::PP ();
use List::Util ();

use constant POINTS => 400;
use constant STRIDE => 8;    # okvira izmedju dva uzorka za RMS

# flac_info($file) -> { rate, channels, bits, samples } iz STREAMINFO bloka, ili undef
sub flac_info {
	my ($f) = @_;
	open my $fh, '<:raw', $f or return undef;
	my $n = read $fh, my $b, 26;
	close $fh;
	return undef unless defined $n && $n == 26 && substr($b, 0, 4) eq 'fLaC';
	my ($hi, $lo) = unpack 'NN', substr($b, 18, 8);
	return {
		rate     => $hi >> 12,
		channels => (($hi >> 9) & 7) + 1,
		bits     => (($hi >> 4) & 31) + 1,
		samples  => ($hi & 0xF) * 4294967296 + $lo,
	};
}

# compute($fh, $frames[, points => N, channels => 2]) -> { points, peak => [...], rms => [...] }
# $fh daje sirov PCM s16le; $frames je broj okvira (uzorak po kanalu). Kraci ulaz: ostatak su nule.
sub compute {
	my ($fh, $frames, %o) = @_;
	my $points = $o{points} || POINTS;
	my $ch     = $o{channels} || 2;
	my $fb     = 2 * $ch;
	my $step   = STRIDE * $ch;
	my (@peak, @rms);
	my $start = 0;
	binmode $fh;
	for my $i (0 .. $points - 1) {
		my $end = int(($i + 1) * $frames / $points);
		my $want = ($end - $start) * $fb;
		$start = $end;
		my $buf = '';
		while ($want > length $buf) {
			my $got = read $fh, $buf, $want - length $buf, length $buf;
			last unless $got;
		}
		my @v = unpack 's<*', $buf;
		if (!@v) { push @peak, 0; push @rms, 0; next }
		my $p = List::Util::max(List::Util::max(@v), -List::Util::min(@v));
		my ($s, $c) = (0, 0);
		for (my $j = 0; $j < @v; $j += $step) {
			$s += $v[$_] * $v[$_] for $j .. ($j + $ch - 1 < $#v ? $j + $ch - 1 : $#v);
			$c += $ch;
		}
		push @peak, _scale($p);
		push @rms,  _scale($c ? sqrt($s / $c) : 0);
	}
	return { points => $points, peak => \@peak, rms => \@rms };
}

sub _scale { my $v = int($_[0] * 1000 / 32768 + 0.5); return $v > 1000 ? 1000 : $v }

# write_file($path, $wave): atomski (tmp + rename)
sub write_file {
	my ($path, $w) = @_;
	my $tmp = "$path.tmp";
	open my $fh, '>:raw', $tmp or die "$tmp: $!\n";
	print {$fh} JSON::PP->new->canonical->encode({ v => 1, %$w }) or die "$tmp: $!\n";
	close $fh or die "$tmp: $!\n";
	rename $tmp, $path or die "rename $tmp: $!\n";
	return 1;
}

# read_file($path) -> { points, peak, rms } ili undef
sub read_file {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $raw = <$fh>;
	close $fh;
	my $w = eval { JSON::PP->new->decode($raw) };
	return undef unless ref $w eq 'HASH' && ref $w->{peak} eq 'ARRAY' && ref $w->{rms} eq 'ARRAY'
		&& @{ $w->{peak} } && @{ $w->{peak} } == @{ $w->{rms} };
	return { points => scalar @{ $w->{peak} }, peak => $w->{peak}, rms => $w->{rms} };
}

# Pomocni proces: argumenti <NN.flac> <izlaz.json>, PCM na stdin-u.
sub main {
	my ($in, $out) = @ARGV;
	die "upotreba: Wave::main -- <in.flac> <out.json>\n" unless defined $in && defined $out;
	my $info = flac_info($in) or die "$in: nije FLAC\n";
	die "$in: ocekivan 16-bitni PCM\n" unless $info->{bits} == 16 && $info->{samples};
	my $w = compute(\*STDIN, $info->{samples}, channels => $info->{channels});
	write_file($out, $w);
	exit 0;
}

1;
