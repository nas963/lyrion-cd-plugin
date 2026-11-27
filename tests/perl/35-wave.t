use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp ();
use File::Spec ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Wave'); use_ok('Plugins::AudioCD::Cache') }

my $W = 'Plugins::AudioCD::Wave';
my $root = File::Spec->rel2abs(File::Temp::tempdir('wave-XXXXXX', DIR => '.', CLEANUP => 1));

# ---- compute: tisina, pa puna skala, pa pola ----
{
	my $frames = 3000;
	my $pcm = pack('s<*', (0) x 2000)                            # 1000 okvira tisine
		. pack('s<*', map { $_ % 2 ? -32768 : 32767 } 1 .. 2000)   # 1000 okvira pune skale
		. pack('s<*', (16384) x 2000);                            # 1000 okvira pola
	open my $fh, '<', \$pcm or die;
	my $w = $W->can('compute')->($fh, $frames, points => 3);
	is $w->{points}, 3, 'broj tacaka';
	is_deeply $w->{peak}, [ 0, 1000, 500 ], 'vrh po delu pesme';
	is $w->{rms}[0], 0, 'rms tisine';
	cmp_ok $w->{rms}[1], '>=', 999, 'rms pune skale';
	is $w->{rms}[2], 500, 'rms pola skale';
}

# ---- kraci ulaz od najavljenog: ostatak su nule, nema greske ----
{
	my $pcm = pack('s<*', (1000) x 200);
	open my $fh, '<', \$pcm or die;
	my $w = $W->can('compute')->($fh, 1000, points => 10);
	is scalar @{ $w->{peak} }, 10, 'uvek points tacaka';
	is_deeply [ @{ $w->{peak} }[ 5 .. 9 ] ], [ (0) x 5 ], 'nedostajuci deo su nule';
}

# ---- upis i citanje ----
{
	my $f = "$root/01.wave.json";
	ok $W->can('write_file')->($f, { points => 2, peak => [ 1, 2 ], rms => [ 3, 4 ] }), 'upis';
	ok !-e "$f.tmp", 'bez ostatka .tmp';
	is_deeply $W->can('read_file')->($f), { points => 2, peak => [ 1, 2 ], rms => [ 3, 4 ] }, 'citanje';
	open my $fh, '>', "$root/bad.json" or die; print {$fh} '{"peak":[1],"rms":[]}'; close $fh;
	is $W->can('read_file')->("$root/bad.json"), undef, 'neispravan fajl';
	is $W->can('read_file')->("$root/nema.json"), undef, 'nema fajla';
}

# ---- flac_info iz STREAMINFO ----
{
	my $f = "$root/x.flac";
	my $samples = 44100 * 10;
	my $hi = (44100 << 12) | ((2 - 1) << 9) | ((16 - 1) << 4) | 0;
	open my $fh, '>:raw', $f or die;
	print {$fh} 'fLaC', "\0" x 14, pack('NN', $hi, $samples);
	close $fh;
	is_deeply $W->can('flac_info')->($f), { rate => 44100, channels => 2, bits => 16, samples => $samples }, 'STREAMINFO';
}

# ---- Cache: red za talase ----
my $DISCID = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';
my $toc = { first => 1, last => 3, leadout => 180 * 75,
	tracks => [ map { { n => $_, lba => ($_ - 1) * 60 * 75, data => 0 } } 1 .. 3 ] };
my $disc = { discid => $DISCID, artist => 'A', album => 'B', tracks => [ map { { n => $_, title => "T$_" } } 1 .. 3 ] };

my @SP;
my $fake = sub {
	my (%a) = @_;
	my $cmd = $a{argv}[-1];
	my $sp = bless { %a, cmd => $cmd, killed => 0 }, 'FakeJob';
	if ($cmd =~ /Wave::main/) {
		($sp->{out}) = $cmd =~ /'--' '[^']*' '([^']*)'/;
		$sp->{wave} = 1;
	}
	else {
		($sp->{out}) = $cmd =~ /'-o' '([^']*)'/;
		open my $fh, '>', $sp->{out} or die; print {$fh} 'part'; close $fh;
	}
	push @SP, $sp;
	return $sp;
};
{ package FakeJob; sub kill { $_[0]{killed}++ } }

