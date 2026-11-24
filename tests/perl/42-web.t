use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use JSON::PP ();

use lib dirname(__FILE__) . '/lib';
use LMSBoot;

use Plugins::AudioCD::Web;
use Plugins::AudioCD::Url;

my $dir = 'lib/Plugins/AudioCD';
my $html = "$dir/HTML/EN/plugins/AudioCD";

sub slurp { my ($f) = @_; open my $fh, '<:encoding(UTF-8)', $f or die "$f: $!"; local $/; return <$fh> }

# ---------- ruta omota: discid se validira ----------
my $id = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';    # pravi MusicBrainz disc ID (27 znakova + '-')
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/$id.jpg"), $id, 'ispravan discid se prihvata');
is(Plugins::AudioCD::Web::cover_discid("/plugins/AudioCD/cover/$id.jpg"), $id, 'vodeca kosa crta je ok');
for my $bad ('../x', '../../etc/passwd', '..', "$id/../x", 'x', 'abc-', "${id}x", substr($id, 1), '..........................-/..', "$id\n", '%2e%2e%2fx') {
	my $p = "plugins/AudioCD/cover/$bad.jpg";
	(my $shown = $bad) =~ s/\n/\\n/g;
	is(Plugins::AudioCD::Web::cover_discid($p), undef, "odbijen: $shown");
}
for my $suf (qw(_100x100_f _50x50_o _300x300_f _40x40 _1200x1200_c)) {
	is(Plugins::AudioCD::Web::cover_discid("/plugins/AudioCD/cover/$id$suf.jpg"), $id, "Material velicina $suf se prihvata");
}
for my $badsuf ('_100x100_ff', '_x100_f', '_100x100_F', '_100x100_f/..', '_10000x1_f', '_100x100_f_f', '_100_f', '-100x100', '_100x100_1') {
	is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/$id$badsuf.jpg"), undef, "odbijen sufiks: $badsuf");
}
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/../x_100x100_f.jpg"), undef, 'losa putanja i sa sufiksom');
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/abc-_100x100_f.jpg"), undef, 'los discid i sa sufiksom');
# URL koji plugin sam daje: "cd." ispred discid-a drzi putanju van LMS-ovog resizera (vidi dole)
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/cd.$id.jpg"), $id, 'cd.<discid>.jpg se prihvata');
is(Plugins::AudioCD::Web::cover_discid("/plugins/AudioCD/cover/cd.${id}_100x100_f.jpg"), $id, 'cd.<discid>_100x100_f.jpg se prihvata');
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/cd.cd.$id.jpg"), undef, 'dupli prefiks se odbija');
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/xx.$id.jpg"), undef, 'drugi prefiks se odbija');
is(Plugins::AudioCD::Web::cover_url($id), "plugins/AudioCD/cover/cd.$id.jpg", 'cover_url');
{
	# LMS (Slim::Web::HTTP) sve putanje oblika /ime_WxH[_m] salje svom resizeru, koji ne zna za nase omote (404).
	# "cd." pre discid-a prekida [\w-]+ pa putanja stize do nase rute, i sa Material sufiksom.
	my $lms = qr/\/[\w-]+_(X|\d+)x(X|\d+)(?:_([mpsSfFco]))?(?:_[\da-fA-F]+)?/x;
	for my $d ($id, 'a_b_c.d-e_f-g.h_i-j.k_l-m_n-', 'AAAAAAAAAAAAAAAAAAAAAAAAAAA-') {
		my $u = Plugins::AudioCD::Web::cover_url($d);
		(my $m = $u) =~ s/\.jpg$/_100x100_f.jpg/;
		unlike("/$m", $lms, "Material URL za $d ne ide LMS resizeru");
		like($m, Plugins::AudioCD::Web::COVER_RE, "...a nasa ruta ga prihvata");
	}
	like('/plugins/AudioCD/cover/' . $id . '_100x100_f.jpg', $lms, 'bez prefiksa bi ga resizer preuzeo (zato prefiks)');
}
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/cover/$id.png"), undef, 'samo .jpg');
for my $g ('cd-generic.png', 'cd-generic_100x100_f.png', 'cd-generic_50x50_o.png', 'cd-generic_300x300_f.png') {
	like("plugins/AudioCD/$g", Plugins::AudioCD::Web::GENERIC_RE, "genericki CD: $g");
}
for my $g ('cd-generic.jpg', 'cd-generic_x.png', 'cd-generic_100x100_ff.png', 'cd-generic/../x.png', 'cd-genericX.png') {
	unlike("plugins/AudioCD/$g", Plugins::AudioCD::Web::GENERIC_RE, "genericki CD odbijen: $g");
}
is(Plugins::AudioCD::Web::cover_discid("plugins/AudioCD/other/$id.jpg"), undef, 'samo ispod cover/');
is(Plugins::AudioCD::Web::cover_discid(undef), undef, 'undef');

