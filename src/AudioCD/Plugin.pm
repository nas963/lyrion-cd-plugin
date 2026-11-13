package Plugins::AudioCD::Plugin;

# Veza AudioCD jedinica sa Lyrion-om: prefs, CLI komande ['audiocd', ...], audiocd:// handler,
# Jobs backend na LMS event loop-u, polling drajva, HTTP za metapodatke i omot, obavestenja.
# Pravila stanja su u State.pm (cist Perl, testiran); ovde je samo LMS sloj.

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use EV ();
use Encode ();
use File::Path ();
use File::Spec::Functions qw(catdir);
use JSON::PP ();
use Time::HiRes ();

use Slim::Control::Request;
use Slim::Menu::BrowseLibrary;
use Slim::Networking::Select;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::Client;
use Slim::Player::ProtocolHandlers;
use Slim::Schema;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings ();
use Slim::Utils::Timers;

use Plugins::AudioCD::Cache;
use Plugins::AudioCD::Config;
use Plugins::AudioCD::Drive;
use Plugins::AudioCD::Jobs;
use Plugins::AudioCD::MaterialBridge;
use Plugins::AudioCD::MetaCache;
use Plugins::AudioCD::Metadata::Lookup;
use Plugins::AudioCD::Menu;
use Plugins::AudioCD::ProtocolHandler;
use Plugins::AudioCD::Ripper;
use Plugins::AudioCD::State;
use Plugins::AudioCD::Tools;

our $VERSION = '0.1.0';

use constant POLL_INTERVAL => 5;     # s, polling drajva (rezerva za udev)
use constant START_DELAY   => 3;     # s, prva provera drajva posle starta
use constant HTTP_TIMEOUT  => 15;
use constant EJECT_DELAY   => 1.5;   # s, posle prekida posla pa izbacivanje
use constant RUN_CMD_LIMIT => 10;    # s, cd-info se ubija posle ovoliko (= Lookup CDTEXT_TIMEOUT)
use constant EJECT_TRIES   => 20;    # najvise toliko pokusaja (po EJECT_DELAY) da procesi oslobode drajv

my $UA = "AudioCD/$VERSION ( https://github.com/nas963/lyrion-cd-plugin )";

my $prefs = preferences('plugin.audiocd');
my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.audiocd',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_AUDIOCD',
});

my ($STATE, $CACHE, $RIPPER, $META, $POLL);
my %TIMERS;      # aktivni LMS tajmeri ovog plugina (gase se u shutdownPlugin)
my %CHILD_W;     # EV child watcher-i po pid-u
my %RUN_CMD;     # cd-info poslovi: drze drajv, pa bi ioctl (polling) blokirao LMS dok traju
my (%MOVING, %MOVING_JOB, %MOVE_STATE);    # premestanja u biblioteku u toku (po id-u rip-a), njihovi cp poslovi i ishod (moving / last_error / warning)
use constant MOVE_LIMIT => 1800;    # s, cp se ubija posle ovoliko

sub getDisplayName { return 'PLUGIN_AUDIOCD' }

# ProtocolHandler: metapodaci diska (trenutni ili iz MetaCache-a).
sub disc_info {
	my ($discid) = @_;
	return $STATE ? $STATE->disc_info($discid) : undef;
}

# ProtocolHandler: audiocd:// pesma se pusta, a kes ne izvlaci taj disk -> pokreni ga (ista
# pravila zauzetog drajva kao Play, lista plejera se ne dira). -> ($ok, $err)
sub ensure_cached {
	my ($discid, $n) = @_;
	return (undef, { error => 'not_available' }) unless $STATE;
	return $STATE->request_cache($discid, $n);
}

# ---------- tajmeri i Jobs backend ----------

sub _timer {
	my ($secs, $cb) = @_;
	my $h;
	$h = Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $secs, sub {
		delete $TIMERS{$h};
		$cb->();
	});
	$TIMERS{$h} = $h;
	return $h;
}