{
	@SP = ();
	my $dir = "$root/c1";
	mkdir $dir;
	my $c = Plugins::AudioCD::Cache->new(spawn => $fake, dir => $dir, device => '/dev/sr0', paranoia => 'p', flac => 'flac',
		wave_helper => [ 'perl', '-MPlugins::AudioCD::Wave', '-e', 'Plugins::AudioCD::Wave::main()' ]);
	ok $c->start($disc, $toc, 1), 'start';
	is scalar(grep { $_->{wave} } @SP), 0, 'talas tek kad je pesma gotova';
	$SP[0]{on_exit}->(0);    # pesma 1 izvucena
	my @w = grep { $_->{wave} } @SP;
	is scalar @w, 1, 'talas pesme 1 pokrenut';
	like $w[0]{cmd}, qr/; 'flac' '-d' '-c' .*01\.flac' \| 'perl' /, 'flac -d | pomocni proces';
	like $w[0]{cmd}, qr/01\.wave\.json'/, 'izlaz NN.wave.json';
	my ($t2) = grep { !$_->{wave} && $_->{out} =~ /02\.flac\.part\z/ } @SP;
	ok $t2, 'izvlacenje pesme 2 tece uz racunanje talasa';
	$t2->{on_exit}->(0);    # pesma 2 izvucena
	is scalar(grep { $_->{wave} } @SP), 1, 'jedan talas u isto vreme';
	is $c->wave($DISCID, 1), undef, 'talas jos nije gotov';

	$W->can('write_file')->($w[0]{out}, { points => 2, peak => [ 5, 6 ], rms => [ 7, 8 ] });
	$w[0]{on_exit}->(0);
	is_deeply $c->wave($DISCID, 1), { points => 2, peak => [ 5, 6 ], rms => [ 7, 8 ] }, 'talas pesme 1';
	is_deeply $c->status->{waves}, [1], 'status: waves';
	is $c->wave('drugi', 1), undef, 'drugi disk';
	my @w2 = grep { $_->{wave} } @SP;
	is scalar @w2, 2, 'sledeci talas krece posle prethodnog';
	like $w2[1]{cmd}, qr/02\.wave\.json'/, 'pesma 2';

	# neuspeh: bez fajla, red ide dalje
	$w2[1]{on_exit}->(1);
	is $c->wave($DISCID, 2), undef, 'neuspeo talas';

	$c->clear;
	is_deeply $c->status->{waves}, [], 'clear brise spisak talasa';
}

# ---- wave_first i restart (postojeci fajlovi) ----
{
	@SP = ();
	my $dir = "$root/c2";
	mkdir $dir;
	mkdir "$dir/$DISCID";
	for my $n (1 .. 3) { open my $fh, '>', sprintf('%s/%s/%02d.flac', $dir, $DISCID, $n) or die; print {$fh} 'x'; close $fh }
	$W->can('write_file')->("$dir/$DISCID/02.wave.json", { points => 1, peak => [1], rms => [1] });
	my $c = Plugins::AudioCD::Cache->new(spawn => $fake, dir => $dir, device => '/dev/sr0', paranoia => 'p', flac => 'flac',
		wave_helper => [ 'perl', '-e', 'Plugins::AudioCD::Wave::main()' ]);
	$c->start($disc, $toc, 1);
	my @w = grep { $_->{wave} } @SP;
	is scalar @w, 1, 'posle restarta: racuna se samo jedan u isto vreme';
	like $w[0]{cmd}, qr/01\.wave\.json'/, 'prva nedostajuca pesma';
	ok $c->wave($DISCID, 2), 'postojeci talas se cita';
	$c->wave_first(3);
	is_deeply $c->{wave_queue}, [3], 'red';
	$c->start({ %$disc, discid => 'Y5YcSD94m8NHH5Zrj6gYEHIq5k8-' }, $toc, 1);
	ok $w[0]{killed}, 'drugi disk prekida racunanje';
}

# ---- bez wave_helper: nista ----
{
	@SP = ();
	my $dir = "$root/c3";
	mkdir $dir;
	my $c = Plugins::AudioCD::Cache->new(spawn => $fake, dir => $dir, device => '/dev/sr0', paranoia => 'p', flac => 'flac');
	$c->start($disc, $toc, 1);
	$SP[0]{on_exit}->(0);
	is scalar(grep { $_->{wave} } @SP), 0, 'iskljuceno bez wave_helper';
}

# ---- pravi proces: flac na disku, ako postoji ----
SKIP: {
	my $flac = Plugins::AudioCD::Tools::find('flac');
	skip 'nema flac', 3 unless $flac;
	my $raw = "$root/t.raw";
	open my $fh, '>:raw', $raw or die;
	print {$fh} pack('s<*', map { int(10000 * sin($_ / 20)) } 1 .. 2 * 44100 * 3);
	close $fh;
	my $f = "$root/t.flac";
	system($flac, '-s', '-f', '--force-raw-format', '--endian=little', '--sign=signed', '--channels=2', '--bps=16',
		'--sample-rate=44100', '-o', $f, $raw) == 0 or skip 'flac kodiranje nije uspelo', 3;
	my $out = "$root/t.wave.json";
	my $lib = File::Spec->rel2abs('lib');
	my $cmd = join ' ', map { "'$_'" } $flac, '-d', '-c', '-s', '--force-raw-format', '--endian=little', '--sign=signed', $f;
	$cmd .= " | '$^X' -I '$lib' -MPlugins::AudioCD::Wave -e 'Plugins::AudioCD::Wave::main()' -- '$f' '$out'";
	is system('/bin/bash', '-c', "set -o pipefail; $cmd"), 0, 'flac -d | Wave::main';
	my $w = $W->can('read_file')->($out);
	is $w->{points}, 400, '400 tacaka';
	my @p = grep { $_ >= 290 && $_ <= 320 } @{ $w->{peak} };
	cmp_ok scalar @p, '>', 390, 'vrh sinusa ~305 svuda';
}

done_testing;
