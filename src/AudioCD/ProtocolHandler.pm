package Plugins::AudioCD::ProtocolHandler;

# audiocd://<discid>/<n>: pesma sa CD-a koja se pusta iz kesa u RAM-u (<cache_dir>/<discid>/NN.flac).
#
# Nalaz iz LMS 9.1.1 izvora (Slim/Player/Protocols/File.pm, Volatile.pm, ProtocolHandlers.pm,
# Song.pm, TranscodingHelper.pm, Schema.pm, Schema/RemoteTrack.pm, Music/Info.pm):
# - Svaka registrovana sema osim file/db je "remote" (ProtocolHandlers::isValidRemoteHandler),
#   pa je pesma Slim::Schema::RemoteTrack (bez baze). Isti model koristi ugradjeni
#   Slim::Player::Protocols::Volatile (tmp://): nasledjuje File, isRemote 1, pathFromFileURL
#   preslikava URL na lokalni fajl, atributi (SIZE, OFFSET, SECS, RATE, SAMPLESIZE, CHANNELS)
#   se upisuju u RemoteTrack iz Slim::Formats->readTags($path).
# - File::open cita velicinu, trajanje i ofset iz RemoteTrack-a i otvara $class->pathFromFileURL($url);
#   premotavanje radi preko FLAC findFrameBoundaries (File::canSeek -> Formats::FLAC::canSeek).
# - Tip: RemoteTrack->content_type; za novu pesmu Info::typeFromPath pita getFormatForURL -> 'flc'.
# - Song::open bira stream mod ['I', 'R'|'F']: 'I' je prvi, pa handler->new otvara fajl, a
#   pravilo flc->flc je '-' (squeezelite dobija originalni FLAC, bit-perfect); transkodovanje
#   (npr. UPnPBridge flc->pcm) cita iz istog handle-a preko stdin.
# - NE nasledjujemo Volatile: za Volatile Song::canDoSeek moze da izabere transkoder koji
#   seek-uje iz fajla ('F' + $track->path), a RemoteTrack->path preslikava samo tmp://, pa bi
#   dobio "audiocd://..." umesto putanje. Kao obican remote handler canSeek je 1: seek je
#   bajt-ofset u fajlu, isto kao za lokalni FLAC.
# - Song::getNextSong poziva handler->getNextTrack($song, $ok, $fail) pre open-a: tu cekamo
#   (tajmer) da pesma bude izvucena i tada popunjavamo RemoteTrack iz fajla.
# - canDirectStream 0 (File): LMS sam servira fajl plejeru.
#
# Plugin (Task 12) registruje handler i daje mu kes:
#   Slim::Player::ProtocolHandlers->registerHandler(audiocd => 'Plugins::AudioCD::ProtocolHandler');
#   Plugins::AudioCD::ProtocolHandler->set_cache($cache);
# Metapodaci: Plugins::AudioCD::Plugin::disc_info($discid) -> $disc|undef.
# Pokretanje kesa za pesmu dodatu mimo Play-a: Plugins::AudioCD::Plugin::ensure_cached($discid, $n).

use strict;
use warnings;
use utf8;

use base qw(Slim::Player::Protocols::File);

use Time::HiRes ();

use Slim::Formats;
use Slim::Music::Info;
use Slim::Schema::RemoteTrack;
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Player::Song;

use Plugins::AudioCD::Cache;
use Plugins::AudioCD::Url;

use constant WAIT_STEP => 0.5;    # sekundi izmedju provera da li je pesma izvucena

my $log = logger('plugin.audiocd');
my $CACHE;

sub set_cache { $CACHE = $_[1]; return }

sub url_for { my ($class, $discid, $n) = @_; return "audiocd://$discid/$n" }

