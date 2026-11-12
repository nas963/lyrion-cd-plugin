use strict;
use warnings;
use utf8;
use Test::More;

use Plugins::AudioCD::MaterialBridge;

my $um = <<'JS';
// UnifiedMusic start
(function () {
    var script = document.createElement("script");
    script.src = "/plugins/UnifiedMusic/material/unified-material.js?v=" + Math.floor(Date.now() / 3600000);
    document.body.appendChild(script);
})();
// UnifiedMusic end
JS

sub count { my ($t, $re) = @_; my $n = () = $t =~ /$re/g; return $n }

# prazan custom.js
my $m = Plugins::AudioCD::MaterialBridge::merge_custom_js('');
is count($m, qr{^// AudioCD start$}m), 1, 'prazan: start marker jednom';
is count($m, qr{^// AudioCD end$}m), 1, 'prazan: end marker jednom';
like $m, qr{/plugins/AudioCD/material/audiocd-material\.js\?v=" \+ Math\.floor\(Date\.now\(\) / 3600000\)}, 'blok ucitava skriptu sa verzijom po satu';

# tekst koji vec ima Unified Music blok
my $both = Plugins::AudioCD::MaterialBridge::merge_custom_js($um);
is count($both, qr{^// UnifiedMusic start$}m), 1, 'UM blok prisutan';
is count($both, qr{^// UnifiedMusic end$}m), 1, 'UM kraj prisutan';
is count($both, qr{^// AudioCD start$}m), 1, 'nas blok tacno jednom';
is index($both, $um), 0, 'UM blok netaknut (bajt po bajt, na pocetku)';

# ponovljen merge je idempotentan
my $again = Plugins::AudioCD::MaterialBridge::merge_custom_js($both);
is $again, $both, 'ponovljen merge ne menja tekst';
is count($again, qr{^// AudioCD start$}m), 1, 'i dalje jednom';

# korisnicki kod ispred ostaje
my $user = "// moj kod\nvar x = 1;\n";
my $mixed = Plugins::AudioCD::MaterialBridge::merge_custom_js($user . $um);
like $mixed, qr/\A\Q$user$um\E/, 'korisnicki kod i UM ostaju ispred naseg bloka';
is Plugins::AudioCD::MaterialBridge::merge_custom_js($mixed), $mixed, 'idempotentno i sa korisnickim kodom';

# nas blok usred teksta (iza njega ima koda): ostaje tacno jednom
my $mid = Plugins::AudioCD::MaterialBridge::merge_custom_js($both . "// kasnije\n");
is count($mid, qr{^// AudioCD start$}m), 1, 'nas blok jednom i kad iza ima koda';
like $mid, qr{// kasnije\n}, 'kod iza bloka ostaje';
is count($mid, qr{^// UnifiedMusic start$}m), 1, 'UM jednom';

# remove uklanja samo nas
is Plugins::AudioCD::MaterialBridge::remove_custom_js($both), $um, 'remove: ostaje samo UM blok, bajt po bajt';
is Plugins::AudioCD::MaterialBridge::remove_custom_js($m), '', 'remove: prazan ostatak';
is Plugins::AudioCD::MaterialBridge::remove_custom_js($um), $um, 'remove: bez naseg bloka nista se ne menja';
is Plugins::AudioCD::MaterialBridge::remove_custom_js(undef), '', 'remove: undef -> prazno';
is Plugins::AudioCD::MaterialBridge::remove_custom_js($user . $both . "// kraj\n"), $user . $um . "// kraj\n", 'remove u sredini teksta';

# obrnut redosled: nas blok pa UM
my $rev = Plugins::AudioCD::MaterialBridge::merge_custom_js('') . $um;
is Plugins::AudioCD::MaterialBridge::remove_custom_js($rev), $um, 'remove: nas blok ispred UM';

# install/uninstall nad pravim folderom
{
	use File::Temp qw(tempdir);
	my $d = tempdir(CLEANUP => 1) . '/material-skin';
	sub slurp { open my $f, '<:raw', $_[0] or die "$_[0]: $!"; local $/; return <$f> }
	sub spew { open my $f, '>:raw', $_[0] or die "$_[0]: $!"; print {$f} $_[1]; close $f }

	is Plugins::AudioCD::MaterialBridge::uninstall($d), 0, 'uninstall bez fajla: nista, ne pravi fajl';
	ok !-e "$d/custom.js", 'fajl nije napravljen';
	is Plugins::AudioCD::MaterialBridge::install($d), 1, 'install pravi folder i fajl';
	is count(slurp("$d/custom.js"), qr{^// AudioCD start$}m), 1, 'blok u fajlu';
	is Plugins::AudioCD::MaterialBridge::install($d), 0, 'ponovni install ne menja fajl';

	spew("$d/custom.js", $um);
	Plugins::AudioCD::MaterialBridge::install($d);
	my $f = slurp("$d/custom.js");
	is index($f, $um), 0, 'install: UM blok netaknut';
	is count($f, qr{^// AudioCD start$}m), 1, 'install: nas blok jednom';
	is Plugins::AudioCD::MaterialBridge::uninstall($d), 1, 'uninstall menja fajl';
	is slurp("$d/custom.js"), $um, 'uninstall: ostaje samo UM blok';

	spew("$d/custom.js", "var bez_novog_reda = 1;");
	Plugins::AudioCD::MaterialBridge::install($d);
	like slurp("$d/custom.js"), qr{^// AudioCD start$}m, 'blok pocinje u novom redu i kad fajl nema zavrsni newline';
}

# JS skripta
my $js = 'lib/Plugins/AudioCD/HTML/EN/plugins/AudioCD/material/audiocd-material.js';
ok -f $js, 'audiocd-material.js postoji';
open my $fh, '<:encoding(UTF-8)', $js or die "$js: $!";
my $src = do { local $/; <$fh> };
like $src, qr{/plugins/AudioCD/index\.html}, 'skripta otvara stranicu plugina';
like $src, qr{homeScreenItems}, 'skripta se kaci na Material home';
unlike $src, qr{UnifiedMusic|unified}i, 'skripta ne dira Unified Music';

done_testing;