sub _cancel_timer {
	my ($h) = @_;
	return unless $h && delete $TIMERS{$h};
	Slim::Utils::Timers::killSpecific($h);
	return;
}

# LMS-ov EV sam pokuplja decu (SIGCHLD), pa status procesa stize preko EV::child.
sub _io_backend {
	return {
		add_read     => sub { my ($fh, $cb) = @_; Slim::Networking::Select::addRead($fh, sub { $cb->($fh) }) },
		remove_read  => sub { Slim::Networking::Select::removeRead($_[0]) },
		timer        => \&_timer,
		cancel_timer => \&_cancel_timer,
		child        => sub {
			my ($pid, $cb) = @_;
			$CHILD_W{$pid} = EV::child($pid, 0, sub {
				my $st = $_[0]->rstatus;
				delete $CHILD_W{$pid};
				$cb->($st);
			});
			return $CHILD_W{$pid};
		},
	};
}

# ---------- pomocne ----------

sub _device { my $d = $prefs->get('device'); return defined $d && length $d ? $d : '/dev/cdrom' }

sub _rips_dir { return Plugins::AudioCD::Config::rips_dir($prefs->get('ripsDir')) }

sub _base_dir {
	my $c = preferences('server')->get('cachedir');
	return catdir($c, 'AudioCD');
}

