package Plugins::AudioCD::Web;

# Web stranica plugina: /plugins/AudioCD/index.html (podaci i komande idu preko JSON-RPC-a),
# omot diska /plugins/AudioCD/cover/<discid>.jpg i stavka u Extras meniju klasicnog web-a.
#
# Tekstovi: svi tokeni PLUGIN_AUDIOCD_* iz strings.txt idu u stranicu kao JSON (jezik servera),
# pa JS koristi t('UI_...') bez ikakvog teksta u kodu. Jedan mehanizam: TT promenljiva audiocdData.
# Cist deo (cover_discid, cover_file, ui_tokens, html_json) se testira bez LMS-a; LMS se ucitava tek u init.

use strict;
use warnings;
use utf8;

use File::Basename ();
use File::Spec ();
use JSON::PP ();

use Plugins::AudioCD::Cache;
use Plugins::AudioCD::Url;

use constant PAGE        => 'plugins/AudioCD/index.html';
use constant COVER_PREFIX => 'plugins/AudioCD/cover/';
# LMS (Slim::Web::HTTP) svaku putanju oblika /ime_WxH[_m] salje svom resizeru, koji ne zna za nase omote (404),
# a Material Skin svakoj slici pod /plugins/ dodaje takav sufiks. Zato je URL omota plugin/cover/cd.<discid>.jpg:
# tacka posle "cd" prekida ime koje regex resizera trazi, pa zahtev stize do nase rute (i sa sufiksom).
# Material Skin ubacuje velicinu pre ekstenzije (_100x100_f, _50x50_o, ...); to je jedini dozvoljen sufiks.
# Omot se vraca u originalnoj velicini (pretrazivac ga smanjuje), bez izrade novih fajlova.
use constant SIZE_SUFFIX => qr/(?:_[0-9]{1,4}x[0-9]{1,4}(?:_[a-z])?)?/;
# isti oblik kao Cache::valid_discid: 27 znakova + '-'; nista drugo (../ je odbijeno)
use constant COVER_RE    => qr{^plugins/AudioCD/cover/(?:cd\.)?([A-Za-z0-9._-]{27}-)@{[ SIZE_SUFFIX ]}\.jpg\z};
# Genericki CD (cd-generic.png) je u HTML/EN/plugins/AudioCD, pa ga LMS servira sam: sa sufiksom velicine
# (cd-generic_WxH[_m].png, kako ga trazi Material) zahtev hvata LMS-ov resizer (Slim::Web::Graphics) i daje
# sliku iz putanje skina/plugina, a bez sufiksa ide kao staticki fajl. Ova ruta je samo rezerva.
use constant GENERIC_RE  => qr{^plugins/AudioCD/cd-generic@{[ SIZE_SUFFIX ]}\.png\z};

my $DIR = File::Basename::dirname(__FILE__);
my $GENERIC = File::Spec->catfile($DIR, 'HTML', 'EN', 'plugins', 'AudioCD', 'cd-generic.png');

my $METACACHE;

# URL omota (relativan, kako ga trazi Material); ProtocolHandler/State dodaju vodecu kosu crtu
sub cover_url { return Plugins::AudioCD::Url::cover_url(@_) }

# plugins/AudioCD/cover/[cd.]<discid>[_WxH[_x]].jpg -> discid | undef
sub cover_discid {
	my ($path) = @_;
	return undef unless defined $path;
	$path =~ s{^/+}{};
	return undef unless $path =~ COVER_RE;
	my $id = $1;
	return Plugins::AudioCD::Cache::valid_discid($id) ? $id : undef;
}

# Putanja -> (fajl, content type). Nema omota (ili losa putanja) -> genericki CD.
# $cover_path: sub($discid) -> putanja jpg-a u MetaCache-u.
sub cover_file {
	my ($path, $cover_path) = @_;
	my $id = cover_discid($path);
	if (defined $id && $cover_path) {
		my $f = eval { $cover_path->($id) };
		return ($f, 'image/jpeg') if defined $f && -f $f;
	}
	return ($GENERIC, 'image/png');
}

