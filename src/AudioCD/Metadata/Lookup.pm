package Plugins::AudioCD::Metadata::Lookup;

# Redosled izvora metapodataka: MusicBrainz -> GnuDB -> CD-Text -> genericki.
# Cist Perl, bez Slim zavisnosti: HTTP, pokretanje procesa i tajmeri se ubacuju (Plugin ih vezuje na LMS).
#
#   http_get => sub ($url, $cb_ok->($body_bytes, $status), $cb_err->($msg))
#   run_cmd  => sub (\@argv, $cb->($stdout_bytes))
#   timer    => sub ($secs, $cb)
#   now      => sub { vreme u sekundama (moze biti razlomljeno) }
#
# Zahtevi ne nose nikakve licne podatke: samo disc ID / TOC / CDDB parametri; User-Agent dodaje getter.
# MusicBrainz zahtevi idu kroz limiter (najmanje 1 s razmaka); GnuDB ne treba limiter.
# Telo odgovora stize kao bajtovi: MusicBrainz parser ih sam dekodira (JSON::PP->utf8),
# a GnuDB tekst se ovde dekodira iz UTF-8 pre parsiranja.

use strict;
use warnings;
use utf8;

use Encode ();
use Time::HiRes ();
use Unicode::Normalize ();

use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Metadata::MusicBrainz;
use Plugins::AudioCD::Metadata::GnuDB;
use Plugins::AudioCD::Metadata::CdText;

use constant MB_INTERVAL    => 1;
use constant CDTEXT_TIMEOUT => 10;    # watchdog za cd-info
use constant LOOKUP_TIMEOUT => 60;    # watchdog za ceo lookup

sub new {
	my ($class, %a) = @_;
	die "http_get je obavezan\n" unless ref $a{http_get} eq 'CODE';
	die "timer je obavezan\n"    unless ref $a{timer} eq 'CODE';
	return bless {
		http_get => $a{http_get},
		run_cmd  => $a{run_cmd},
		timer    => $a{timer},
		now      => $a{now} || sub { Time::HiRes::time() },
		version  => defined $a{version} ? $a{version} : '0',
		device   => defined $a{device} ? $a{device} : '/dev/cdrom',
		next_mb  => undef,
	}, $class;
}

sub generic_disc {
	my ($toc) = @_;
	my @audio = Plugins::AudioCD::DiscId::audio_tracks($toc);
	my $disc = {
		discid      => undef,
		cddbid      => undef,
		source      => 'generic',
		artist      => 'Unknown Artist',
		album       => 'Audio CD',
		year        => undef,
		disc_number => 1,
		disc_total  => 1,
		compilation => 0,
		tracks      => [ map { { n => $_->{n}, title => 'Track ' . $_->{n}, artist => 'Unknown Artist', length => undef } } @audio ],
	};
	fill_lengths($disc, $toc);
	return $disc;
}

sub fill_lengths {
	my ($disc, $toc) = @_;
	my $len = Plugins::AudioCD::DiscId::track_lengths($toc);
	for my $t (@{ $disc->{tracks} || [] }) {
		$t->{length} = $len->{ $t->{n} } if !defined $t->{length} && defined $len->{ $t->{n} };
	}
	return $disc;
}

# Mala slova, bez akcenata, razmaci svedeni i skinuti: za poredjenje naslova albuma.
sub _norm_title {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s = Unicode::Normalize::NFD($s);
	$s =~ s/\p{Mn}//g;
	$s = lc $s;
	$s =~ s/\s+/ /g;
	$s =~ s/^ | $//g;
	return $s;
}

sub _decode_utf8 {
	my ($bytes) = @_;
	return '' unless defined $bytes;
	return Encode::decode('UTF-8', $bytes);
}

# Zastita: $cb se izvrsava najvise jednom.
sub _once {
	my ($cb) = @_;
	my $fired = 0;
	return sub { return if $fired++; return $cb->(@_) };
}