# parse_url($url) -> ($discid, $n) | ()
sub parse_url {
	my ($class, $url) = @_;
	return () unless defined $url && $url =~ m{^audiocd://([^/]+)/(\d+)\z};
	my ($discid, $n) = ($1, $2 + 0);
	return () unless Plugins::AudioCD::Cache::valid_discid($discid);
	return ($discid, $n);
}

sub _disc_info {
	my ($discid) = @_;
	my $f = Plugins::AudioCD::Plugin->can('disc_info') or return undef;
	return eval { $f->($discid) };
}

sub _track_meta {
	my ($discid, $n) = @_;
	my $disc = _disc_info($discid);
	return undef unless ref $disc eq 'HASH';
	my ($t) = grep { ref $_ eq 'HASH' && defined $_->{n} && $_->{n} == $n } @{ $disc->{tracks} || [] };
	return { disc => $disc, track => $t || {} };
}

sub cover_url { my ($class, $discid) = @_; return "/" . Plugins::AudioCD::Url::cover_url($discid) }

# ---------- LMS handler API ----------

sub isRemote        { 1 }
sub canDirectStream { 0 }
sub getFormatForURL { 'flc' }

sub pathFromFileURL {
	my ($class, $url) = @_;
	my ($discid, $n) = $class->parse_url($url);
	my $p = $CACHE && defined $n ? $CACHE->path($discid, $n) : undef;
	return defined $p ? $p : '';
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my ($discid, $n) = $class->parse_url($url);
	return {} unless defined $n;
	my $m = _track_meta($discid, $n) or return { type => 'FLAC', tracknum => $n };
	my ($d, $t) = ($m->{disc}, $m->{track});
	my $cover = $class->cover_url($discid);
	return {
		title    => $t->{title},
		artist   => Plugins::AudioCD::Cache::track_artist($t, $d),
		album    => $d->{album},
		tracknum => $n,
		duration => $t->{length},
		cover    => $cover,
		icon     => $cover,
		type     => 'FLAC',
	};
}

sub getIcon {
	my ($class, $url) = @_;
	my ($discid) = $class->parse_url($url);
	return defined $discid ? $class->cover_url($discid) : 'html/images/cover.png';
}

# Popunjava RemoteTrack iz keširanog fajla (velicina, trajanje, format) i iz metapodataka diska.
sub _fill_track {
	my ($class, $track, $path, $discid, $n) = @_;
	my $attr = Slim::Formats->readTags($path) || {};
	my $m = _track_meta($discid, $n);
	if ($m) {
		my ($d, $t) = ($m->{disc}, $m->{track});
		$attr->{TITLE}    = $t->{title} if defined $t->{title};
		my $artist = Plugins::AudioCD::Cache::track_artist($t, $d);
		$attr->{ARTIST}   = $artist if defined $artist;
		$attr->{ALBUM}    = $d->{album} if defined $d->{album};
		$attr->{TRACKNUM} = $n;
	}
	$attr->{CT} = 'flc';
	Slim::Schema::RemoteTrack->updateOrCreate($track, $attr);
	return;
}

# Da li LMS jos ceka bas ovu pesmu: status READY i prva je u redu StreamingController-a
# (_getNextTrack je stavlja na pocetak songqueue pre getNextSong; preskakanje stavlja novu ispred).
sub _song_active {
	my ($song) = @_;
	my $ok = eval {
		return 0 unless $song->status == Slim::Player::Song::STATUS_READY();
		my $owner = $song->owner;
		return 1 unless $owner && $owner->can('streamingSong');
		my $s = $owner->streamingSong;
		return defined $s && $s == $song ? 1 : 0;
	};
	return $ok // 1;
}

# Ceka da pesma bude izvucena, pa pusta; pesma ide na pocetak reda kesa. Odluku donosi
# Cache::Waiter (jedan cekac po plejeru, rok 120 s, produzava se dok .part raste, najvise 600 s).
sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $track = $song->currentTrack;
	my $url   = $track->url;
	my ($discid, $n) = $class->parse_url($url);

	my $fail = sub {
		my ($why) = @_;
		$log->warn("$url: $why");
		$errorCb->('PLUGIN_AUDIOCD_TRACK_NOT_READY', $url);
	};
	return $fail->('neispravan URL') unless defined $n;
	return $fail->('kes nije podesen') unless $CACHE;

	my $key = eval { $song->master->id } // '';
	# Pesma dodata mimo audiocd play (lista posle restarta, Add / Play next, ponovo ubacen disk):
	# Waiter preko ensure pokrece kes ako je taj disk u drajvu, a za drugi disk odmah javlja gresku.
	my $ensure = Plugins::AudioCD::Plugin->can('ensure_cached');
	my $w = $CACHE->waiter(key => $key, discid => $discid, n => $n, $ensure ? (ensure => $ensure) : ());
	my $check;
	$check = sub {
		my ($what, $arg) = $w->poll(_song_active($song));
		if ($what eq 'wait') {
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + WAIT_STEP, $check);
			return;
		}
		undef $check;
		if ($what eq 'ready') {
			eval { $class->_fill_track($track, $arg, $discid, $n); 1 }
				or $log->warn("$url: citanje tagova: $@");
			return $successCb->();
		}
		return $fail->($arg) if $what eq 'fail';
		main::INFOLOG && $log->is_info && $log->info("$url: cekanje prekinuto (preskocena pesma)");
		return;
	};
	$check->();
	return;
}

1;
