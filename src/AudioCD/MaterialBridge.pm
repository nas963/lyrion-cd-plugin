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
sub remove_custom_js {
	my ($text) = @_;

	$text //= '';
	$text =~ s/^\Q$START\E\n.*?^\Q$END\E\n?//ms;
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

	my $file = "$dir/custom.js";
	return _rewrite($file, \&merge_custom_js, 1);
}

# Uklanja nas blok iz custom.js (fajl koji ne postoji se ne pravi).
sub uninstall {
	my ($dir) = @_;

	return _rewrite("$dir/custom.js", \&remove_custom_js, 0);
}

sub _rewrite {
	my ($file, $fn, $create) = @_;

	my $current = '';
	if (open my $in, '<:raw', $file) {
		local $/;
		$current = <$in>;
		close $in;
	}
	elsif (!$create) {
		return 0;
	}
	my $new = $fn->($current);
	return 0 if $new eq $current;

	(my $parent = $file) =~ s{/[^/]*\z}{};
	require File::Path;
	File::Path::make_path($parent) unless -d $parent;
	open my $out, '>:raw', $file or die "$file: $!";
	print {$out} $new;
	close $out or die "$file: $!";
	return 1;
}

1;