sub _http_get {
	my ($url, $ok, $err) = @_;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { my ($http) = @_; $ok->($http->content, $http->code) },
		sub { my ($http, $error) = @_; $err->($error // 'http greska') },
		{ timeout => HTTP_TIMEOUT },
	)->get($url, 'User-Agent' => $UA);
	return;
}

# Lookup run_cmd: cd-info preko Jobs-a. Lookup vec dodaje nice/ionice (Ruling 12); ovde se samo
# /usr/bin/cd-info zamenjuje alatom iz Tools::find (Ruling 11). Izlaz se vraca kao UTF-8 bajtovi.
# cd-info na disku bez CD-Text-a zna da radi i par minuta i sve vreme drzi drajv: ubija se posle
# RUN_CMD_LIMIT s, a polling ne dira drajv dok radi (ioctl bi blokirao LMS).
sub _run_cmd {
	my ($argv, $cb) = @_;
	my @a = @$argv;
	for (@a) {
		next unless $_ eq '/usr/bin/cd-info';
		my $p = Plugins::AudioCD::Tools::find('cd-info') or return $cb->(undef);
		$_ = $p;
	}
	my (@out, $pid);
	my $job = Plugins::AudioCD::Jobs->spawn(
		argv    => \@a,
		on_line => sub { push @out, $_[0] },
		on_exit => sub {
			delete $RUN_CMD{$pid} if defined $pid;
			$cb->(join '', map { Encode::encode('UTF-8', $_) . "\n" } @out);
			$STATE->on_lookup_idle if $STATE && !%RUN_CMD;    # odlozeni automatski rip
			$STATE->on_jobs_changed if $STATE;
		},
	);
	$pid = $job->pid;
	$RUN_CMD{$pid} = $job;
	_timer(RUN_CMD_LIMIT, sub { $job->kill if $job->is_running });
	return;
}

# Omot: URL-ovi redom, prvi uspesan se upisuje u $dest (preko .tmp + rename).
sub _fetch_cover {
	my ($urls, $dest, $cb) = @_;
	my @todo = @$urls;
	my $next;
	$next = sub {
		my $url = shift @todo;
		if (!defined $url) { undef $next; return $cb->(0) }
		_http_get($url, sub {
			my ($body, $code) = @_;
			return $next->() unless defined $code && $code == 200 && defined $body && length $body > 100;
			my $tmp = "$dest.tmp$$";
			my $ok = eval {
				(my $dir = $dest) =~ s{/[^/]*\z}{};
				File::Path::make_path($dir, { mode => 0755 }) unless -d $dir;
				open my $fh, '>:raw', $tmp or die "$tmp: $!\n";
				print {$fh} $body or die "$tmp: $!\n";
				close $fh or die "$tmp: $!\n";
				chmod 0644, $tmp;
				rename $tmp, $dest or die "rename: $!\n";
				1;
			};
			unless ($ok) {
				unlink $tmp;
				$log->warn("omot nije sacuvan: $@");
				return $next->();
			}
			undef $next;
			$cb->(1);
		}, sub {
			main::INFOLOG && $log->is_info && $log->info("omot $url: $_[0]");
			$next->();
		});
	};
	$next->();
	return;
}

# Play: cela lista diska na plejeru, start od izabrane pesme.
sub _play {
	my ($client_id, $urls, $idx) = @_;
	my $client = defined $client_id ? Slim::Player::Client::getClient($client_id) : undef;
	return (undef, { error => 'no_player' }) unless $client;
	my @tracks;
	for my $url (@$urls) {
		my ($discid, $n) = Plugins::AudioCD::ProtocolHandler->parse_url($url);
		my $meta = Plugins::AudioCD::ProtocolHandler->getMetadataFor($client, $url);
		my %attr = (CT => 'flc', TRACKNUM => $n);
		$attr{TITLE}  = $meta->{title}    if defined $meta->{title};
		$attr{ARTIST} = $meta->{artist}   if defined $meta->{artist};
		$attr{ALBUM}  = $meta->{album}    if defined $meta->{album};
		$attr{SECS}   = $meta->{duration} if defined $meta->{duration};
		my $t = Slim::Schema->updateOrCreate({ url => $url, attributes => \%attr });
		push @tracks, $t if $t;
	}
	return (undef, { error => 'play_failed' }) unless @tracks == @$urls;
	$client->execute(['power', 1]) unless $client->power;
	$client->execute(['playlist', 'playtracks', 'listRef', \@tracks, undef, $idx]);
	return (1, undef);
}

# Zivi procesi koji mogu da drze drajv (cd-info, cd-paranoia, cyanrip, eject, i oni koji jos
# umiru posle kill-a); premestanja u biblioteku (cp) ne diraju drajv.
sub _drive_procs {
	my $n = Plugins::AudioCD::Jobs::running_count() - scalar(keys %MOVING_JOB);
	return $n > 0 ? $n : 0;
}

# Izbacivanje: ioctl, a ako ne uspe, alat `eject` preko Jobs-a (Ruling 1).
# $done->() se zove tacno jednom kad je izbacivanje pokusano ili napusteno (State: eject_pending).
sub _eject {
	my ($was_busy, $done) = @_;
	my $fired = 0;
	my $finish = sub { return if $fired++; eval { $done->() if $done; 1 } or $log->warn("eject done: $@") };
	my $dev = _device();
	my $do = sub {
		my ($ok, $err) = Plugins::AudioCD::Drive::eject($dev);
		return $finish->() if $ok;
		my $tool = Plugins::AudioCD::Tools::find('eject');
		unless ($tool) {
			$log->warn("izbacivanje nije uspelo ($err), alat eject ne postoji");
			return $finish->();
		}
		my $job = eval {
			Plugins::AudioCD::Jobs->spawn(
				argv    => [ Plugins::AudioCD::Jobs::low_prio($tool, $dev) ],
				on_exit => sub { $log->warn("eject $dev: status $_[0]") if $_[0]; $finish->() },
			);
		};
		$finish->() unless $job;
	};
	return $do->() unless $was_busy;
	# Posao je upravo prekinut: CDROMEJECT tek kad nijedan proces vise ne drzi drajv (cd-info,
	# cd-paranoia, cyanrip umiru asinhrono), inace bi ioctl blokirao LMS.
	my $tries = 0;
	my $wait;
	$wait = sub {
		if (_drive_procs() == 0) { undef $wait; return $do->() }
		if (++$tries > EJECT_TRIES) {
			undef $wait;
			$log->warn("izbacivanje odustalo: procesi i dalje drze drajv");
			return $finish->();
		}
		_timer(EJECT_DELAY, $wait);
	};
	_timer(EJECT_DELAY, $wait);
	return;
}

# Kraj ripa: kratka poruka na svim ukljucenim plejerima.
sub _notify {
	my ($e) = @_;
	my $res = $e->{result} // '';
	my $key = $res eq 'ok' ? 'PLUGIN_AUDIOCD_RIP_DONE'
		: $res eq 'accurip_mismatch' ? 'PLUGIN_AUDIOCD_RIP_WARNING' : 'PLUGIN_AUDIOCD_RIP_FAILED';
	my $what = join ' - ', grep { defined && length } $e->{artist}, $e->{album};
	for my $client (Slim::Player::Client::clients()) {
		next unless $client->power;
		my $title = $client->string('PLUGIN_AUDIOCD');
		my $msg   = $client->string($key) . (length $what ? ": $what" : '');
		$client->showBriefly({ line => [ $title, $msg ], jive => { type => 'popupinfo', text => [ $title, $msg ] } },
			{ duration => 5 });
	}
	return;
}

sub _missing_tools { return Plugins::AudioCD::Tools::missing('cyanrip', 'cd-paranoia', 'flac') }

# Kes za Play pripada pluginu: pri startu se brise sve sto je ostalo.
sub _clear_dir {
	my ($dir) = @_;
	opendir(my $dh, $dir) or return;
	my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	for my $k (@kids) {
		my $p = "$dir/$k";
		if (-d $p && !-l $p) { File::Path::remove_tree($p, { error => \my $err }) }
		else                 { unlink $p }
	}
	return;
}

# ---------- meni (My Music) i Material ----------

# Cvor "Audio CD" u My Music (aplikacije, Material); pesme/akcije su u Menu.pm.
sub _register_menu {
	Slim::Menu::BrowseLibrary->registerNode(Plugins::AudioCD::Menu::node(sub {
		my ($client, $cb, $args) = @_;
		Plugins::AudioCD::Menu::feed($client, $cb, $args, $STATE ? $STATE->snapshot : undef, {
			string  => sub { my ($token, @a) = @_; my $s = Slim::Utils::Strings::cstring($client, $token, @a); return defined $s && $s ne $token ? $s : undef },
			profile => $prefs->get('profile'),
		});
	}));
	return;
}

# Blok u <prefs>/material-skin/custom.js koji ucitava audiocd-material.js; Unified Music blok se ne dira.
sub _install_material_bridge {
	my $dir = catdir(Slim::Utils::Prefs::dir(), 'material-skin');
	eval { Plugins::AudioCD::MaterialBridge::install($dir); 1 } or $log->error("Material Skin dodatak nije postavljen: $@");
	return;
}

# ---------- init / shutdown ----------

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);

	$prefs->init({ %Plugins::AudioCD::Config::DEFAULTS });
	Plugins::AudioCD::Jobs::set_io_backend(_io_backend());

	my $base = _base_dir();
	$META = Plugins::AudioCD::MetaCache->new(dir => catdir($base, 'meta'));

	my $play = catdir($base, 'play');
	my $cdir = Plugins::AudioCD::Cache::cache_dir(candidates => [ '/run/audiocd', '/dev/shm/audiocd', $play ]);
	unless ($cdir) {
		$log->error("nema upisivog foldera za kes; koristim $play");
		$cdir = $play;
	}
	_clear_dir($cdir);
	$CACHE = Plugins::AudioCD::Cache->new(dir => $cdir, device => \&_device, secure => sub { $prefs->get('secureCache') },
		on_change => sub { $STATE->on_jobs_changed if $STATE });

	$RIPPER = Plugins::AudioCD::Ripper->new(
		history_file => catdir($base, 'history.json'),
		on_change    => sub { return unless $STATE; $STATE->on_rip_change; $STATE->on_jobs_changed },
	);
	my $n = $RIPPER->recover_interrupted(_rips_dir());
	$log->warn("obrisano $n ostataka prekinutih rip-ova") if $n;

	my $lookup = Plugins::AudioCD::Metadata::Lookup->new(
		http_get => \&_http_get,
		run_cmd  => \&_run_cmd,
		timer    => sub { _timer(@_); return },
		version  => $VERSION,
		device   => \&_device,    # zivo: promena podesavanja vazi bez restarta
	);

	my $last_status = '';
	$STATE = Plugins::AudioCD::State->new(
		pref          => sub { $prefs->get($_[0]) },
		read_toc      => \&Plugins::AudioCD::Drive::read_toc,
		lookup        => $lookup,
		metacache     => $META,
		cache         => $CACHE,
		ripper        => $RIPPER,
		rips_dir      => \&_rips_dir,
		fetch_cover   => \&_fetch_cover,
		play          => \&_play,
		eject         => \&_eject,
		missing_tools => \&_missing_tools,
		notify        => \&_notify,
		kill_all      => \&Plugins::AudioCD::Jobs::kill_all,
		drive_status  => \&Plugins::AudioCD::Drive::drive_status,
		lookup_busy   => sub { %RUN_CMD ? 1 : 0 },
		drive_procs   => \&_drive_procs,
		kill_lookup   => sub { $_->kill for values %RUN_CMD },
		log           => sub { my ($lvl, $m) = @_; $lvl eq 'warn' ? $log->warn($m) : $log->info($m) },
		on_change     => sub {
			my $s = $STATE or return;
			return if $s->status eq $last_status;
			$last_status = $s->status;
			main::INFOLOG && $log->is_info && $log->info("stanje diska: $last_status");
		},
	);

	Slim::Player::ProtocolHandlers->registerHandler(audiocd => 'Plugins::AudioCD::ProtocolHandler');
	Plugins::AudioCD::ProtocolHandler->set_cache($CACHE);

	_register_menu();
	_install_material_bridge();

	# Web stranica (omot, stavka u Extras) i podesavanja
	require Plugins::AudioCD::Web;
	Plugins::AudioCD::Web->init(metacache => $META);
	require Plugins::AudioCD::Settings;
	Plugins::AudioCD::Settings->new;

	my %cmd = (
		load           => [ 0, 0, 1, \&_cli_load ],
		eject_event    => [ 0, 0, 1, \&_cli_eject_event ],
		status         => [ 0, 1, 1, \&_cli_status ],
		play           => [ 0, 0, 1, \&_cli_play ],
		rip            => [ 0, 0, 1, \&_cli_rip ],
		cancel         => [ 0, 0, 1, \&_cli_cancel ],
		eject          => [ 0, 0, 1, \&_cli_eject ],
		select_release => [ 0, 0, 1, \&_cli_select_release ],
		edit           => [ 0, 0, 1, \&_cli_edit ],
		move           => [ 0, 0, 1, \&_cli_move ],
		history        => [ 0, 1, 1, \&_cli_history ],
	);
	Slim::Control::Request::addDispatch([ 'audiocd', $_ ], $cmd{$_}) for keys %cmd;

	# Prva provera (auto-load ako je disk unutra), pa polling.
	$POLL = _timer(START_DELAY, sub { _poll(1) });

	$log->info("AudioCD $VERSION: uredjaj " . _device() . ", kes $cdir, rip-ovi " . _rips_dir());
	return;
}

