package Plugins::AudioCD::State;

# Stanje diska u drajvu i pravila za poslove (Play keš, rip). Cist Perl, bez Slim zavisnosti:
# sve sto dira LMS, drajv ili mrezu se ubacuje (Plugin.pm vezuje na LMS, testovi na lazne objekte).
#
# Zavisnosti (new):
#   pref        => sub($kljuc) -> vrednost iz plugin.audiocd prefs-a        (obavezno)
#   read_toc    => sub($dev) -> ($toc, $err)                               (obavezno)
#   lookup      => objekat sa ->lookup($toc, $cb, offline => 0|1)          (obavezno)
#   metacache   => Plugins::AudioCD::MetaCache                             (obavezno)
#   cache       => Plugins::AudioCD::Cache                                 (obavezno)
#   ripper      => Plugins::AudioCD::Ripper                                (obavezno)
#   rips_dir    => sub -> podrazumevani folder za rip-ove
#   media_dirs  => sub -> [LMS muzicki folderi] (karakteri); rip dir iz zahteva samo ispod njih ili rips_dir
#   fetch_cover => sub(\@urls, $dest_path, $cb->($ok))
#   play        => sub($client_id, \@urls, $start_index) -> ($ok, $err)
#   eject       => sub($was_busy, $done)    $done->() kad CDROMEJECT zavrsi ili odustane
#   missing_tools => sub -> imena alata koji nedostaju
#   notify      => sub($history_entry)       kraj ripa (kad je pref notify)
#   kill_all    => sub                        gasenje: ubija sve procese
#   drive_status => sub($dev) -> ($code, $err)  provera za eject_event (ioctl)
#   lookup_busy => sub -> 0|1                 radi li cd-info (Lookup), koji drzi drajv
#   kill_lookup => sub                        ubija cd-info (asinhrono)
#   drive_procs => sub -> broj                zivih procesa na drajvu (i onih koji jos umiru)
#   on_change   => sub                        stanje promenjeno
#   log         => sub($nivo, $poruka)
#
# Pravila: drajv radi jednu stvar (cache, rip ili cd-info iz Lookup-a); dok je zauzet nema ioctl-a
# (load, eject_event), jer bi ioctl na drajvu koji cita drugi proces blokirao LMS;
# Play tokom ripa samo ako je disk ceo u kesu;
# drugi Play istog diska koristi isti kes; izbacivanje prekida sve poslove i brise stanje diska,
# ali kes ostaje: gotove pesme se i dalje sviraju, a kes se brise tek kad se ubaci DRUGI disk
# (ili pri gasenju); isti disk ponovo ubacen nastavlja izvlacenje pesama koje fale;
# zakasneli odgovori (lookup, omot) starog diska se ignorisu (brojac generacija).

use strict;
use warnings;
use utf8;

use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Library;
use Plugins::AudioCD::Metadata::Lookup;
use Plugins::AudioCD::Metadata::MusicBrainz;
use Plugins::AudioCD::Profiles;
use Plugins::AudioCD::Ripper;
use Plugins::AudioCD::Tools;

use constant CDS_DISC_OK => 4;

my @REQUIRED = qw(pref read_toc lookup metacache cache ripper);
my %NOOP = (
	rips_dir      => sub { undef },
	media_dirs    => sub { [] },
	fetch_cover   => sub { },
	play          => sub { (undef, { error => 'no_player' }) },
	eject         => sub { },
	missing_tools => sub { () },
	notify        => sub { },
	kill_all      => sub { },
	drive_status  => sub { (undef, 'io') },
	lookup_busy   => sub { 0 },
	kill_lookup   => sub { },
	drive_procs   => sub { 0 },
	on_change     => sub { },
	log           => sub { },
);

