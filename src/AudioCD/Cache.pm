package Plugins::AudioCD::Cache;

# Kes za Play: pesme diska se izvlace jedna po jedna (cd-paranoia | flac -0) u
# <cache_dir>/<discid>/NN.flac (prvo NN.flac.part, pa rename kad je gotova).
# Redosled: od izabrane pesme do kraja, pa od pocetka; prioritize() pomera pesmu na pocetak reda.
# Cuva se samo jedan disk. Cist Perl, bez Slim zavisnosti; spawn se ubacuje (testovi).
# Bit-perfect: cd-paranoia daje 44.1 kHz / 16 bit WAV, flac -0 je bez gubitaka, nema obrade.

use strict;
use warnings;
use utf8;

use File::Path ();
use Scalar::Util ();
use Time::HiRes ();

use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Jobs;
use Plugins::AudioCD::Tools;
use Plugins::AudioCD::Wave;

use constant WAIT_MAX => 120;    # sekundi cekanja na pesmu bez napretka
use constant HARD_MAX => 600;    # apsolutna granica cekanja (i dok .part raste)
use constant EARLY_SECS => 15;     # s muzike u .part pre ranog pustanja (sa secure duplo)
use constant EARLY_DIRECT => 5;    # isto, za direktno pustanje
use constant WAITING_TTL => 3;    # s; cekac koji se toliko nije javio vise ne drzi tekucu pesmu
use constant EARLY_MIN_SPEED => 4; # sporiji drajv ne stize da puni brze nego sto plejer trosi
use constant ENSURE_RETRY => 60;    # s, ponavljanje pokretanja kesa dok cd-info / proces / lookup pustaju drajv

# MusicBrainz disc ID: 28 znakova base64 (+/= -> ._-), uvek se zavrsava sa '-'.
sub valid_discid {
	my ($id) = @_;
	return defined $id && $id =~ /^[A-Za-z0-9._-]{27}-\z/ ? 1 : 0;
}

# Izvodjac pesme, a ako ga nema (ili je prazan) izvodjac diska.
sub track_artist {
	my ($t, $disc) = @_;
	return (defined $t->{artist} && length $t->{artist}) ? $t->{artist} : $disc->{artist};
}

# ---------- folder kesa ----------

use constant BYTES_PER_SEC => 176400;
use constant RESERVE       => 20 * 1024 * 1024;

# Potrebno mesto za kes diska: audio sekunde * 176400 * 0.65 (flac -0) + 20 MB.
sub needed_bytes {
	my ($toc) = @_;
	my $secs = 0;
	$secs += $_ for values %{ Plugins::AudioCD::DiscId::track_lengths($toc) };
	return int($secs * BYTES_PER_SEC * 0.65) + RESERVE;
}

# cache_dir(candidates => [...]) -> prvi koji postoji ili moze da se napravi i upisiv je; inace undef
sub cache_dir {
	my (%a) = @_;
	for my $d (@{ $a{candidates} || [] }) {
		next unless defined $d && length $d;
		File::Path::make_path($d, { mode => 0755, error => \my $err }) unless -d $d;
		return $d if -d $d && -w _ && -x _;
	}
	return undef;
}

# ---------- objekat ----------

sub new {
	my ($class, %a) = @_;
	die "Cache->new: dir mora biti apsolutna putanja\n" unless defined $a{dir} && $a{dir} =~ m{^/.};
	return bless {
		spawn     => $a{spawn} || sub { Plugins::AudioCD::Jobs->spawn(@_) },
		dir       => $a{dir},
		candidates => $a{candidates} || [],    # folderi za kes redom; bira se prvi sa dovoljno mesta
		df        => $a{df} || \&Plugins::AudioCD::Tools::df_free,
		last_error => undef,
		device    => $a{device},    # string ili sub (pref se cita za svaku pesmu)
		secure    => $a{secure},    # 0|1 ili sub
		speed     => $a{speed},     # brzina citanja (-S) ili sub; undef = bez ogranicenja
		early     => $a{early},     # 0|1 ili sub: pustanje dok se pesma jos izvlaci
		direct    => $a{direct},    # 0|1 ili sub: bez ucitavanja celog diska, samo trazena pesma i sledeca
		on_change => $a{on_change},
		on_mismatch => $a{on_mismatch},    # pesma nije duga kao u TOC-u: u drajvu je mozda drugi disk
		paranoia  => $a{paranoia} || Plugins::AudioCD::Tools::find('cd-paranoia') || 'cd-paranoia',
		flac      => $a{flac} || Plugins::AudioCD::Tools::find('flac') || 'flac',
		discid    => undef,
		disc      => undef,
		tracks    => [],    # brojevi audio pesama, po redu
		queue     => [],
		done      => {},
		failed    => {},
		current   => undef,
		waiters   => {},    # kljuc (plejer) => generacija poslednjeg cekaca
		waiting   => {},    # kljuc => { n, t } dok cekac ceka pesmu
		dying     => undef, # prekinuta pesma ciji proces jos drzi drajv; sledeca krece kad izadje
		# talasni oblik (Wave.pm): argv pomocnog procesa bez ulaza i izlaza; undef = iskljuceno
		wave_helper => $a{wave_helper},
		waves     => {},    # pesme sa gotovim NN.wave.json
		wave_queue => [],
		wave_job  => undef, # { n, job }
	}, $class;
}

