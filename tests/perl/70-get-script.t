use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $pk = -d "$Bin/../packaging" ? "$Bin/../packaging" : "$Bin/../../packaging";

for my $f (qw(get.sh install.sh uninstall.sh)) {
	ok -f "$pk/$f", "$f postoji" or BAIL_OUT("nema packaging/$f");
	is system('bash', '-n', "$pk/$f"), 0, "bash -n $f";
}

# get.sh: nepoznata akcija
{
	my $out = `bash $pk/get.sh nesto 2>&1`;
	isnt $? >> 8, 0, 'get.sh odbija nepoznatu akciju';
	like $out, qr/Upotreba/, 'get.sh: uputstvo';
}

# get.sh: nedostupan paket prekida rad i nista ne pokrece
{
	my $dir = tempdir(CLEANUP => 1);
	my $out = `AUDIOCD_BASE_URL=file://$dir bash $pk/get.sh 2>&1`;
	isnt $? >> 8, 0, 'get.sh: nedostupan paket prekida rad';
	like $out, qr/preuzeti/i, 'get.sh: poruka o preuzimanju';
}

# get.sh: pogresan otisak
{
	my $dir = tempdir(CLEANUP => 1);
	my $build = tempdir(CLEANUP => 1);
	mkdir "$build/audiocd-9.9.9";
	open my $fh, '>', "$build/audiocd-9.9.9/install.sh" or die $!;
	print {$fh} "echo RAN-install\n";
	close $fh;
	system("cd $build && python3 -m zipfile -c $dir/audiocd.zip audiocd-9.9.9") == 0 or die 'zip';
	open my $sh, '>', "$dir/audiocd.zip.sha256" or die $!;
	print {$sh} ('0' x 64) . "  audiocd.zip\n";
	close $sh;
	my $out = `AUDIOCD_BASE_URL=file://$dir bash $pk/get.sh 2>&1`;
	isnt $? >> 8, 0, 'get.sh: pogresan otisak prekida rad';
	unlike $out, qr/RAN-/, 'get.sh: nista se ne pokrece';

	# ispravan otisak: pokrece install.sh iz paketa
	system("cd $dir && sha256sum audiocd.zip > audiocd.zip.sha256") == 0 or die 'sha';
	$out = `AUDIOCD_BASE_URL=file://$dir bash $pk/get.sh 2>&1`;
	is $? >> 8, 0, 'get.sh: ispravan paket';
	like $out, qr/RAN-install/, 'get.sh: pokrece install.sh';
}

# install.sh i uninstall.sh bez root-a
SKIP: {
	skip 'pokrenuto kao root', 4 if $> == 0;
	for my $f (qw(install.sh uninstall.sh)) {
		my $out = `bash $pk/$f 2>&1`;
		isnt $? >> 8, 0, "$f bez root-a izlazi sa greskom";
		like $out, qr/root/, "$f: poruka o root-u";
	}
}

# uninstall.sh: uklanjanje AudioCD bloka ne dira Unified Music blok
{
	my $dir = tempdir(CLEANUP => 1);
	my $file = "$dir/custom.js";
	my $unified = "// UnifiedMusic start\n(function () { var a = 1; })();\n// UnifiedMusic end\n";
	my $audio = "// AudioCD start\n(function () {\n    var s = 1;\n})();\n// AudioCD end\n";
	my $other = "console.log('x');\n";

	my $write = sub { open my $fh, '>:raw', $file or die $!; print {$fh} $_[0]; close $fh };
	my $read = sub { open my $fh, '<:raw', $file or die $!; local $/; my $t = <$fh>; close $fh; $t };
	my $run = sub { system('bash', '-c', 'source "$1"; remove_audiocd_block "$2"', 'x', "$pk/uninstall.sh", $file) };

	$write->($other . $unified . $audio);
	is $run->(), 0, 'remove_audiocd_block izlazi sa 0';
	is $read->(), $other . $unified, 'AudioCD blok uklonjen, Unified Music i ostalo netaknuto';

	$write->($audio . $unified);
	$run->();
	is $read->(), $unified, 'blok na pocetku uklonjen';

	$write->($other . $unified);
	$run->();
	is $read->(), $other . $unified, 'bez AudioCD bloka fajl je isti';

	$write->("a\r\n// AudioCD start\r\nx\r\n// AudioCD end\r\nb\r\n");
	$run->();
	is $read->(), "a\r\nb\r\n", 'CRLF fajl';

	chmod 0640, $file;
	$write->($other . $audio);
	chmod 0640, $file;
	$run->();
	is((stat $file)[2] & 07777, 0640, 'dozvole fajla ostaju');
	my @left = glob("$dir/*.audiocd.*");
	is scalar(@left), 0, 'nema privremenih fajlova';
}

done_testing;