sub new {
	my ($class, %d) = @_;
	for (@REQUIRED) { die "State: $_ je obavezan\n" unless $d{$_} }
	$d{$_} ||= $NOOP{$_} for keys %NOOP;
	my $self = bless { d => \%d, gen => 0, last_drive => undef, stopped => 0, rip_dirs => {} }, $class;
	$self->_reset('empty');
	my $h = $d{ripper}->history;
	$self->{seen_rip} = @$h ? $h->[0]{id} : undef;    # stara istorija se ne javlja
	return $self;
}

# ---------- pomocne ----------

sub _pref   { my ($self, $k) = @_; return $self->{d}{pref}->($k) }
sub _device { my ($self) = @_; my $d = $self->_pref('device'); return defined $d && length $d ? $d : '/dev/cdrom' }
sub _log    { my ($self, $lvl, $msg) = @_; eval { $self->{d}{log}->($lvl, $msg); 1 }; return }
sub _err    { my ($code, %x) = @_; return (undef, { error => $code, %x }) }

sub _changed {
	my ($self) = @_;
	eval { $self->{d}{on_change}->(); 1 } or $self->_log(warn => "on_change: $@");
	return;
}

sub _reset {
	my ($self, $status, @errors) = @_;
	$self->{status}      = $status;
	$self->{toc}         = undef;
	$self->{discid}      = undef;
	$self->{cddbid}      = undef;
	$self->{candidates}  = [];
	$self->{release_idx} = 0;
	$self->{fuzzy}       = 0;
	$self->{disc}        = undef;
	$self->{cover_urls}  = [];
	$self->{errors}      = [@errors];
	return;
}

sub status { return $_[0]{status} }

sub _ready { my ($self) = @_; return $self->{status} eq 'ready' && $self->{disc} && $self->{toc} ? 1 : 0 }

sub _audio { my ($self) = @_; return map { $_->{n} } Plugins::AudioCD::DiscId::audio_tracks($self->{toc}) }

sub _missing {
	my ($self, @want) = @_;
	my %m = map { $_ => 1 } $self->{d}{missing_tools}->();
	return grep { $m{$_} } @want;
}

sub _cover_file {
	my ($self) = @_;
	return undef unless defined $self->{discid};
	my $p = eval { $self->{d}{metacache}->cover_path($self->{discid}) };
	return defined $p && -f $p ? $p : undef;
}

sub _cache_complete {
	my ($self) = @_;
	my $c = $self->{d}{cache};
	my $id = $c->discid;
	return 0 unless defined $id && defined $self->{discid} && $id eq $self->{discid} && $self->{toc};
	for my $n ($self->_audio) { return 0 unless $c->ready($n) }
	return 1;
}

# 'rip' | 'cache' | 'lookup' (cd-info) | 'process' (proces na drajvu jos umire) | 'none'
sub drive_busy {
	my ($self) = @_;
	return 'rip'    if $self->{d}{ripper}->busy;
	return 'cache'  if $self->{d}{cache}->busy;
	return 'lookup' if $self->{d}{lookup_busy}->();
	return 'process' if $self->{d}{drive_procs}->() > 0;
	return 'none';
}

sub _kill_lookup {
	my ($self) = @_;
	return unless $self->{d}{lookup_busy}->();
	eval { $self->{d}{kill_lookup}->(); 1 } or $self->_log(warn => "cd-info: $@");
	return;
}

# Prekida poslove na disku koji vise nije u drajvu. Kes: izvlacenje staje, a gotove pesme ostaju
# (disk izbacen); clear_cache => 1 samo kad je u drajvu drugi disk (ili disk bez audio pesama).
sub _drop_disc {
	my ($self, %o) = @_;
	$self->_kill_lookup;
	delete $self->{pending_autorip};
	my $c = $self->{d}{cache};
	eval { $c->stop; $c->clear if $o{clear_cache}; 1 } or $self->_log(warn => "kes: $@");
	my $r = $self->{d}{ripper};
	if ($r->busy) { eval { $r->abort_all('ejected'); 1 } or $self->_log(warn => "rip: $@") }
	return;
}

