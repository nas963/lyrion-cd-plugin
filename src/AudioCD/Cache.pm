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

use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Jobs;
use Plugins::AudioCD::Tools;

# ---------- folder kesa ----------

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
	return bless {
		spawn     => $a{spawn} || sub { Plugins::AudioCD::Jobs->spawn(@_) },
		dir       => $a{dir},
		device    => $a{device},
		secure    => $a{secure} ? 1 : 0,
		on_change => $a{on_change},
		paranoia  => $a{paranoia} || Plugins::AudioCD::Tools::find('cd-paranoia') || 'cd-paranoia',
		flac      => $a{flac} || Plugins::AudioCD::Tools::find('flac') || 'flac',
		discid    => undef,
		disc      => undef,
		tracks    => [],    # brojevi audio pesama, po redu
		queue     => [],
		done      => {},
		failed    => {},
		current   => undef,
	}, $class;
}

sub _notify {
	my ($self) = @_;
	my $cb = $self->{on_change} or return;
	eval { $cb->(); 1 } or warn "Cache on_change: $@";
	return;
}

sub _disc_dir { "$_[0]{dir}/$_[1]" }
sub _file { my ($self, $n) = @_; return sprintf('%s/%02d.flac', $self->_disc_dir($self->{discid}), $n) }

# Brise kes svih drugih diskova (cuva se samo trenutni).
sub _remove_others {
	my ($self, $keep) = @_;
	opendir(my $dh, $self->{dir}) or return;
	my @kids = grep { $_ ne '.' && $_ ne '..' && $_ ne $keep } readdir $dh;
	closedir $dh;
	for my $k (@kids) {
		my $p = "$self->{dir}/$k";
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
		elsif (/\.part\z/)      { unlink "$d/$_" }
	}
	return;
}

# start($disc, $toc, $first_track): redosled first..last, pa 1..first-1; gotove pesme se preskacu.
sub start {
	my ($self, $disc, $toc, $first) = @_;
	my $id = ref $disc eq 'HASH' ? $disc->{discid} : undef;
	unless (defined $id && $id =~ /^[A-Za-z0-9._-]+\z/ && $id !~ /^\.+\z/ && ref $toc eq 'HASH') {
		warn "Cache start: neispravan disk ili TOC\n";
		return 0;
	}

	if (!defined $self->{discid} || $self->{discid} ne $id) {
		$self->stop;
		$self->{done}   = {};
		$self->{discid} = $id;
		$self->_remove_others($id);
		File::Path::make_path($self->_disc_dir($id), { mode => 0755, error => \my $err });
		$self->_scan_existing;
	}
	$self->{disc}   = $disc;
	$self->{failed} = {};

	my @audio = map { $_->{n} } Plugins::AudioCD::DiscId::audio_tracks($toc);
	$self->{tracks} = \@audio;
	$first = $audio[0] unless defined $first && grep { $_ == $first } @audio;
	my $cur = $self->{current} ? $self->{current}{n} : 0;
	$self->{queue} = [ grep { !$self->{done}{$_} && $_ != $cur } (grep { $_ >= $first } @audio), (grep { $_ < $first } @audio) ];

	$self->_notify;
	$self->_pump;
	return 1;
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

sub discid { $_[0]{discid} }

# Prekida tekucu pesmu (brise .part) i prazni red; gotove pesme ostaju.
sub stop {
	my ($self) = @_;
	my $had = $self->busy;
	$self->{queue} = [];
	if (my $rec = delete $self->{current}) {
		$rec->{cancelled} = 1;
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
	File::Path::remove_tree($self->_disc_dir($self->{discid}), { error => \my $err }) if defined $self->{discid};
	$self->{discid} = $self->{disc} = undef;
	$self->{tracks} = [];
	$self->{done}   = {};
	$self->{failed} = {};
	$self->_notify;
	return;
}

sub status {
	my ($self) = @_;
	my $total = scalar @{ $self->{tracks} };
	my @done  = sort { $a <=> $b } keys %{ $self->{done} };
	return {
		done    => \@done,
		failed  => [ sort { $a <=> $b } keys %{ $self->{failed} } ],
		current => $self->{current} ? $self->{current}{n} : undef,
		percent => $total ? int(@done / $total * 100) : 0,
	};
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
		ARTIST                     => $t->{artist} // $disc->{artist},
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
		[ $self->{paranoia}, ($self->{secure} ? () : '-Z'), '-d', $self->{device}, $n, '-' ],
		[ $self->{flac}, '-0', '--silent', '-f', @tags, '-o', $part, '-' ],
	));
}

sub _pump {
	my ($self) = @_;
	return if $self->{current} || $self->{pumping};
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
	my $rec = { n => $n, final => $final, part => "$final.part", tail => [] };
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

sub _on_exit {
	my ($self, $rec, $status) = @_;
	return if $rec->{finished}++;
	if ($rec->{cancelled}) {
		unlink $rec->{part};
		return;
	}
	if ($status == 0 && -s $rec->{part}) {
		chmod 0644, $rec->{part};
		if (rename $rec->{part}, $rec->{final}) {
			$self->{done}{ $rec->{n} } = 1;
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
	delete $self->{current} if $self->{current} && $self->{current} == $rec;
	$self->_notify;
	$self->_pump;
	return;
}

1;