{
	my $tmp = tempdir(CLEANUP => 1);
	open my $o, '>:raw', "$tmp/$id.jpg" or die $!;
	print {$o} "\xFF\xD8\xFF" . ('x' x 200);
	close $o;
	my $cover_path = sub { "$tmp/$_[0].jpg" };

	my ($f, $ct) = Plugins::AudioCD::Web::cover_file("plugins/AudioCD/cover/$id.jpg", $cover_path);
	is($f, "$tmp/$id.jpg", 'omot postoji: njegov fajl');
	is($ct, 'image/jpeg', '...i image/jpeg');

	my $other = 'AAAAAAAAAAAAAAAAAAAAAAAAAAA-';
	($f, $ct) = Plugins::AudioCD::Web::cover_file("plugins/AudioCD/cover/$other.jpg", $cover_path);
	like($f, qr{/cd-generic\.png\z}, 'nema omota: genericki CD');
	is($ct, 'image/png', '...i image/png');
	ok(-f $f, 'genericki CD postoji u paketu');
	open my $g, '<:raw', $f or die $!;
	read $g, my $magic, 8;
	is($magic, "\x89PNG\r\n\x1a\n", 'cd-generic.png je PNG');
	ok(-s $f < 100_000, 'cd-generic.png je mala');

	($f, $ct) = Plugins::AudioCD::Web::cover_file("plugins/AudioCD/cover/${id}_100x100_f.jpg", $cover_path);
	is($f, "$tmp/$id.jpg", 'Material velicina: isti fajl omota');
	is($ct, 'image/jpeg', '...i image/jpeg');

	($f, $ct) = Plugins::AudioCD::Web::cover_file("plugins/AudioCD/cover/cd.${id}_50x50_o.jpg", $cover_path);
	is($f, "$tmp/$id.jpg", 'cd. prefiks + Material velicina: isti fajl omota');

	($f, $ct) = Plugins::AudioCD::Web::cover_file('plugins/AudioCD/cover/../x.jpg', $cover_path);
	like($f, qr{/cd-generic\.png\z}, 'losa putanja ne cita nista sem generickog CD-a');
}

# ---------- tekstovi ----------
my @tokens = Plugins::AudioCD::Web::ui_tokens("$dir/strings.txt");
ok(scalar(@tokens) > 100, 'ui_tokens cita strings.txt');
my %have = map { $_ => 1 } @tokens;

# svaki token ima EN i SR
{
	my $text = slurp("$dir/strings.txt");
	my %lang;
	my $cur;
	for my $l (split /\n/, $text) {
		if ($l =~ /^(PLUGIN_AUDIOCD\w*)\s*$/) { $cur = $1; next }
		$lang{$cur}{$1} = $2 if defined $cur && $l =~ /^\t(EN|SR)\t(.+)$/;
	}
	my @bad = grep { !($lang{$_}{EN} && $lang{$_}{SR}) } @tokens;
	is_deeply(\@bad, [], 'svaki token ima EN i SR') or diag "@bad";
	# placeholderi {N} moraju biti isti u EN i SR
	my @mism = grep {
		my ($e, $s) = @{ $lang{$_} }{qw(EN SR)};
		join(',', sort $e =~ /\{(\d+)\}/g) ne join(',', sort $s =~ /\{(\d+)\}/g)
	} @tokens;
	is_deeply(\@mism, [], 'EN i SR imaju iste {N} placeholdere') or diag "@mism";
}

my $strings = Plugins::AudioCD::Web::ui_strings(sub { "<$_[0]>" }, @tokens);
ok(exists $strings->{UI_PLAY} && exists $strings->{ERR_NO_DISC} && exists $strings->{TITLE}, 'ui_strings: UI_, ERR_ i naziv');
ok(!(grep { /^SET_/ } keys %$strings), 'SET_* tekstovi ne idu u stranicu');