# ---------- disk ----------

# on_load(offline => 0|1, force => 0|1) -> ($ok, $err)
sub on_load {
	my ($self, %o) = @_;
	return _err('stopped') if $self->{stopped};
	return _err('eject_pending') if $self->{eject_pending};
	# zauzet drajv: bez read_toc ioctl-a (blokirao bi LMS); disk se proverava kad posao zavrsi
	return _err('drive_busy', busy => $self->drive_busy) if $self->drive_busy ne 'none';
	my ($toc, $err) = eval { $self->{d}{read_toc}->($self->_device) };
	$err = 'io' if !$toc && !defined $err;

	if (!$toc) {
		$self->_drop_disc if defined $self->{discid};
		$self->{gen}++;
		$self->_reset($err eq 'no_disc' ? 'empty' : 'error', { code => $err });
		$self->_changed;
		return _err($err);
	}
	my @audio = Plugins::AudioCD::DiscId::audio_tracks($toc);
	if (!@audio) {
		$self->_drop_disc(clear_cache => 1);    # drugi (neaudio) disk: kes izbacenog diska vise ne treba
		$self->{gen}++;
		$self->_reset('empty', { code => 'no_audio' });
		$self->_changed;
		return _err('no_audio');
	}

	my $id = Plugins::AudioCD::DiscId::musicbrainz_id($toc);
	my $same = defined $self->{discid} && $self->{discid} eq $id;
	return (1, undef) if $same && !$o{force} && !$o{offline} && $self->{status} =~ /^(?:reading|ready)\z/;

	$self->_drop_disc(clear_cache => 1) if defined $self->{discid} && !$same;    # zamenjen disk
	# kes izbacenog diska (State je prazan) se brise tek kad je u drajvu drugi disk
	my $cid = $self->{d}{cache}->discid;
	if (defined $cid && $cid ne $id) {
		eval { $self->{d}{cache}->clear; 1 } or $self->_log(warn => "kes: $@");
	}
	my $gen = ++$self->{gen};
	$self->_reset('reading');
	$self->{toc}    = $toc;
	$self->{discid} = $id;
	$self->{cddbid} = Plugins::AudioCD::DiscId::cddb_id($toc);

	unless ($o{offline} || $o{force}) {
		my $cached = eval { $self->{d}{metacache}->get($id) };
		if (ref $cached eq 'HASH' && ref $cached->{disc} eq 'HASH') {
			$self->_apply($cached);
			return (1, undef);
		}
	}
	$self->_changed;

	my $offline = $o{offline} ? 1 : 0;
	my $ok = eval {
		$self->{d}{lookup}->lookup($toc, sub {
			my ($res) = @_;
			return if $self->{stopped} || $gen != $self->{gen};
			$self->on_lookup_done($res, offline => $offline);
		}, $offline ? (offline => 1) : ());
		1;
	};
	unless ($ok) {
		$self->_log(warn => "lookup: $@");
		my $disc = Plugins::AudioCD::Metadata::Lookup::generic_disc($toc);
		$disc->{discid} = $id;
		$disc->{cddbid} = $self->{cddbid};
		$self->on_lookup_done({ discid => $id, cddbid => $self->{cddbid}, candidates => [], selected => 0, disc => $disc, cover_urls => [] }, offline => 1);
	}
	return (1, undef);
}