sub _poll {
	my ($first) = @_;
	# ioctl na drajvu koji cita drugi proces (cd-info, cd-paranoia, cyanrip) blokira LMS: tada se preskace
	if ($STATE && $STATE->drive_busy eq 'none' && ($first || $prefs->get('polling'))) {
		my ($code, $err) = Plugins::AudioCD::Drive::drive_status(_device());
		eval { $STATE->on_drive_status($code, $err); 1 } or $log->error("polling: $@");
	}
	$POLL = _timer(POLL_INTERVAL, \&_poll);
	return;
}

sub shutdownPlugin {
	Slim::Menu::BrowseLibrary->deregisterNode('audiocd');
	_cancel_timer($POLL);
	_cancel_timer($_) for values %TIMERS;
	%TIMERS = ();
	$STATE->shutdown if $STATE;    # Jobs::kill_all, Cache::clear, ostaci rip-ova
	%CHILD_W = ();
	%RUN_CMD = ();
	%MOVING = %MOVING_JOB = %MOVE_STATE = ();
	return;
}

# ---------- CLI ----------

sub _done {
	my ($request, $ok, $err, %extra) = @_;
	if ($ok) {
		$request->addResult(ok => 1);
		$request->addResult($_ => $extra{$_}) for sort keys %extra;
	}
	else {
		$err ||= { error => 'failed' };
		$request->addResult(error => $err->{error});
		$request->addResult($_ => $err->{$_}) for grep { $_ ne 'error' } sort keys %$err;
	}
	$request->setStatusDone;
	return;
}

