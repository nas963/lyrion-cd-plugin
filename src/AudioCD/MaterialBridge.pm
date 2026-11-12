package Plugins::AudioCD::MaterialBridge;

# Blok koji Material-ov custom.js koristi da ucita nasu skriptu. Cist Perl, bez Lyrion-a.
# Blok Unified Music-a (i bilo koji drugi kod) u custom.js se nikad ne dira: menja se samo
# tekst izmedju nasih markera.

use strict;
use warnings;
use utf8;

my $START = '// AudioCD start';
my $END   = '// AudioCD end';

my $BLOCK = <<"END_BLOCK";
$START
(function () {
    var script = document.createElement("script");
    script.src = "/plugins/AudioCD/material/audiocd-material.js?v=" + Math.floor(Date.now() / 3600000);
    document.body.appendChild(script);
})();
$END
END_BLOCK

# Uklanja samo nas blok (sa zavrsnim novim redom); bez bloka tekst ostaje isti.
# Tolerise \r\n. Ostatak (start bez kraja): uklanja se marker i, ako odmah iza njega stoji
# nasa funkcija, ona do prvog "})();"; kod iza se ne dira (ni Unified Music blok).
sub remove_custom_js {
	my ($text) = @_;

	$text //= '';
	$text =~ s/^\Q$START\E[ \t]*\r?\n.*?^\Q$END\E[ \t]*(?:\r?\n|\z)//ms;
	$text =~ s/^\Q$START\E[ \t]*(?:\r?\n|\z)(?:\(function \(\) \{[^\n]*\n.*?^\}\)\(\);[ \t]*(?:\r?\n|\z))?//ms;
	$text =~ s/^\Q$END\E[ \t]*(?:\r?\n|\z)//m;
	return $text;
}

# Nas blok je na kraju teksta, tacno jednom (ponovljen poziv ne menja rezultat).
sub merge_custom_js {
	my ($text) = @_;

	$text = remove_custom_js($text);
	$text .= "\n" if length $text && $text !~ /\n\z/;
	return $text . $BLOCK;
}

# Upisuje nas blok u <prefs>/material-skin/custom.js (pravi folder ako treba); ne dira ostatak fajla.
# Fajl se ne pise ako se tekst ne menja. Baca izuzetak pri gresci u I/O.
sub install {
	my ($dir) = @_;

	return _rewrite("$dir/custom.js", \&merge_custom_js, 1);
}

# Uklanja nas blok iz custom.js (fajl koji ne postoji se ne pravi).
sub uninstall {
	my ($dir) = @_;

	return _rewrite("$dir/custom.js", \&remove_custom_js, 0);
}

# Samo ENOENT znaci "nema fajla"; svaka druga greska citanja baca izuzetak (postojeci fajl se nikad
# ne prepisuje ako nije procitan). Upis je atomski: privremeni fajl u istom folderu, pa rename;
# pri gresci se privremeni fajl brise, original ostaje.
sub _rewrite {
	my ($file, $fn, $create) = @_;

	my $current = '';
	my $mode;
	if (open my $in, '<:raw', $file) {
		local $/;
		$current = <$in>;
		defined $current or die "$file: $!";
		close $in or die "$file: $!";
		$mode = (stat $file)[2];
		$mode = $mode & 07777 if defined $mode;
	}
	elsif ($!{ENOENT}) {
		return 0 unless $create;
	}
	else {
		die "$file: $!";
	}
	my $new = $fn->($current);
	return 0 if $new eq $current;

	(my $parent = $file) =~ s{/[^/]*\z}{};
	require File::Path;
	File::Path::make_path($parent) unless -d $parent;

	my $tmp = "$file.audiocd.$$";
	my $ok = eval {
		open my $out, '>:raw', $tmp or die "$tmp: $!\n";
		print {$out} $new or die "$tmp: $!\n";
		close $out or die "$tmp: $!\n";
		chmod $mode, $tmp if defined $mode;
		rename $tmp, $file or die "$file: $!\n";
		1;
	};
	unless ($ok) {
		my $err = $@;
		unlink $tmp;
		die $err;
	}
	return 1;
}

1;