sub _notify {
	my ($self) = @_;
	my $cb = $self->{on_change} or return;
	eval { $cb->(); 1 } or warn "Cache on_change: $@";
	return;
}

# Vrednost ili code ref (Plugin daje sub koji cita pref: promena vazi bez restarta).
sub _val { my ($v) = @_; return ref $v eq 'CODE' ? $v->() : $v }
sub _device { my $d = _val($_[0]{device}); return defined $d && length $d ? $d : '/dev/cdrom' }
sub _secure { return _val($_[0]{secure}) ? 1 : 0 }
sub direct  { return _val($_[0]{direct}) ? 1 : 0 }

# Opcija brzine za cd-paranoia. Drajv koji ne menja brzinu: cd-paranoia to prijavi i nastavlja.
sub _speed_args {
	my ($self) = @_;
	my $s = _val($self->{speed});
	return defined $s && $s =~ /^[1-9]\d?\z/ ? ('-S', $s) : ();
}

sub _disc_dir { "$_[0]{dir}/$_[1]" }
sub _file { my ($self, $n) = @_; return sprintf('%s/%02d.flac', $self->_disc_dir($self->{discid}), $n) }
sub _wave_file { my ($self, $n) = @_; return sprintf('%s/%02d.wave.json', $self->_disc_dir($self->{discid}), $n) }

# Kandidati za folder kesa, redom (Plugin: /run/audiocd, /dev/shm/audiocd, LMS cache); bez njih samo dir.
sub _candidates {
	my ($self) = @_;
	my %seen;
	return grep { defined && length && !$seen{$_}++ } @{ $self->{candidates} || [] }, $self->{dir};
}

# Prvi kandidat koji je upisiv i ima bar $need slobodnih bajtova (df nepoznat: upozorenje, prihvata se).
sub _pick_dir {
	my ($self, $need) = @_;
	for my $d ($self->_candidates) {
		next unless defined cache_dir(candidates => [$d]);
		my $free = $self->{df}->($d);
		unless (defined $free) {
			warn "Cache: ne mogu da saznam slobodan prostor za $d; provera se preskace\n";
			return $d;
		}
		return $d if $free >= $need;
	}
	return undef;
}

# Brise kes svih drugih diskova u folderu $dir (podrazumevano tekuci; cuva se samo trenutni).
sub _remove_others {
	my ($self, $keep, $dir) = @_;
	$dir //= $self->{dir};
	opendir(my $dh, $dir) or return;
	my @kids = grep { valid_discid($_) && $_ ne $keep } readdir $dh;
	closedir $dh;
	for my $k (@kids) {
		my $p = "$dir/$k";
		next if -l $p || !-d _;
		File::Path::remove_tree($p, { error => \my $err });
	}
	return;
}

# Gotove pesme koje su vec u folderu (npr. posle restarta plugina); ostaci .part se brisu.
sub _scan_existing {
	my ($self) = @_;
	my $d = $self->_disc_dir($self->{discid});
	opendir(my $dh, $d) or return;
	my @f = readdir $dh;
	closedir $dh;
	for (@f) {
		if (/^(\d\d)\.flac\z/) { $self->{done}{ $1 + 0 } = 1 }
		elsif (/^(\d\d)\.wave\.json\z/) { $self->{waves}{ $1 + 0 } = 1 }
		elsif (/\.(?:part|tmp)\z/) { unlink "$d/$_" }
	}
	$self->_wave_add($_) for sort { $a <=> $b } grep { !$self->{waves}{$_} } keys %{ $self->{done} };
	return;
}