my $json = Plugins::AudioCD::Web::html_json({ a => "</script><b>&\x{10d}" });
unlike($json, qr/[<>&]/, 'html_json: bez <, > i &');
unlike($json, qr/[^\x00-\x7f]/, 'html_json: samo ASCII');
is(JSON::PP->new->decode($json)->{a}, "</script><b>&\x{10d}", 'html_json: vrednost se vraca nepromenjena');

# JS koristi samo postojece tokene (nema teksta u kodu)
my $js = slurp("$html/audiocd.js");
my $page = slurp("$html/index.html");
{
	my %used = map { $_ => 1 } $js =~ /\bt\('([A-Z_]+)'\s*[,)]/g;
	my @missing = grep { !$have{"PLUGIN_AUDIOCD_$_"} && !($_ eq 'TITLE') } sort keys %used;
	is_deeply(\@missing, [], 'svaki t(KLJUC) u JS postoji u strings.txt') or diag "@missing";
	ok(scalar(keys %used) > 40, 'JS koristi tekstove iz strings.txt');
	my @s = $js =~ /\bS\['([A-Z_]+)'\]/g;    # direktni pristupi
	is_deeply([ grep { !$have{"PLUGIN_AUDIOCD_$_"} } @s ], [], 'direktni S[...] kljucevi postoje');

	# dinamicki kljucevi: sve vrednosti koje server moze da vrati
	my %dyn = (
		UI_BUSY_      => [qw(rip cache lookup process)],
		UI_PROFILE_   => [qw(fast balanced secure)],
		UI_RESULT_    => [qw(ok accurip_mismatch error cancelled)],
		UI_REASON_    => [qw(ejected aborted)],
		UI_SOURCE_    => [qw(musicbrainz gnudb cdtext generic manual)],
		ERR_WARN_     => [qw(source_not_removed)],
		UI_NOTE_      => [qw(check_offset no_speed)],
	);
	like($js, qr/'UI_NOTE_'/, 'JS prikazuje napomene istorije (check_offset, no_speed)');
	for my $p (sort keys %dyn) {
		my @m = grep { !$have{ 'PLUGIN_AUDIOCD_' . $p . uc $_ } } @{ $dyn{$p} };
		is_deeply(\@m, [], "dinamicki kljucevi $p* postoje") or diag "@m";
	}
	# svi kodovi gresaka koje CLI/State/Library/Drive vracaju (Task 12/13) imaju poruku
	my @codes = qw(bad_args bad_index bad_track busy busy_disc cache_failed cache_no_space rip_dir_outside drive_busy eject eject_pending failed
		missing_tools move_failed copy_failed verify_failed mkdir_failed not_writable no_audio no_disc no_device no_player no_space
		not_available not_found play_failed rips_dir rip_failed save_failed stopped exists outside_library outside_rips
		timeout permission io helper drive_timeout);
	my @nomsg = grep { !$have{ 'PLUGIN_AUDIOCD_ERR_' . uc $_ } } @codes;
	is_deeply(\@nomsg, [], 'svaki kod greske ima poruku') or diag "@nomsg";
	ok($have{PLUGIN_AUDIOCD_ERR_UNKNOWN}, 'postoji poruka za nepoznat kod');
}

# Ruling 15: nigde FLAC nivo
unlike($js . $page, qr/flac/i, 'stranica i JS nemaju FLAC nivo (Ruling 15)');
unlike(slurp("$html/settings/basic.html"), qr/flac/i, 'podesavanja nemaju FLAC nivo');