# HTTP zahtev sa garancijom: tacno jedan od ok/err se izvrsava (drugi poziv se ignorise);
# izuzetak u ok handleru ili u samom getteru postaje err.
sub _get {
	my ($self, $url, $ok, $err) = @_;
	my $fired = 0;
	my $e = sub { return if $fired++; $err->(@_) };
	my $o = sub {
		return if $fired++;
		my @a = @_;
		eval { $ok->(@a); 1 } or do { my $m = $@; $err->("handler: $m") };
	};
	eval { $self->{http_get}->($url, $o, $e); 1 } or do {
		my $m = $@;
		$e->("http_get: $m");
	};
	return;
}

# MusicBrainz zahtev kroz limiter: svaki dobija svoj termin, najmanje MB_INTERVAL posle prethodnog.
sub _mb_get {
	my ($self, $url, $ok, $err) = @_;
	my $now  = $self->{now}->();
	my $slot = (defined $self->{next_mb} && $self->{next_mb} > $now) ? $self->{next_mb} : $now;
	$self->{next_mb} = $slot + MB_INTERVAL;
	my $delay = $slot - $now;
	if ($delay > 0) {
		$self->{timer}->($delay, sub { $self->_get($url, $ok, $err) });
	}
	else {
		$self->_get($url, $ok, $err);
	}
	return;
}

sub _track_count {
	my ($toc) = @_;
	return scalar(my @a = Plugins::AudioCD::DiscId::audio_tracks($toc));
}

# Disk bez albuma I bez izvodjaca je promasaj (parse_read na gresci vraca prazan disk).
sub _usable {
	my ($disc) = @_;
	return 0 unless ref $disc eq 'HASH';
	return ((defined $disc->{album} && length $disc->{album}) || (defined $disc->{artist} && length $disc->{artist})) ? 1 : 0;
}

# GnuDB: query -> prvi pogodak -> read. $cb->($disc|undef) tacno jednom. Los/prazan odgovor je promasaj.
sub _gnudb {
	my ($self, $toc, $cddbid, $cb) = @_;
	$cb = _once($cb);
	my $v    = $self->{version};
	my $miss = sub { $cb->(undef) };
	$self->_get(
		Plugins::AudioCD::Metadata::GnuDB::query_url($toc, $cddbid, $v),
		sub {
			my ($body, $status) = @_;
			return $cb->(undef) unless defined $status && $status == 200;
			my $m = Plugins::AudioCD::Metadata::GnuDB::parse_query(_decode_utf8($body));
			return $cb->(undef) unless @$m;
			$self->_get(
				Plugins::AudioCD::Metadata::GnuDB::read_url($m->[0]{category}, $m->[0]{id}, $v),
				sub {
					my ($b2, $s2) = @_;
					return $cb->(undef) unless defined $s2 && $s2 == 200;
					my $disc = Plugins::AudioCD::Metadata::GnuDB::parse_read(_decode_utf8($b2), _track_count($toc));
					return $cb->(undef) unless _usable($disc);
					$cb->($disc);
				},
				$miss,
			);
		},
		$miss,
	);
	return;
}

# CD-Text: watchdog CDTEXT_TIMEOUT s; zakasneli rezultat se ignorise.
sub _cdtext {
	my ($self, $toc, $cb) = @_;
	return $cb->(undef) unless ref $self->{run_cmd} eq 'CODE';
	$cb = _once($cb);
	my @argv = ('nice', '-n', '10', 'ionice', '-c3', Plugins::AudioCD::Metadata::CdText::command($self->{device}));
	$self->{timer}->(CDTEXT_TIMEOUT, sub { $cb->(undef) });
	my $ok = eval {
		$self->{run_cmd}->(\@argv, sub {
			my ($out) = @_;
			my $disc = eval {
				my $text;
				if (defined $out) {
					$text = eval { Encode::decode('UTF-8', $out, Encode::FB_CROAK) };
					$text = Encode::decode('ISO-8859-1', $out) unless defined $text;
				}
				Plugins::AudioCD::Metadata::CdText::parse($text, _track_count($toc));
			};
			$cb->(_usable($disc) ? $disc : undef);
		});
		1;
	};
	$cb->(undef) unless $ok;
	return;
}

sub _candidate_of {
	my ($disc) = @_;
	return { release_id => undef, title => $disc->{album}, artist => $disc->{artist}, disc => $disc };
}