# Tokeni PLUGIN_AUDIOCD_* iz strings.txt (redosled fajla).
sub ui_tokens {
	my ($file) = @_;
	$file //= File::Spec->catfile($DIR, 'strings.txt');
	open my $fh, '<:encoding(UTF-8)', $file or return ();
	my @t;
	while (my $l = <$fh>) {
		push @t, $1 if $l =~ /^(PLUGIN_AUDIOCD(?:_\w+)?)\s*$/;
	}
	close $fh;
	return @t;
}

# JSON bezbedan za <script type="application/json">: samo ASCII, bez '<', '>' i '&'.
sub html_json {
	my ($data) = @_;
	my $j = JSON::PP->new->ascii->canonical->encode($data);
	$j =~ s/</\\u003c/g;
	$j =~ s/>/\\u003e/g;
	$j =~ s/&/\\u0026/g;
	return $j;
}

# Nazivi tokena bez prefiksa (UI_PLAY, ERR_NO_DISC, TITLE za naziv plugina, ...) -> tekst; $string: sub($token) -> tekst.
sub ui_strings {
	my ($string, @tokens) = @_;
	my %s;
	for my $tok (@tokens) {
		(my $key = $tok) =~ s/^PLUGIN_AUDIOCD_?//;
		$key = 'TITLE' if $key eq '';
		next if $key ne 'TITLE' && $key !~ /^(?:UI|ERR)_/;    # SET_* su samo za podesavanja
		$s{$key} = $string->($tok);
	}
	return \%s;
}

# Kes-busting za JS/CSS: LMS salje staticke fajlove sa max-age od nedelju dana.
sub _stamp {
	my $m = 0;
	for my $f (qw(audiocd.js audiocd.css folderpick.js)) {
		my $t = (stat File::Spec->catfile($DIR, 'HTML', 'EN', 'plugins', 'AudioCD', $f))[9];
		$m = $t if $t && $t > $m;
	}
	return $m;
}

sub init {
	my ($class, %a) = @_;
	$METACACHE = $a{metacache};

	require Slim::Utils::Prefs;
	require Slim::Utils::Strings;
	require Slim::Web::HTTP;
	require Slim::Web::Pages;
	require Plugins::AudioCD::Config;

	my $prefs = Slim::Utils::Prefs::preferences('plugin.audiocd');

	Slim::Web::Pages->addPageFunction(PAGE, sub {
		my ($client, $params) = @_;
		my $strings = ui_strings(sub { Slim::Utils::Strings::string($_[0]) }, ui_tokens());
		$params->{audiocdData} = html_json({
			strings => $strings,
			config  => {
				ripsDir       => Plugins::AudioCD::Config::rips_dir($prefs->get('ripsDir')),
				profile       => $prefs->get('profile') // 'balanced',
				ejectAfterRip => $prefs->get('ejectAfterRip') ? 1 : 0,
				libraryDir    => $prefs->get('libraryDir') // '',
			},
		});
		$params->{audiocdStamp} = _stamp();
		($params->{audiocdLang} = lc(Slim::Utils::Strings::getLanguage() // 'en')) =~ tr/_/-/;    # en_gb -> en-gb (BCP 47)
		return Slim::Web::HTTP::filltemplatefile(PAGE, $params);
	});

	# Omot: regex nad putanjom bez vodece kose crte; fajl i content type se biraju iz iste provere
	my $cover_path = sub { $METACACHE ? $METACACHE->cover_path($_[0]) : undef };
	Slim::Web::Pages->addRawDownload(COVER_RE, sub { (cover_file($_[0], $cover_path))[0] },
		sub { (cover_file($_[0], $cover_path))[1] });

	# Rezerva za genericki CD (vidi GENERIC_RE); obicno ga servira sam LMS (resizer ili staticki fajl)
	Slim::Web::Pages->addRawDownload(GENERIC_RE, sub { $GENERIC }, 'image/png');

	Slim::Web::Pages->addPageLinks('plugins', { PLUGIN_AUDIOCD => PAGE });
	return;
}

1;