# stranica: bez spoljnih biblioteka, svetla/tamna tema, uska stranica
unlike($page . $js, qr{(?:src|href)\s*=\s*["']https?://}i, 'bez spoljnih resursa');
my $css = slurp("$html/audiocd.css");
like($css, qr/prefers-color-scheme:\s*dark/, 'tamna tema preko prefers-color-scheme');
like($css, qr/max-width:\s*480px/, 'pravila za usku stranicu');
like($page, qr/name="viewport"/, 'viewport meta');
like($js, qr{/jsonrpc\.js}, 'JSON-RPC');
like($js, qr/cmd\('load', 'force:1'\)/, 'Pokusaj ponovo salje load force:1');
like($js, qr/missing_tools \|\| \[\]\)\.length/, 'Ripuj se gasi kad nedostaju alati');
like($js, qr/e\.moved \? t\('UI_MOVED_TO'/, 'oznaka biblioteke po e.moved');
unlike($js, qr/run\(cmd\(/, 'run() dobija funkciju, ne gotov zahtev');
like($js, qr/catch \(e\)/, 'localStorage u try/catch');

# Pause/Nastavi/Stop za CD koji svira na izabranom plejeru; Ripuj nudi da se slusanje prvo zaustavi
unlike($page, qr/id="btn-pause"/, 'Play i Pauza su jedno dugme');
like($page, qr/id="rip-stop-box"[^>]*hidden/, 'rip dijalog: opcija za zaustavljanje sakrivena');
like($js, qr/\['status', '-', 1, 'tags:u'\]/, 'stanje plejera preko ["status","-",1,"tags:u"]');
like($js, qr/audiocd:\\\/\\\//, 'CD se prepoznaje po audiocd:// URL-u');
like($js, qr/transport\(\['stop'\]\)/, 'Stop salje ["stop"]');
like($js, qr/\['pause', $_\]/, "Play\/Pauza salje [pause, $_]") for 0, 1;
like($page, qr/id="$_" class="icon[^"]*" disabled><svg/, "$_: ikona, iskljuceno dok CD ne svira") for qw(btn-prev btn-play btn-next btn-stop);
like($page, qr/id="$_"/, "displej: $_") for qw(display lcd-track lcd-time lcd-mode lcd-text lcd-cal lcd-total);
like($js, qr/iconText\('$_'/, "$_: naziv za citace ekrana") for qw(btn-prev btn-play btn-next btn-stop);
like($js, qr/\['playlist', 'index', '\Q$_\E1'\]/, "prethodna/sledeca: $_") for '-', '+';
like($js, qr/'stop_cache:1'/, 'rip sa zaustavljanjem salje stop_cache:1');
like($js, qr/res\.busy === 'process'/, 'rip ponavlja dok prekinut proces umire');
like($css, qr/\.field\[hidden\] \{ display: none; \}/, 'sakriveno .field.check polje se ne prikazuje');
for my $k (qw(UI_PAUSE UI_RESUME UI_STOP UI_NOW_PLAYING UI_NOW_PAUSED UI_RIP_STOP_PLAYBACK)) {
	ok($have{"PLUGIN_AUDIOCD_$k"}, "tekst $k postoji");
	like($js, qr/'\Q$k\E'/, "JS koristi $k");
}
# Brisanje istorije: dugme uz naslov, potvrda, komanda history_clear (registrovana u Plugin.pm)
like($page, qr/id="hist-clear"[^>]*hidden/, 'Obrisi istoriju: sakriveno dok je istorija prazna');
like($js, qr/window\.confirm\(t\('UI_HISTORY_CLEAR_CONFIRM'\)\)/, 'Obrisi istoriju trazi potvrdu');
like(slurp("$dir/Plugin.pm"), qr/history_clear\s*=>\s*\[ 0, 0, 1, \\&_cli_history_clear \]/, 'CLI audiocd history_clear');
for my $k (qw(UI_HISTORY_CLEAR UI_HISTORY_CLEAR_CONFIRM UI_HISTORY_CLEARED)) {
	ok($have{"PLUGIN_AUDIOCD_$k"}, "tekst $k postoji");
	like($js, qr/'\Q$k\E'/, "JS koristi $k");
}
for my $cmdname (qw(status history history_clear load play rip cancel eject select_release edit move)) {
	like($js, qr/\Q'$cmdname'\E/, "JS poziva audiocd $cmdname");
}
like($js, qr/\['players', 0, 99\]/, 'plejeri preko ["players",0,99]');

# Material: tema, fiksni plejer, Settings samo u novom tabu
like($js, qr/params\.get\('player'\)|get\('player'\)/, 'JS cita ?player=');
like($js, qr/'--background-color'/, 'JS cita Material boje (--background-color)');
like($js, qr/'--primary-color'/, 'JS cita Material akcenat (--primary-color)');
like($js, qr/window\.parent/, 'JS detektuje Material iframe');
like($js, qr/stopImmediatePropagation\(\)/, 'Settings klik ne stize do Material-ovog handlera');
like($js, qr/closest\('#settings-link'\)[\s\S]*?\}, true\);/, 'Settings: capture listener na document-u');
like($js, qr/\^\[0-9a-f\]\{2\}\(:\[0-9a-f\]\{2\}\)\{5\}\$\/i/, '?player= se validira (MAC)');
ok(index($js, '/^[\w.:-]{1,64}$/.test(v)') >= 0, '?player= se validira (bezbedan id)');
is(Plugins::AudioCD::Url::cover_url($id), "plugins/AudioCD/cover/cd.$id.jpg", 'Url::cover_url');
for my $f (qw(ProtocolHandler Menu)) {
	like(slurp("$dir/$f.pm"), qr/Plugins::AudioCD::Url::cover_url/, "$f koristi Url::cover_url");
	unlike(slurp("$dir/$f.pm"), qr{AudioCD/cover/}, "$f ne gradi URL omota rucno");
}
like($js, qr/window\.open\(.*'_blank', 'noopener'\)/, 'Settings u Material-u: window.open(_blank, noopener)');
like($page, qr/id="settings-link"[^>]*target="_blank"[^>]*rel="noopener"/, 'Settings link: target=_blank rel=noopener');
like($css, qr/\.embedded/, 'CSS ima izgled za Material iframe');
like($css, qr/\.player-pick\[hidden\]|fixed-player/, 'CSS: sakriven izbor plejera');
# Tema iz Materiala: odluka po pozadini (ne po OS-u), tekst iz --light/--dark-text-color, kartice iz popup boje
like($js, qr/function materialTheme\(/, 'cista funkcija materialTheme');
like($js, qr/luma\(bg\) < 0\.5/, 'tamna tema = tamna pozadina iz Materiala');
like($js, qr/dark \? v\['--light-text-color'\] : v\['--dark-text-color'\]/, 'tekst: --light-text-color na tamnoj, --dark-text-color na svetloj');
like($js, qr/--std-popup-background-color/, 'kartice iz --std-popup-background-color');
like($js, qr/setAttribute\('data-theme', th\.dark/, 'data-theme iz Materiala, ne iz prefers-color-scheme');
like($js, qr/Roboto, "Segoe UI", system-ui, sans-serif/, 'rezervni font kad je roditeljski serif/Times');
like($css, qr/\.link \{ color: var\(--link/, 'linkovi: --link (Material accent)');
unlike($js, qr/innerHTML/, 'JS bez innerHTML');

# ---------- Settings::validate (LMS okruzenje) ----------
{
	my $tmp = tempdir(CLEANUP => 1);
	mkdir "$tmp/music" or die $!;
	mkdir "$tmp/rips" or die $!;
	mkdir "$tmp/other" or die $!;
	my $code = q{
		require JSON::PP; require Plugins::AudioCD::Settings;
		my ($tmp) = @ARGV;
		my %ok = (device => '/dev/cdrom', ripsDir => "$tmp/rips", libraryDir => "$tmp/music/Rips", profile => 'secure',
			quietSpeed => '8', driveOffset => '-6', onInsert => 'play', autoPlayPlayer => 'dc:a6:32:56:a8:04', autoRipProfile => 'fast', autoLoad => 1, notify => 1);
		my %cases;
		my $run = sub { my ($name, %over) = @_;
			my %in = (%ok, %over);
			delete $in{$_} for grep { !defined $in{$_} } keys %in;
			my ($c, $e) = Plugins::AudioCD::Settings::validate(\%in, media => ["$tmp/music"]);
			$cases{$name} = { clean => $c, err => $e };
		};
		$run->('ok');
		$run->('flac9', flacLevel => 9);
		$run->('rel_rips', ripsDir => 'relative/dir');
		$run->('dotdot_rips', ripsDir => "$tmp/rips/../x");
		$run->('creatable_rips', ripsDir => "$tmp/rips/new/deeper");
		$run->('uncreatable_rips', ripsDir => "/proc/nope/x");
		$run->('empty_rips', ripsDir => '');
		$run->('lib_outside', libraryDir => "$tmp/other/x");
		$run->('lib_rel', libraryDir => 'music/x');
		$run->('lib_empty', libraryDir => '');
		$run->('ins_bad', onInsert => 'x');
		$run->('ins_noplayer', autoPlayPlayer => '');
		$run->('ins_rip', onInsert => 'rip', autoPlayPlayer => '');
		$run->('ins_badplayer', autoPlayPlayer => 'x');
		$run->('speed0', quietSpeed => 0);
		$run->('speed1', quietSpeed => 1);
		$run->('speed52', quietSpeed => 52);
		$run->('speed53', quietSpeed => 53);
		$run->('speedx', quietSpeed => 'abc');
		$run->('speedneg', quietSpeed => '-3');
		$run->('profile_bad', profile => 'ultra');
		$run->('dev_bad', device => 'cdrom');
		$run->('dev_dotdot', device => '/dev/../etc/passwd');
		$run->('offset_bad', driveOffset => 'x');
		$run->('offset_big', driveOffset => 99999);
		$run->('offset_empty', driveOffset => '');
		print JSON::PP->new->canonical->encode(\%cases);
	};
	my $out = LMSBoot::run($code, $tmp);
	my $r = eval { JSON::PP->new->decode($out) };
	ok($r, 'validate se izvrsava bez upozorenja') or diag $out;
	$r ||= {};

	my $err = sub { $r->{ $_[0] }{err} || {} };
	is_deeply($err->('ok'), {}, 'ispravan unos: nema gresaka');
	is($r->{ok}{clean}{quietSpeed}, 8, 'brzina se cuva kao broj');
	is($r->{ok}{clean}{libraryDir}, "$tmp/music/Rips", 'libraryDir ispod muzickog foldera');
	ok($err->('ins_bad')->{onInsert}, 'onInsert: nepoznata vrednost se odbija');
	ok($err->('ins_noplayer')->{autoPlayPlayer}, 'play bez plejera se odbija');
	is_deeply($err->('ins_rip'), {}, 'rip bez plejera je ok');
	ok($err->('ins_badplayer')->{autoPlayPlayer}, 'neispravan ID plejera se odbija');
	is($r->{ok}{clean}{notify}, 1, 'cekirano = 1');
	is($r->{ok}{clean}{polling}, 0, 'necekirano (nije poslato) = 0');
	ok(!exists $r->{ok}{clean}{flacLevel}, 'flacLevel se ne validira ni cuva (Ruling 15)');
	is_deeply($err->('flac9'), {}, 'flacLevel 9 se ignorise, nije greska (Ruling 15)');
	ok(!exists $r->{flac9}{clean}{flacLevel}, '...i ne dospeva u prefs');

	ok($err->('rel_rips')->{ripsDir}, 'relativna putanja foldera za ripove se odbija');
	ok($err->('dotdot_rips')->{ripsDir}, 'putanja sa .. se odbija');
	is_deeply($err->('creatable_rips'), {}, 'folder koji se moze napraviti je ok');
	ok($err->('uncreatable_rips')->{ripsDir}, 'folder koji ne moze da se napravi se odbija');
	is_deeply($err->('empty_rips'), {}, 'prazan ripsDir = podrazumevani');
	ok($err->('lib_outside')->{libraryDir}, 'libraryDir van muzickih foldera se odbija');
	ok($err->('lib_rel')->{libraryDir}, 'relativan libraryDir se odbija');
	is_deeply($err->('lib_empty'), {}, 'prazan libraryDir = prvi muzicki folder');
	ok($err->('speed0')->{quietSpeed}, 'brzina 0 se odbija');
	is_deeply($err->('speed1'), {}, 'brzina 1 je ok');
	is_deeply($err->('speed52'), {}, 'brzina 52 je ok');
	ok($err->('speed53')->{quietSpeed}, 'brzina 53 se odbija');
	ok($err->('speedx')->{quietSpeed}, 'brzina "abc" se odbija');
	ok($err->('speedneg')->{quietSpeed}, 'negativna brzina se odbija');
	ok($err->('profile_bad')->{profile}, 'nepoznat profil se odbija');
	ok($err->('dev_bad')->{device}, 'relativan uredjaj se odbija');
	ok($err->('dev_dotdot')->{device}, 'uredjaj sa .. se odbija');
	ok($err->('offset_bad')->{driveOffset}, 'ofset "x" se odbija');
	ok($err->('offset_big')->{driveOffset}, 'preveliki ofset se odbija');
	is_deeply($err->('offset_empty'), {}, 'prazan ofset je ok');
	is($r->{offset_empty}{clean}{driveOffset}, '', '...i cuva se prazan');
	like($err->('speed0')->{quietSpeed}, qr/^PLUGIN_AUDIOCD_SET_ERR_/, 'greska je token iz strings.txt');
	my @errtok = map { $_ } grep { /^SET_ERR_/ } map { (my $x = $_) =~ s/^PLUGIN_AUDIOCD_//; $x } @tokens;
	ok(scalar(@errtok) >= 6, 'SET_ERR_* tokeni postoje');
}

# ---------- Web.pm i Settings.pm se ucitavaju u LMS-u ----------
for my $f ("$dir/Web.pm", "$dir/Settings.pm") {
	like(LMSBoot::syntax($f), qr/syntax OK/, "$f: syntax OK");
}

done_testing;