# Sklapa rezultat (bez poziva callback-a); umire na gresci.
sub _build {
	my ($toc, $ids, $cands, $selected, $fuzzy) = @_;
	for my $c (@$cands) {
		$c->{disc}{discid} = $ids->{discid};
		$c->{disc}{cddbid} = $ids->{cddbid};
		fill_lengths($c->{disc}, $toc);
		$c->{fuzzy} = 1 if $fuzzy;
	}
	my $sel = $cands->[$selected];
	my @covers = $sel->{disc}{source} eq 'musicbrainz' ? Plugins::AudioCD::Metadata::MusicBrainz::cover_urls($sel) : ();
	return {
		discid     => $ids->{discid},
		cddbid     => $ids->{cddbid},
		candidates => $cands,
		selected   => $selected,
		fuzzy      => $fuzzy ? 1 : 0,
		disc       => $sel->{disc},
		cover_urls => \@covers,
	};
}

sub lookup {
	my ($self, $toc, $cb) = @_;
	my $ids = {
		discid => Plugins::AudioCD::DiscId::musicbrainz_id($toc),
		cddbid => Plugins::AudioCD::DiscId::cddb_id($toc),
	};
	my $count = _track_count($toc);
	my $done  = 0;

	# Isporuka: tacno jednom; ako sklapanje pukne, ide se na sledeci izvor.
	my $deliver = sub {
		my ($cands, $sel, $fuzzy, $next) = @_;
		return if $done;
		my $res = eval { _build($toc, $ids, $cands, $sel, $fuzzy) };
		if (!$res) { return $next ? $next->() : undef }
		$done = 1;
		$cb->($res);
		return;
	};

	my $fallback_generic = sub {
		return if $done;
		my $res = eval { _build($toc, $ids, [ _candidate_of(generic_disc($toc)) ], 0, 0) }
			|| { discid => $ids->{discid}, cddbid => $ids->{cddbid}, candidates => [], selected => 0, fuzzy => 0,
				disc => generic_disc($toc), cover_urls => [] };
		$done = 1;
		$cb->($res);
		return;
	};
	my $try_cdtext = sub {
		return if $done;
		$self->_cdtext($toc, sub {
			my ($d) = @_;
			return if $done;
			return $fallback_generic->() unless $d;
			$deliver->([ _candidate_of($d) ], 0, 0, $fallback_generic);
		});
	};
	my $try_gnudb = sub {
		return if $done;
		$self->_gnudb($toc, $ids->{cddbid}, sub {
			my ($d) = @_;
			return if $done;
			return $try_cdtext->() unless $d;
			$deliver->([ _candidate_of($d) ], 0, 0, $try_cdtext);
		});
	};

	# Ukupni watchdog: sta god da visi, lookup zavrsava genericki.
	$self->{timer}->(LOOKUP_TIMEOUT, sub { $fallback_generic->() });

	my $mb_done = sub {
		my ($body, $status) = @_;
		return $try_gnudb->() unless defined $status && $status == 200;
		my $cands = Plugins::AudioCD::Metadata::MusicBrainz::parse_releases($body, $ids->{discid}, $count);
		return $try_gnudb->() unless @$cands;

		my $exact = Plugins::AudioCD::Metadata::MusicBrainz::has_exact_match($body, $ids->{discid});
		return $deliver->($cands, 0, 0, $try_gnudb) if $exact;
		# Jedan priblizan kandidat: oznaka fuzzy, GnuDB nije potreban.
		return $deliver->($cands, 0, 1, $try_gnudb) if @$cands < 2;

		# Priblizan pogodak sa vise izdanja: GnuDB pomaze da se preselektuje pravo izdanje.
		$self->_gnudb($toc, $ids->{cddbid}, sub {
			my ($g) = @_;
			return if $done;
			my $sel = 0;
			if ($g) {
				my $want = _norm_title($g->{album});
				for my $i (0 .. $#$cands) {
					if (length $want && _norm_title($cands->[$i]{title}) eq $want) { $sel = $i; last }
				}
			}
			$deliver->($cands, $sel, 1, $try_gnudb);
		});
	};

	$self->_mb_get(
		Plugins::AudioCD::Metadata::MusicBrainz::discid_url($ids->{discid}, Plugins::AudioCD::DiscId::mb_toc_string($toc)),
		$mb_done,
		sub { $try_gnudb->() },
	);
	return;
}

1;