# start($disc, $toc, $first_track[, resume => 1]): redosled first..last, pa 1..first-1; gotove pesme se
# preskacu. Eksplicitan start (Play, ensure) ponavlja i ranije neuspele pesme; resume (isti disk ponovo
# ubacen, State::_resume_cache) izvlaci samo nedostajuce: nikad pokusane i prekinute izbacivanjem.
sub start {
	my ($self, $disc, $toc, $first, %o) = @_;
	my $id = ref $disc eq 'HASH' ? $disc->{discid} : undef;
	unless (valid_discid($id) && ref $toc eq 'HASH') {
		warn "Cache start: neispravan disk ili TOC\n";
		return 0;
	}

	$self->{last_error} = undef;
	if (!defined $self->{discid} || $self->{discid} ne $id) {
		$self->stop;
		$self->_wave_reset;
		$self->{done}   = {};
		$self->{discid} = undef;
		$self->{tracks} = [];
		$self->_remove_others($id, $_) for $self->_candidates;    # stari disk oslobadja mesto pre provere
		my $need = needed_bytes($toc);
		my $dir = $self->_pick_dir($need);
		unless (defined $dir) {
			$self->{last_error} = { error => 'cache_no_space', needed => $need };
			warn "Cache: nema mesta za kes diska ($need bajtova) ni u jednom folderu\n";
			$self->_notify;
			return 0;
		}
		$self->{dir}    = $dir;
		$self->{discid} = $id;
		File::Path::make_path($self->_disc_dir($id), { mode => 0755, error => \my $err });
		$self->_scan_existing;
	}
	$self->{disc}   = $disc;
	$self->{lengths} = Plugins::AudioCD::DiscId::track_lengths($toc);
	# iza pesme je data pesma (enhanced CD): razmak sesija se ne racuna svuda isto, duzina se ne proverava
	my @t = sort { $a->{n} <=> $b->{n} } @{ $toc->{tracks} };
	$self->{no_length} = { map { $t[$_]{n} => 1 } grep { $t[ $_ + 1 ]{data} } 0 .. $#t - 1 };
	$self->{failed} = {} unless $o{resume};

	my @audio = map { $_->{n} } Plugins::AudioCD::DiscId::audio_tracks($toc);
	$self->{tracks} = \@audio;
	$first = $audio[0] unless defined $first && grep { $_ == $first } @audio;
	my $cur = $self->{current} ? $self->{current}{n} : 0;
	$self->{queue} = $self->_order($first, $cur);

	$self->_notify;
	$self->_pump;
	return 1;
}

# Red izvlacenja od pesme $first: do kraja, pa od pocetka; direktno pustanje: samo ta pesma.
sub _order {
	my ($self, $first, $cur) = @_;
	my @t = @{ $self->{tracks} };
	my @o = $self->direct ? ($first) : ((grep { $_ >= $first } @t), (grep { $_ < $first } @t));
	return [ grep { !$self->{done}{$_} && !$self->{failed}{$_} && $_ != $cur } @o ];
}

# Plejer $key sada trazi pesmu $n. Tekuca pesma koju vise niko ne slusa niti ceka se prekida (skok na
# drugu pesmu ne sme da ceka njen kraj); ako je nekome potrebna, $n ide prva posle nje.
sub demand {
	my ($self, $n, $key) = @_;
	return if $self->{done}{$n} || $self->{failed}{$n} || !grep { $_ == $n } @{ $self->{tracks} };
	my $cur = $self->{current};
	return if $cur && $cur->{n} == $n;
	if (!grep { $_ == $n } @{ $self->{queue} }) {
		return unless $self->direct;
		push @{ $self->{queue} }, $n;
	}
	$self->prioritize($n) if $self->{queue}[0] != $n;
	return if !$cur || $self->_needed($cur, $key);
	delete $self->{current};
	$cur->{cancelled} = 1;
	$cur->{state}     = 'gone';
	$self->{queue}    = $self->_order($n, 0);
	$self->{dying}    = $cur if $cur->{job};
	$cur->{job}->kill if $cur->{job};
	unlink $cur->{part};
	$self->_notify;
	$self->_pump;
	return;
}

# Da li tekucu pesmu cita ili ceka neki plejer osim $key.
sub _needed {
	my ($self, $rec, $key) = @_;
	for my $r (@{ $rec->{readers} || [] }) {
		return 1 if $r->{key} ne $key && $r->{fh} && defined fileno $r->{fh};
	}
	my $now = Time::HiRes::time();
	for my $k (keys %{ $self->{waiting} }) {
		my $w = $self->{waiting}{$k};
		return 1 if $k ne $key && $w->{n} == $rec->{n} && $now - $w->{t} < WAITING_TTL;
	}
	return 0;
}

# Plejer $key cita rastuci fajl pesme (ProtocolHandler::Growing); slaba referenca, zatvoren se ne racuna.
sub add_reader {
	my ($rec, $key, $fh) = @_;
	my $r = { key => $key, fh => $fh };
	Scalar::Util::weaken($r->{fh});
	push @{ $rec->{readers} }, $r;
	return;
}

# Direktno pustanje: pesma iza $n, ako jos treba da se izvuce (za prelaz bez pauze); inace undef.
sub next_wanted {
	my ($self, $n) = @_;
	return undef unless $self->direct;
	my ($next) = grep { $_ > $n } @{ $self->{tracks} };
	return undef if !defined $next || $self->{done}{$next} || $self->{failed}{$next};
	return undef if $self->{current} && $self->{current}{n} == $next;
	return undef if grep { $_ == $next } @{ $self->{queue} };
	return $next;
}

sub prioritize {
	my ($self, $n) = @_;
	return unless defined $n;
	my @q = @{ $self->{queue} };
	return unless grep { $_ == $n } @q;
	$self->{queue} = [ $n, grep { $_ != $n } @q ];
	$self->_notify;
	return;
}

# path($discid, $n) -> putanja gotove pesme ili undef (dok traje .part, ili disk nije u kesu)
sub path {
	my ($self, $discid, $n) = @_;
	return undef unless defined $discid && defined $self->{discid} && $discid eq $self->{discid};
	return undef unless defined $n && $self->{done}{$n};
	my $p = $self->_file($n);
	return -f $p ? $p : undef;
}

sub ready {
	my ($self, $n) = @_;
	return defined $self->{discid} && defined $self->path($self->{discid}, $n) ? 1 : 0;
}

sub busy {
	my ($self) = @_;
	return ($self->{current} || @{ $self->{queue} }) ? 1 : 0;
}

# Da li disk $id ima pesme koje nedostaju a izvlacenje je stalo (izbacen disk, ponovo ubacen)?
# Neuspele pesme se ne racunaju: ponavljaju se samo na eksplicitan Play/ensure.
sub resumable {
	my ($self, $id) = @_;
	return 0 unless defined $id && defined $self->{discid} && $id eq $self->{discid};
	return 0 if $self->busy || !@{ $self->{tracks} } || $self->direct;
	return (grep { !$self->{done}{$_} && !$self->{failed}{$_} } @{ $self->{tracks} }) ? 1 : 0;
}

# Disk izvadjen: pesme koje su pukle (najcesce bas zato sto je disk izvadjen) vise se ne vode kao
# neuspele, pa ih nastavak posle ponovnog ubacivanja izvlaci.
sub forget_failed {
	my ($self) = @_;
	return unless %{ $self->{failed} };
	$self->{failed} = {};
	$self->_notify;
	return;
}

sub discid { $_[0]{discid} }
sub dir    { $_[0]{dir} }
sub last_error { $_[0]{last_error} }    # posle neuspelog start-a: { error => 'cache_no_space', needed }

# Prekida tekucu pesmu (brise .part) i prazni red; gotove pesme ostaju.
sub stop {
	my ($self) = @_;
	my $had = $self->busy;
	$self->{queue} = [];
	if (my $rec = delete $self->{current}) {
		$rec->{cancelled} = 1;
		$rec->{state} = 'gone';
		$rec->{job}->kill if $rec->{job};
		unlink $rec->{part};
	}
	$self->_notify if $had;
	return;
}

# Zaustavlja i brise folder diska.
sub clear {
	my ($self) = @_;
	$self->stop;
	$self->_wave_reset;
	File::Path::remove_tree($self->_disc_dir($self->{discid}), { error => \my $err }) if defined $self->{discid};
	$self->{discid} = $self->{disc} = undef;
	$self->{tracks} = [];
	$self->{done}   = {};
	$self->{failed} = {};
	$self->_notify;
	return;
}

# Deo tekuce pesme koji je izvucen (0..0.99), po velicini .part: kompresija se procenjuje iz gotovih
# pesama istog diska, a dok ih nema 0.65. Procena se menja, pa vrednost samo raste.
sub _current_part {
	my ($self) = @_;
	my $rec = $self->{current} or return 0;
	my $len = $self->{lengths} || {};
	my $secs = $len->{ $rec->{n} } or return 0;
	my ($b, $s) = (0, 0);
	for my $n (keys %{ $self->{done} }) {
		my $l = $len->{$n} or next;
		$b += -s $self->_file($n) || 0;
		$s += $l;
	}
	my $rate = $s && $b ? $b / $s : BYTES_PER_SEC * 0.65;
	my $f = (-s $rec->{part} || 0) / ($secs * $rate);
	$f = 0.99 if $f > 0.99;
	$rec->{shown} = $f if $f > ($rec->{shown} // 0);
	return $rec->{shown} // 0;
}

# Procenat diska po trajanju pesama, ukljucujuci deo tekuce.
sub _percent {
	my ($self) = @_;
	my $len = $self->{lengths} || {};
	my ($all, $have) = (0, 0);
	for my $n (@{ $self->{tracks} }) {
		my $l = $len->{$n} || 1;
		$all  += $l;
		$have += $l if $self->{done}{$n};
	}
	return 0 unless $all;
	$have += $self->_current_part * ($len->{ $self->{current}{n} } || 1) if $self->{current};
	return int($have / $all * 100);
}

sub status {
	my ($self) = @_;
	my @done  = sort { $a <=> $b } keys %{ $self->{done} };
	return {
		done    => \@done,
		failed  => [ sort { $a <=> $b } keys %{ $self->{failed} } ],
		current => $self->{current} ? $self->{current}{n} : undef,
		percent => $self->_percent,
		direct  => $self->direct,
		waves   => [ sort { $a <=> $b } keys %{ $self->{waves} } ],
	};
}

# ---------- cekanje na pesmu (za ProtocolHandler::getNextTrack) ----------

# waiter(key => $player_id, discid => ..., n => ...[, now => sub, wait_max, hard_max]) -> $w
# Po kljucu vazi samo poslednji cekac: noviji gasi starije (preskakanje pesama).
sub waiter {
	my ($self, %a) = @_;
	my $now = $a{now} || \&Time::HiRes::time;
	my $t0  = $now->();
	my $wm  = $a{wait_max} // WAIT_MAX;
	my $hm  = $a{hard_max} // HARD_MAX;
	my $key = defined $a{key} ? $a{key} : '';
	return bless {
		cache    => $self,
		key      => $key,
		gen      => ++$self->{waiters}{$key},
		discid   => $a{discid},
		n        => $a{n},
		now      => $now,
		wait_max => $wm,
		deadline => $t0 + $wm,
		hard     => $t0 + $hm,
		size     => -1,
		ensure   => $a{ensure},              # sub($discid, $n) -> ($ok, $err): pokreni kes (State::request_cache)
		early    => $a{early},               # bajtova u .part za rano pustanje; undef = cekaj celu pesmu
		retry_to => $t0 + ENSURE_RETRY,
	}, 'Plugins::AudioCD::Cache::Waiter';
}

# Velicina .part tekuce pesme $n (undef ako se $n trenutno ne izvlaci).
sub part_size {
	my ($self, $n) = @_;
	my $c = $self->{current};
	return undef unless $c && defined $n && $c->{n} == $n;
	return -s $c->{part} || 0;
}

# Trajanje pesme iz TOC-a (s), tacno na sektor.
sub track_secs {
	my ($self, $discid, $n) = @_;
	return undef unless defined $discid && defined $self->{discid} && $discid eq $self->{discid};
	return $self->{lengths} ? $self->{lengths}{$n} : undef;
}

# Najmanja velicina .part za rano pustanje (procena za flac -0); undef = rano pustanje iskljuceno.
sub early_bytes {
	my ($self) = @_;
	return undef unless _val($self->{early}) || $self->direct;
	my $s = _val($self->{speed});
	return undef if defined $s && $s =~ /^\d+\z/ && $s < EARLY_MIN_SPEED;
	return int(($self->direct ? EARLY_DIRECT : EARLY_SECS) * ($self->_secure ? 2 : 1) * BYTES_PER_SEC * 0.65);
}

# Pesma koja se upravo izvlaci: zapis { part, state } ili undef. state: 'part' (raste), 'done'
# (gotova; .part je preimenovan, otvoren fajl ostaje isti) ili 'gone' (prekinuta ili neuspela).
sub growing {
	my ($self, $discid, $n) = @_;
	return undef unless defined $discid && defined $self->{discid} && $discid eq $self->{discid};
	return defined $self->part_size($n) ? $self->{current} : undef;
}

# ---------- izvlacenje ----------

sub _clean { my ($v) = @_; $v =~ s/[\r\n]+/ /g; return $v }

sub argv_for {
	my ($self, $n, $part) = @_;
	my $disc = $self->{disc} || {};
	my ($t) = grep { ref $_ eq 'HASH' && defined $_->{n} && $_->{n} == $n } @{ $disc->{tracks} || [] };
	$t ||= {};
	my @kv = (
		TITLE                      => $t->{title},
		ARTIST                     => track_artist($t, $disc),
		ALBUM                      => $disc->{album},
		TRACKNUMBER                => $n,
		MUSICBRAINZ_TRACKID        => $t->{recording_id},
		MUSICBRAINZ_ARTISTID       => $t->{artist_id},
		MUSICBRAINZ_ALBUMID        => $disc->{release_id},
		MUSICBRAINZ_ALBUMARTISTID  => $disc->{album_artist_id},
		MUSICBRAINZ_RELEASEGROUPID => $disc->{release_group_id},
	);
	my @tags;
	while (@kv) {
		my ($k, $v) = splice @kv, 0, 2;
		push @tags, '-T', "$k=" . _clean($v) if defined $v && $v ne '';
	}
	return Plugins::AudioCD::Jobs::low_prio(Plugins::AudioCD::Jobs::pipeline(
		[ $self->{paranoia}, ($self->_secure ? () : '-Z'), $self->_speed_args, '-d', $self->_device, $n, '-' ],
		[ $self->{flac}, '-0', '--silent', '-f', @tags, '-o', $part, '-' ],
	));
}

sub _pump {
	my ($self) = @_;
	return if $self->{current} || $self->{pumping} || $self->{dying};
	local $self->{pumping} = 1;
	while (!$self->{current} && @{ $self->{queue} }) {
		my $n = shift @{ $self->{queue} };
		next if $self->{done}{$n};
		$self->_spawn($n);
	}
	return;
}

sub _spawn {
	my ($self, $n) = @_;
	my $final = $self->_file($n);
	my $rec = { n => $n, final => $final, part => "$final.part", state => 'part', tail => [] };
	$self->{current} = $rec;
	my $job = eval {
		$self->{spawn}->(
			argv    => [ $self->argv_for($n, $rec->{part}) ],
			umask   => 022,
			on_line => sub { push @{ $rec->{tail} }, $_[0]; shift @{ $rec->{tail} } while @{ $rec->{tail} } > 5 },
			on_exit => sub { $self->_on_exit($rec, $_[0]) },
		);
	};
	if (!$job && !$rec->{finished}) {
		warn "Cache: spawn za pesmu $n nije uspeo: " . ($@ || 'nema posla') . "\n";
		$self->_on_exit($rec, 255);
		return;
	}
	$rec->{job} = $job unless $rec->{finished};
	$self->_notify;
	return;
}

# Trajanje iz FLAC zaglavlja (s) ili undef ako nije FLAC / nepoznato.
sub _flac_secs {
	my ($f) = @_;
	open my $fh, '<:raw', $f or return undef;
	my $n = read $fh, my $b, 26;
	close $fh;
	return undef unless defined $n && $n == 26 && substr($b, 0, 4) eq 'fLaC';
	my ($hi, $lo) = unpack 'NN', substr($b, 18, 8);
	my $rate    = $hi >> 12;
	my $samples = ($hi & 0xF) * 4294967296 + $lo;
	return $rate && $samples ? $samples / $rate : undef;
}

# Izvucena pesma mora da bude duga kao u TOC-u diska kome kes pripada (TOC je zaokruzen na sekundu).
sub _length_ok {
	my ($self, $rec) = @_;
	return 1 if $self->{no_length} && $self->{no_length}{ $rec->{n} };
	my $want = $self->{lengths} ? $self->{lengths}{ $rec->{n} } : undef;
	my $got  = _flac_secs($rec->{part});
	return 1 unless defined $want && defined $got;
	return 1 if abs($got - $want) <= 2;
	warn sprintf("Cache: pesma %d traje %.1f s umesto %d s; odbacena\n", $rec->{n}, $got, $want);
	return 0;
}

sub _on_exit {
	my ($self, $rec, $status) = @_;
	return if $rec->{finished}++;
	if ($rec->{cancelled}) {
		unlink $rec->{part} unless $self->{current} && $self->{current}{part} eq $rec->{part};
		if ($self->{dying} && $self->{dying} == $rec) {
			$self->{dying} = undef;
			$self->_pump;
		}
		return;
	}
	my $mismatch = 0;
	if ($status == 0 && -s $rec->{part} && !$self->_length_ok($rec)) {
		unlink $rec->{part};
		$self->{failed}{ $rec->{n} } = 1;
		$mismatch = 1;
	}
	elsif ($status == 0 && -s $rec->{part}) {
		chmod 0644, $rec->{part};
		if (rename $rec->{part}, $rec->{final}) {
			$self->{done}{ $rec->{n} } = 1;
			$rec->{state} = 'done';
			$self->_wave_add($rec->{n});
		}
		else {
			warn "Cache: rename $rec->{part}: $!\n";
			$self->{failed}{ $rec->{n} } = 1;
		}
	}
	else {
		warn "Cache: pesma $rec->{n} nije izvucena (status $status): " . join(' | ', @{ $rec->{tail} }) . "\n";
		unlink $rec->{part};
		$self->{failed}{ $rec->{n} } = 1;
	}
	$rec->{state} = 'gone' if $rec->{state} ne 'done';
	delete $self->{current} if $self->{current} && $self->{current} == $rec;
	$self->_notify;
	$self->_pump;
	if ($mismatch && $self->{on_mismatch}) {
		eval { $self->{on_mismatch}->(); 1 } or warn "Cache on_mismatch: $@";
	}
	return;
}

# ---------- talasni oblik ----------

# wave($discid, $n) -> { points, peak, rms } ili undef dok nije izracunat
sub wave {
	my ($self, $discid, $n) = @_;
	return undef unless defined $discid && defined $self->{discid} && $discid eq $self->{discid};
	return undef unless defined $n && $self->{waves}{$n};
	return Plugins::AudioCD::Wave::read_file($self->_wave_file($n));
}

# Pesma koja se upravo pusta ide prva u red za racunanje.
sub wave_first {
	my ($self, $n) = @_;
	my @q = @{ $self->{wave_queue} };
	return unless defined $n && grep { $_ == $n } @q;
	$self->{wave_queue} = [ $n, grep { $_ != $n } @q ];
	return;
}

sub _wave_add {
	my ($self, $n) = @_;
	return unless $self->{wave_helper} && !$self->{waves}{$n};
	return if grep { $_ == $n } @{ $self->{wave_queue} };
	return if $self->{wave_job} && $self->{wave_job}{n} == $n;
	push @{ $self->{wave_queue} }, $n;
	$self->_wave_pump;
	return;
}

# Jedan proces u isto vreme; drajv ne koristi, pa ne ulazi u busy().
sub _wave_pump {
	my ($self) = @_;
	while (!$self->{wave_job} && @{ $self->{wave_queue} }) {
		my $n = shift @{ $self->{wave_queue} };
		next if $self->{waves}{$n} || !$self->{done}{$n};
		my ($in, $out) = ($self->_file($n), $self->_wave_file($n));
		my $rec = { n => $n, discid => $self->{discid} };
		$self->{wave_job} = $rec;
		my $job = eval {
			$self->{spawn}->(
				argv    => [ Plugins::AudioCD::Jobs::low_prio(Plugins::AudioCD::Jobs::pipeline(
					[ $self->{flac}, '-d', '-c', '-s', '--force-raw-format', '--endian=little', '--sign=signed', $in ],
					[ @{ $self->{wave_helper} }, '--', $in, $out ],
				)) ],
				umask   => 022,
				on_line => sub { },
				on_exit => sub { $self->_wave_exit($rec, $_[0], $out) },
			);
		};
		if (!$job && !$rec->{finished}) {
			warn "Cache: talas pesme $n nije pokrenut: " . ($@ || 'nema posla') . "
";
			$rec->{finished} = 1;
			$self->{wave_job} = undef;
			next;
		}
		$rec->{job} = $job unless $rec->{finished};
	}
	return;
}

sub _wave_exit {
	my ($self, $rec, $status, $out) = @_;
	return if $rec->{finished}++;
	return if $rec->{cancelled};
	if ($status == 0 && -s $out && defined $self->{discid} && $self->{discid} eq $rec->{discid}) {
		$self->{waves}{ $rec->{n} } = 1;
	}
	else {
		warn "Cache: talas pesme $rec->{n} nije izracunat (status $status)
" if $status;
		unlink $out, "$out.tmp";
	}
	$self->{wave_job} = undef if $self->{wave_job} && $self->{wave_job} == $rec;
	$self->_wave_pump;
	return;
}

sub _wave_reset {
	my ($self) = @_;
	$self->{wave_queue} = [];
	$self->{waves} = {};
	if (my $rec = delete $self->{wave_job}) {
		$rec->{cancelled} = 1;
		$rec->{job}->kill if $rec->{job};
	}
	return;
}

package Plugins::AudioCD::Cache::Waiter;

use strict;
use warnings;

# poll($active) -> ('stop') | ('ready', $path) | ('early') | ('fail', $razlog) | ('wait')
#   stop: cekac je zastareo (noviji za isti plejer, ili LMS vise ne ceka ovu pesmu); bez callback-a
#   wait: pesma je na redu (Cache::demand); rok se produzava dok .part raste (najvise hard_max)
sub poll {
	my ($self, $active) = @_;
	my $c = $self->{cache};
	return ('stop') if !$active || ($c->{waiters}{ $self->{key} } // 0) != $self->{gen};
	my @r = $self->_poll;
	if ($r[0] eq 'wait') { $c->{waiting}{ $self->{key} } = { n => $self->{n}, t => Time::HiRes::time() } }
	else                 { delete $c->{waiting}{ $self->{key} } }
	$self->_ahead if $r[0] =~ /^(?:ready|early)\z/;
	return @r;
}

# Direktno pustanje: posle trazene pesme izvlaci se jos samo sledeca.
sub _ahead {
	my ($self) = @_;
	my $c = $self->{cache};
	my $next = $c->next_wanted($self->{n});
	return unless defined $next;
	if ($c->busy) { push @{ $c->{queue} }, $next }
	elsif ($self->{ensure}) { eval { $self->{ensure}->($self->{discid}, $next); 1 } or warn "Cache: $@" }
	return;
}

sub _poll {
	my ($self) = @_;
	my $c = $self->{cache};
	my ($discid, $n) = @$self{qw(discid n)};
	if (defined(my $p = $c->path($discid, $n))) { return ('ready', $p) }
	# Kes ne izvlaci ovaj disk (pesma dodata mimo Play-a): pokreni ga jednom; zauzet drajv
	# (cd-info, proces koji umire) ili disk koji se jos cita se ponavljaju do ENSURE_RETRY s.
	my $extracting = defined $c->discid && defined $discid && $c->discid eq $discid && $c->busy;
	if ($self->{ensure} && !$self->{ensured} && !$extracting) {
		my ($ok, $err) = eval { $self->{ensure}->($discid, $n) };
		$err = { error => 'failed', message => $@ } if !$ok && !$err;
		if ($ok) {
			$self->{ensured} = 1;
			if (defined(my $p = $c->path($discid, $n))) { return ('ready', $p) }
		}
		else {
			my $e = ref $err eq 'HASH' ? ($err->{error} // 'failed') : "$err";
			my $retry = $e eq 'not_ready' || ($e eq 'drive_busy' && ($err->{busy} // '') =~ /^(?:lookup|process)\z/);
			return ('wait') if $retry && $self->{now}->() < $self->{retry_to};
			return ('fail', "kes nije pokrenut: $e");
		}
	}
	return ('fail', 'disk nije u kesu') unless defined $c->discid && defined $discid && $c->discid eq $discid;
	return ('fail', 'izvlacenje pesme nije uspelo') if $c->{failed}{$n};
	return ('fail', 'kes ne izvlaci pesme') unless $c->busy;
	$c->demand($n, $self->{key});
	my $now  = $self->{now}->();
	my $size = $c->part_size($n);
	return ('early') if defined $self->{early} && defined $size && $size >= $self->{early};
	if (defined $size && $size > $self->{size}) {
		$self->{size}     = $size;
		$self->{deadline} = $now + $self->{wait_max};
		$self->{deadline} = $self->{hard} if $self->{deadline} > $self->{hard};
	}
	return ('fail', 'isteklo cekanje') if $now >= $self->{deadline};
	return ('wait');
}

1;