sub _param {
	my ($request, $name) = @_;
	my $v = $request->getParam($name);
	return defined $v && length $v ? $v : undef;
}

sub _cli_load {
	my ($request) = @_;
	my ($ok, $err) = $STATE->on_load(offline => _param($request, 'offline') ? 1 : 0, force => _param($request, 'force') ? 1 : 0);
	_done($request, $ok, $err, status => $STATE->snapshot->{status});
}

# udev: disk izvadjen. Pravila (ioctl samo kad je drajv slobodan, eject_after rip se ne prekida) su u State.
sub _cli_eject_event {
	my ($request) = @_;
	my ($ok, $err, $what) = $STATE->on_eject_event;
	_done($request, $ok, $err, result => $what);
}

sub _cli_status {
	my ($request) = @_;
	my $s = $STATE->snapshot;
	$request->addResult(version => $VERSION);
	$request->addResult($_ => $s->{$_}) for sort keys %$s;
	$request->setStatusDone;
}

sub _cli_play {
	my ($request) = @_;
	my $client = $request->client;
	if (my $pid = _param($request, 'player')) {
		$client = Slim::Player::Client::getClient($pid);
	}
	return _done($request, undef, { error => 'no_player' }) unless $client;
	my ($ok, $err) = $STATE->request_play($client->id, _param($request, 'track') // 1);
	_done($request, $ok, $err);
}

sub _cli_rip {
	my ($request) = @_;
	# 'flac' (nivo) se prihvata i ignorise: cyanrip nema opciju za nivo (Ruling 15)
	my ($id, $err) = $STATE->request_rip(
		profile => _param($request, 'profile'),
		dir     => _param($request, 'dir'),
		eject   => _param($request, 'eject'),
	);
	_done($request, $id, $err, id => $id);
}

sub _cli_cancel {
	my ($request) = @_;
	my $id = _param($request, 'id');
	my $ok = defined $id && $RIPPER->cancel($id);
	_done($request, $ok, { error => 'not_found' });
}

sub _cli_eject {
	my ($request) = @_;
	my ($ok, $err) = $STATE->eject;
	_done($request, $ok, $err);
}

sub _cli_select_release {
	my ($request) = @_;
	my ($ok, $err) = $STATE->select_release(_param($request, 'index'));
	_done($request, $ok, $err);
}

sub _decode_json {
	my ($text) = @_;
	return undef unless defined $text;
	my $data = utf8::is_utf8($text)
		? eval { JSON::PP->new->decode($text) }
		: (eval { JSON::PP->new->utf8->decode($text) } // eval { JSON::PP->new->decode($text) });
	return $data;
}

sub _cli_edit {
	my ($request) = @_;
	my $data = _decode_json(_param($request, 'json'));
	return _done($request, undef, { error => 'bad_args', field => 'json' }) unless ref $data eq 'HASH';
	my ($ok, $err) = $STATE->edit($data);
	_done($request, $ok, $err);
}

sub _cli_history {
	my ($request) = @_;
	$request->addResult(history => [ map { my $m = $MOVE_STATE{ $_->{id} // '' }; $m ? { %$_, move => { %$m } } : $_ } @{ $RIPPER->history } ]);
	$request->setStatusDone;
}

# Premesti u biblioteku (Library.pm iz Task 13): samo ispod LMS muzickih foldera.
sub _cli_move {
	my ($request) = @_;
	my $id = _param($request, 'id');
	my ($e) = grep { defined $id && defined $_->{id} && $_->{id} eq $id } @{ $RIPPER->history };
	return _done($request, undef, { error => 'not_found' })
		unless $e && defined $e->{path} && ($e->{result} // '') =~ /^(?:ok|accurip_mismatch)\z/;

	return _done($request, undef, { error => 'not_available' }) unless eval { require Plugins::AudioCD::Library; 1 };
	my ($lib, $lerr) = Plugins::AudioCD::Library::library_dir(_param($request, 'dest'), $prefs->get('libraryDir'),
		Slim::Utils::Misc::getMediaDirs('audio'));
	return _done($request, undef, { error => $lerr, $lerr eq 'bad_args' ? (field => 'dest') : () }) if $lerr;

	my ($dest, $err) = Plugins::AudioCD::Library::plan_move($e->{path}, $lib, _rips_dir());
	return _done($request, undef, { error => $err }) if $err;
	return _done($request, undef, { error => 'busy' }) if $MOVING{$id};

	# Asinhrono: kopiranje na drugi disk (EXDEV) ide u spoljnom procesu (cp), LMS petlja ne blokira.
	# CLI odmah odgovara; kraj premestanja azurira istoriju i stanje, pa skenira samo taj folder.
	$MOVING{$id} = 1;
	$MOVE_STATE{$id} = { moving => 1 };
	my ($timed_out, @sync);
	Plugins::AudioCD::Library::move_async($e->{path}, $dest,
		rips_root => _rips_dir(),
		spawn     => sub {
			my ($argv, $on_exit) = @_;
			my $job = Plugins::AudioCD::Jobs->spawn(
				argv    => [ Plugins::AudioCD::Jobs::low_prio(@$argv) ],
				on_exit => sub { delete $MOVING_JOB{$id}; $on_exit->(@_) },
			);
			$MOVING_JOB{$id} = $job;
			_timer(MOVE_LIMIT, sub { $timed_out = 1; $job->kill if $job->is_running });
		},
		on_done => sub {
			my ($ok, $merr, $warn) = @_;
			@sync = @_;
			delete $MOVING{$id};
			unless ($ok) {
				$merr = 'timeout' if $timed_out;
				$MOVE_STATE{$id} = { last_error => $merr || 'move_failed' };
				$log->error("premestanje u biblioteku: " . ($merr || 'move_failed'));
				$STATE->on_rip_change if $STATE;
				return;
			}
			# uspeh (i sa upozorenjem): istorija, stanje i skeniranje samo tog foldera
			$MOVE_STATE{$id} = $warn ? { warning => $warn } : {};
			delete $MOVE_STATE{$id} unless %{ $MOVE_STATE{$id} };
			$log->warn("premestanje u biblioteku: $warn") if $warn;
			$RIPPER->update_path($id, $dest);
			$STATE->on_rip_change if $STATE;
			Slim::Control::Request::executeRequest(undef, Plugins::AudioCD::Library::rescan_cmd($dest));
		},
	);
	# greska koja je nastala odmah (busy, exists, mkdir...) ide u odgovor
	return _done($request, undef, { error => $sync[1] || 'move_failed' }) if @sync && !$sync[0];
	_done($request, 1, undef, started => 1, dest => $dest, $sync[2] ? (warning => $sync[2]) : ());
}

1;