# Rezultat Lookup-a (ili kesa). Genericki i offline rezultati se ne kesiraju; rucna izmena pobedjuje.
sub on_lookup_done {
	my ($self, $res, %o) = @_;
	return if $self->{stopped};
	return unless ref $res eq 'HASH' && ref $res->{disc} eq 'HASH' && defined $self->{discid};
	return if defined $res->{discid} && $res->{discid} ne $self->{discid};

	unless ($o{offline}) {
		my $mc = $self->{d}{metacache};
		if (($res->{disc}{source} // '') ne 'generic') {
			eval { $mc->put($self->{discid}, $res); 1 } or $self->_log(warn => "MetaCache: $@");
		}
		my $merged = eval { $mc->get($self->{discid}) };
		$res = $merged if ref $merged eq 'HASH' && ref $merged->{disc} eq 'HASH';
	}
	$self->_kill_lookup;    # rezultat stigao: cd-info vise ne treba (pusta drajv)
	$self->_apply($res);
	return;
}

sub _apply {
	my ($self, $res) = @_;
	my $c = ref $res->{candidates} eq 'ARRAY' ? $res->{candidates} : [];
	my $sel = $res->{selected} // 0;
	$sel = 0 unless $sel =~ /^\d+\z/ && ($sel < @$c || !@$c);
	$self->{candidates}  = $c;
	$self->{release_idx} = $sel + 0;
	$self->{fuzzy}       = $res->{fuzzy} ? 1 : 0;
	$self->{disc}        = $res->{disc};
	$self->{cover_urls}  = ref $res->{cover_urls} eq 'ARRAY' ? $res->{cover_urls} : [];
	$self->{status}      = 'ready';
	$self->{errors}      = [];
	$self->_fetch_cover;
	$self->_changed;
	$self->_auto_rip;
	$self->_resume_cache;
	return;
}

# Isti disk ponovo ubacen posle izbacivanja: nastavlja izvlacenje pesama koje fale (gotove se ne diraju).
# Ne radi ako je drajv zauzet (npr. autoRip je upravo poceo) ili je kes kompletan.
sub _resume_cache {
	my ($self) = @_;
	return if $self->{stopped} || $self->{eject_pending} || !$self->_ready;
	my $c = $self->{d}{cache};
	return unless $c->can('resumable') && $c->resumable($self->{discid});
	return if $self->drive_busy ne 'none';
	my ($first) = grep { !$c->ready($_) } $self->_audio;
	return unless defined $first;
	my ($ok, $err) = $self->_start_cache($first);
	$self->_log(warn => 'nastavak kesa nije pokrenut: ' . ($err->{error} // '?')) unless $ok;
	return;
}

sub _fetch_cover {
	my ($self) = @_;
	return if $self->_cover_file || !@{ $self->{cover_urls} };
	my $dest = eval { $self->{d}{metacache}->cover_path($self->{discid}) } or return;
	my $gen = $self->{gen};
	eval {
		$self->{d}{fetch_cover}->([ @{ $self->{cover_urls} } ], $dest, sub {
			return if $self->{stopped} || $gen != $self->{gen};
			$self->_changed;
		});
		1;
	} or $self->_log(warn => "omot: $@");
	return;
}

sub _auto_rip {
	my ($self) = @_;
	return if $self->{eject_pending};
	return unless $self->_pref('autoRip');
	my $id = $self->{discid};
	# Isti disk posle restarta ili ponovnog ubacivanja se ne ripuje ponovo.
	return if grep { defined $_->{discid} && $_->{discid} eq $id && ($_->{result} // '') =~ /^(?:ok|accurip_mismatch)\z/ }
		@{ $self->{d}{ripper}->history };
	if ($self->{d}{lookup_busy}->()) {    # cd-info jos pusta drajv: rip kad zavrsi (on_lookup_idle)
		$self->{pending_autorip} = $id;
		return;
	}
	delete $self->{pending_autorip};
	my ($ok, $err) = $self->request_rip(profile => $self->_pref('autoRipProfile'));
	$self->_log(warn => "automatski rip nije pokrenut: $err->{error}") unless $ok;
	return;
}

# Plugin javlja da je cd-info zavrsio: odlozeni automatski rip.
sub on_lookup_idle {
	my ($self) = @_;
	my $id = delete $self->{pending_autorip};
	return if $self->{stopped} || !defined $id || !defined $self->{discid} || $id ne $self->{discid} || !$self->_ready;
	$self->_auto_rip;
	return;
}

sub on_eject {
	my ($self) = @_;
	$self->_drop_disc;
	$self->{gen}++;
	$self->{last_drive} = 0;    # sledeci DISC_OK ponovo cita disk
	delete $self->{recheck};
	$self->_reset('empty');
	$self->_changed;
	return (1, undef);
}

# Komanda Eject: prekida poslove, pa izbacuje disk.
sub eject {
	my ($self) = @_;
	my $was_busy = $self->drive_busy ne 'none' ? 1 : 0;
	$self->on_eject;
	# Dok odlozeni CDROMEJECT ne zavrsi, disk se ne vraca u stanje (polling, load, autoRip miruju).
	my $token = ++$self->{eject_seq};
	$self->{eject_pending} = $token;
	my $done = sub {
		delete $self->{eject_pending} if ($self->{eject_pending} // 0) == $token;
		return;
	};
	eval { $self->{d}{eject}->($was_busy, $done); 1 } or do {
		my $e = $@;
		$done->();
		return _err('eject', message => "$e");
	};
	return (1, undef);
}

# Kraj ili promena posla (Cache, Ripper, cd-info): odlozena provera eject_event-a radi i bez polling-a.
sub on_jobs_changed {
	my ($self) = @_;
	return unless $self->{recheck};
	return if $self->{stopped} || $self->{eject_pending} || $self->drive_busy ne 'none';
	my ($code, $err) = eval { $self->{d}{drive_status}->($self->_device) };
	$self->on_drive_status($code, $err);
	return;
}

# Polling: status drajva (CDS_*) ili greska. Ne radi nista dok traje posao.
sub on_drive_status {
	my ($self, $code, $err) = @_;
	return if $self->{stopped} || $self->{eject_pending} || $self->drive_busy ne 'none';
	my $ok   = defined $code && $code == CDS_DISC_OK ? 1 : 0;
	my $prev = $self->{last_drive};
	$self->{last_drive} = $ok;
	if (delete $self->{recheck}) {    # odlozen eject_event: posao je zavrsen, sada se proverava
		return $self->on_load if $ok;
		return $self->on_eject if defined $self->{discid};
	}
	if ($ok) {
		$self->on_load if !$prev && $self->_pref('autoLoad');
		return;
	}
	if (defined $err && $err eq 'permission') {
		return if $self->{status} eq 'error';
		$self->_drop_disc if defined $self->{discid};
		$self->{gen}++;
		$self->_reset('error', { code => 'permission' });
		$self->_changed;
		return;
	}
	$self->on_eject if defined $self->{discid};
	return;
}

# udev: disk izvadjen. Bez posla se proverava drajv (ioctl); tokom posla nema ioctl-a: rip sa
# eject_after (cyanrip -Q sam otvara fioku) se ne prekida, a inace se provera odlaze do kraja posla
# (disk izvadjen usred posla obara cd-paranoia/cyanrip, pa posao ionako zavrsava).
sub on_eject_event {
	my ($self) = @_;
	return _err('stopped') if $self->{stopped};
	my $busy = $self->drive_busy;
	if ($busy ne 'none') {
		my $cur = $busy eq 'rip' ? $self->{d}{ripper}->status->{current} : undef;
		if ($cur && $cur->{eject_after}) {
			$self->{last_drive} = 1;    # posle ripa polling vidi otvorenu fioku
			return (1, undef, 'eject_after');
		}
		$self->{recheck} = 1;
		return (1, undef, 'deferred');
	}
	my ($code) = eval { $self->{d}{drive_status}->($self->_device) };
	return (1, undef, 'ignored') if defined $code && $code == CDS_DISC_OK;
	$self->on_eject;
	return (1, undef, 'ejected');
}

# ---------- metapodaci ----------

sub select_release {
	my ($self, $i) = @_;
	return _err('no_disc') unless $self->_ready;
	my $c = $self->{candidates};
	return _err('bad_index') unless defined $i && $i =~ /^\d+\z/ && $i < @$c;
	my $cand = $c->[$i];
	$self->{release_idx} = $i + 0;
	$self->{disc} = $cand->{disc};
	my @urls = ($cand->{disc}{source} // '') eq 'musicbrainz' ? Plugins::AudioCD::Metadata::MusicBrainz::cover_urls($cand) : ();
	if (@urls) {
		my $old = $self->_cover_file;
		unlink $old if defined $old;
		$self->{cover_urls} = \@urls;
	}
	eval {
		$self->{d}{metacache}->put($self->{discid}, {
			discid => $self->{discid}, cddbid => $self->{cddbid}, candidates => $c, selected => $i + 0,
			fuzzy => $self->{fuzzy}, disc => $cand->{disc}, cover_urls => $self->{cover_urls},
		});
		$self->{d}{metacache}->delete_manual($self->{discid});    # izbor izdanja je noviji od rucne izmene
		1;
	} or $self->_log(warn => "MetaCache: $@");
	$self->_fetch_cover;
	$self->_changed;
	return (1, undef);
}

# edit({ artist, album, year, tracks => [ { n, title, artist } ] }): rucna izmena, cuva se u MetaCache.
sub edit {
	my ($self, $in) = @_;
	return _err('no_disc') unless $self->_ready;
	return _err('bad_args') unless ref $in eq 'HASH';
	my $old = $self->{disc};
	my %new = %$old;
	$new{tracks} = [ map { {%$_} } @{ $old->{tracks} || [] } ];
	for my $k (qw(artist album year)) {
		next unless exists $in->{$k};
		return _err('bad_args', field => $k) if ref $in->{$k};
		$new{$k} = $in->{$k};
	}
	if (exists $in->{tracks}) {
		return _err('bad_args', field => 'tracks') unless ref $in->{tracks} eq 'ARRAY';
		for my $t (@{ $in->{tracks} }) {
			next unless ref $t eq 'HASH' && defined $t->{n} && !ref $t->{n} && $t->{n} =~ /^\d+\z/;
			my ($dst) = grep { $_->{n} == $t->{n} } @{ $new{tracks} };
			next unless $dst;
			for my $k (qw(title artist)) {
				$dst->{$k} = $t->{$k} if defined $t->{$k} && !ref $t->{$k};
			}
		}
	}
	$new{source} = 'manual';
	$new{discid} = $self->{discid};
	eval { $self->{d}{metacache}->put_manual($self->{discid}, \%new); 1 } or return _err('save_failed', message => "$@");
	$self->{disc} = \%new;
	$self->_changed;
	return (1, undef);
}

sub disc_info {
	my ($self, $id) = @_;
	return undef unless defined $id;
	return $self->{disc} if defined $self->{discid} && $self->{discid} eq $id && $self->{disc};
	my $r = eval { $self->{d}{metacache}->get($id) };
	return ref $r eq 'HASH' && ref $r->{disc} eq 'HASH' ? $r->{disc} : undef;
}

# ---------- poslovi ----------

# cd-info jos drzi drajv: ubij ga i odbij zahtev (drajv nikad ne citaju dva procesa); ponovi za trenutak.
sub _lookup_busy_err {
	my ($self) = @_;
	$self->_kill_lookup;
	return _err('drive_busy', busy => 'lookup');
}

# Pokrece kes od pesme $n (disk je ready, pesma postoji). Pravila zauzetog drajva su ista za Play
# i za audiocd:// pesmu koja se pusta bez Play-a: rip ili proces koji jos umire -> drive_busy,
# cd-info se ubija pa drive_busy (ponovi za trenutak); isti disk nastavlja postojeci kes.
sub _start_cache {
	my ($self, $n) = @_;
	return (1, undef) if $self->_cache_complete;
	my $busy = $self->drive_busy;
	return _err('drive_busy', busy => $busy) if $busy eq 'rip' || $busy eq 'process';
	return $self->_lookup_busy_err if $busy eq 'lookup';
	my @miss = $self->_missing('cd-paranoia', 'flac');
	return _err('missing_tools', tools => \@miss) if @miss;
	my $c = $self->{d}{cache};
	unless ($c->start($self->{disc}, $self->{toc}, $n + 0)) {
		my $e = $c->can('last_error') ? $c->last_error : undef;    # npr. { error => 'cache_no_space', needed }
		return (undef, { %$e }) if ref $e eq 'HASH' && defined $e->{error};
		return _err('cache_failed');
	}
	return (1, undef);
}

sub request_play {
	my ($self, $client_id, $n) = @_;
	return _err('no_disc') unless $self->_ready;
	my @audio = $self->_audio;
	return _err('bad_track') unless defined $n && $n =~ /^\d+\z/ && grep { $_ == $n } @audio;

	my ($started, $serr) = $self->_start_cache($n);
	return (undef, $serr) unless $started;
	my ($idx) = grep { $audio[$_] == $n } 0 .. $#audio;
	my @urls = map { "audiocd://$self->{discid}/$_" } @audio;
	my ($ok, $err) = $self->{d}{play}->($client_id, \@urls, $idx);
	$self->_changed;
	return $ok ? (1, undef) : (undef, $err || { error => 'play_failed' });
}

# request_cache($discid, $n): audiocd:// pesma pustena mimo request_play (lista vracena posle
# restarta LMS-a, Add / Play next, ponovo ubacen disk) -> kes se pokrece, lista plejera se ne dira.
# Greske: wrong_disc (u drajvu nije taj disk: odmah fail), not_ready (disk se jos cita),
# bad_track, drive_busy (busy => rip|process|lookup), missing_tools, cache_no_space, cache_failed.
sub request_cache {
	my ($self, $discid, $n) = @_;
	return _err('stopped') if $self->{stopped};
	return _err('wrong_disc') unless defined $discid && defined $self->{discid} && $discid eq $self->{discid};
	return _err('not_ready') unless $self->_ready;
	return _err('bad_track') unless defined $n && $n =~ /^\d+\z/ && grep { $_ == $n } $self->_audio;
	my ($ok, $err) = $self->_start_cache($n);
	$self->_changed if $ok;
	return ($ok, $err);
}

# request_rip(profile, dir, eject) -> ($job_id, undef) | (undef, $err). FLAC nivo se ne prosledjuje (Ruling 15).
sub request_rip {
	my ($self, %a) = @_;
	return _err('no_disc') unless $self->_ready;
	return _err('drive_busy') if $self->drive_busy eq 'cache' && !$self->_cache_complete;
	return $self->_lookup_busy_err if $self->{d}{lookup_busy}->();
	my @miss = $self->_missing('cyanrip');
	return _err('missing_tools', tools => \@miss) if @miss;

	my $profile = defined $a{profile} && length $a{profile} ? $a{profile} : ($self->_pref('profile') // 'balanced');
	return _err('bad_args', field => 'profile') unless grep { $_ eq $profile } @Plugins::AudioCD::Profiles::NAMES;
	my $def = $self->{d}{rips_dir}->();
	my $dir = defined $a{dir} && length $a{dir} ? $a{dir} : $def;
	return _err('bad_args', field => 'dir') unless defined $dir && $dir =~ m{^/} && $dir !~ m{(?:^|/)\.\.(?:/|\z)};
	if (defined $a{dir} && length $a{dir}) {
		# folder iz zahteva: samo ispod foldera za rip-ove ili LMS muzickog foldera (pravilo iz Library)
		my $media = eval { $self->{d}{media_dirs}->() };
		my @roots = grep { defined && length } $def, @{ ref $media eq 'ARRAY' ? $media : [] };
		my ($clean, $lerr) = Plugins::AudioCD::Library::library_dir($dir, undef, \@roots);
		return _err($lerr eq 'bad_args' ? 'bad_args' : 'rip_dir_outside', field => 'dir') if $lerr;
		$dir = $clean;
	}
	my $eject = defined $a{eject} && length $a{eject} ? ($a{eject} ? 1 : 0) : ($self->_pref('ejectAfterRip') ? 1 : 0);
	my $offset = $self->_pref('driveOffset');
	$offset = undef unless defined $offset && length $offset;

	my ($id, $err) = $self->{d}{ripper}->enqueue(
		disc        => $self->{disc},
		toc         => $self->{toc},
		device      => $self->_device,
		profile     => $profile,
		rips_dir    => $dir,
		quiet_speed => $self->_pref('quietDrive') ? $self->_pref('quietSpeed') : undef,
		offset      => $offset,
		eject_after => $eject,
		cover_src   => $self->_cover_file,
	);
	return (undef, $err || { error => 'rip_failed' }) unless defined $id;
	$self->{rip_dirs}{$dir} = 1;
	$self->_changed;
	return ($id, undef);
}

# Ripper javlja promenu: novi zavrseni unosi istorije -> obavestenje (osim otkazanih).
sub on_rip_change {
	my ($self) = @_;
	my $h = $self->{d}{ripper}->history;
	my @new;
	for my $e (@$h) {
		last if defined $self->{seen_rip} && defined $e->{id} && $e->{id} eq $self->{seen_rip};
		push @new, $e;
	}
	$self->{seen_rip} = $h->[0]{id} if @$h;
	if (@new && $self->_pref('notify')) {
		for my $e (reverse @new) {
			next if ($e->{result} // '') eq 'cancelled';
			eval { $self->{d}{notify}->($e); 1 } or $self->_log(warn => "obavestenje: $@");
		}
	}
	$self->_changed;
	return;
}

# Gasenje plugina: ubij procese, obrisi kes i ostatke rip-ova; zakasneli callback-ovi nemaju efekta.
sub shutdown {
	my ($self) = @_;
	$self->{stopped} = 1;
	$self->{gen}++;
	$self->_kill_lookup;
	eval { $self->{d}{ripper}->shutdown('shutdown'); 1 } or $self->_log(warn => "rip shutdown: $@");
	eval { $self->{d}{kill_all}->(); 1 } or $self->_log(warn => "kill_all: $@");
	eval { $self->{d}{cache}->clear; 1 } or $self->_log(warn => "kes: $@");
	my %dirs = (%{ $self->{rip_dirs} });
	my $def = eval { $self->{d}{rips_dir}->() };
	$dirs{$def} = 1 if defined $def && length $def;
	Plugins::AudioCD::Ripper::cleanup_stale($_) for keys %dirs;
	return;
}

# ---------- snapshot ----------

sub snapshot {
	my ($self) = @_;
	my $cover = $self->_cover_file;
	my $i = 0;
	my @rel = map { my %c = %$_; delete $c{disc}; $c{index} = $i++; \%c } @{ $self->{candidates} };
	my $cs = $self->{d}{cache}->status;
	return {
		status        => $self->{status},
		device        => $self->_device,
		toc           => $self->{toc},
		discid        => $self->{discid},
		cddbid        => $self->{cddbid},
		releases      => \@rel,
		release_idx   => $self->{release_idx},
		fuzzy         => $self->{fuzzy},
		metadata      => $self->{disc},
		cover         => defined $cover ? 1 : 0,
		cover_url     => defined $cover ? "/plugins/AudioCD/cover/$self->{discid}.jpg" : undef,
		drive_busy    => $self->drive_busy,
		cache         => { %$cs, discid => $self->{d}{cache}->discid },
		rip           => $self->{d}{ripper}->status,
		errors        => [ @{ $self->{errors} } ],
		missing_tools => [ map { { tool => $_, package => $Plugins::AudioCD::Tools::PACKAGE{$_} // $_ } } $self->{d}{missing_tools}->() ],
	};
}

1;
