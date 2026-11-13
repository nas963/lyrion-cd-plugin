package Plugins::AudioCD::Menu;

# Cvor "Audio CD" u My Music (aplikacije i Material): disk kao stavka (Play/Add u zaglavlju), Ripuj, Izbaci.
# feed() i node() su cisti (bez Slim::*): State snapshot i akcije dolaze spolja, pa se testiraju
# bez LMS-a. LMS se dodiruje tek u default_run() (audiocd CLI preko executeRequest).

use strict;
use warnings;
use utf8;

use Plugins::AudioCD::Cache;
use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Url;

use constant ICON  => 'plugins/AudioCD/cd-generic.png';
use constant WEIGHT => 95;

# Cvor za Slim::Menu::BrowseLibrary->registerNode ($feed: coderef XMLBrowser feed-a).
sub node {
	my ($feed) = @_;
	return {
		type         => 'link',
		name         => 'PLUGIN_AUDIOCD',
		id           => 'audiocd',
		feed         => $feed,
		icon         => ICON,
		jiveIcon     => ICON,
		weight       => WEIGHT,
		homeMenuText => 'PLUGIN_AUDIOCD',
	};
}

sub _tr {
	my ($o, $token, @args) = @_;
	my $s = $o->{string}->($token, @args);
	return defined $s ? $s : $token;
}

# Tekst za token, ili $fallback kad string ne postoji (string sub vraca undef/prazno).
sub _tr_or {
	my ($o, $fallback, $token, @args) = @_;
	my $s = $o->{string}->($token, @args);
	return defined $s && length $s ? $s : $fallback;
}

# audiocd komanda preko LMS-a: ($ok, $err).
sub default_run {
	my ($client, $cmd) = @_;
	require Slim::Control::Request;
	my $req = Slim::Control::Request::executeRequest($client, $cmd);
	my $err = $req ? $req->getResult('error') : 'failed';
	return defined $err ? (undef, { error => $err }) : (1, undef);
}

# Stavka-link koja izvrsi audiocd komandu i odgovori jednom tekstualnom stavkom.
sub _action {
	my ($o, $name, $cmd, $ok_token) = @_;
	return {
		name => $name,
		type => 'link',
		url  => sub {
			my ($client, $cb) = @_;
			my ($ok, $err) = $o->{run}->($client, $cmd);
			my $text = $ok ? _tr($o, $ok_token)
				: _tr_or($o, _tr($o, 'PLUGIN_AUDIOCD_ERR_UNKNOWN'), 'PLUGIN_AUDIOCD_ERR_' . uc(($err && $err->{error}) || 'failed'));
			$cb->({ items => [ { name => $text, type => 'text' } ] });
		},
	};
}

sub _play_action {
	my ($n) = @_;
	return { play => { command => [ 'audiocd', 'play' ], fixedParams => { track => $n } } };
}

# feed($client, $cb, $args, $snapshot, \%opts): XMLBrowser OPML.
#   opts: string => sub($token, @args), run => sub($client, \@cmd) -> ($ok, $err), profile => ime profila rip-a
sub feed {
	my ($client, $cb, $args, $snap, $opts) = @_;
	my %o = (
		string  => sub { $_[0] },
		run     => \&default_run,
		profile => 'balanced',
		%{ $opts || {} },
	);
	$snap ||= {};
	my $disc = ref $snap->{metadata} eq 'HASH' ? $snap->{metadata} : undef;
	my $status = $snap->{status} // 'empty';

	if ($status eq 'reading') {
		return $cb->({ name => _tr(\%o, 'PLUGIN_AUDIOCD'), items => [ { name => _tr(\%o, 'PLUGIN_AUDIOCD_UI_READING'), type => 'text' } ] });
	}
	unless ($status eq 'ready' && $disc && ref $snap->{toc} eq 'HASH' && defined $snap->{discid}) {
		return $cb->({
			name  => _tr(\%o, 'PLUGIN_AUDIOCD'),
			items => [
				{ name => _tr(\%o, 'PLUGIN_AUDIOCD_UI_NO_DISC'), type => 'text' },
				_action(\%o, _tr(\%o, 'PLUGIN_AUDIOCD_UI_LOAD_CD'), [ 'audiocd', 'load' ], 'PLUGIN_AUDIOCD_UI_LOADING'),
			],
		});
	}

	my $discid = $snap->{discid};
	my $image = $snap->{cover} ? Plugins::AudioCD::Url::cover_url($discid) : ICON;
	my %meta = map { ref $_ eq 'HASH' && defined $_->{n} ? ($_->{n} => $_) : () } @{ $disc->{tracks} || [] };

	my @tracks;
	my @audio = map { $_->{n} } Plugins::AudioCD::DiscId::audio_tracks($snap->{toc});
	for my $n (@audio) {
		my $t = $meta{$n} || {};
		my $title = defined $t->{title} && length $t->{title} ? $t->{title} : _tr(\%o, 'PLUGIN_AUDIOCD_UI_TRACK') . " $n";
		my $artist = Plugins::AudioCD::Cache::track_artist($t, $disc);
		my %it = (
			name        => "$n. $title",
			type        => 'audio',
			url         => "audiocd://$discid/$n",
			image       => $image,
			itemActions => _play_action($n),
		);
		$it{line2} = $artist if defined $artist && length $artist;
		$it{secs}  = $t->{length} if defined $t->{length};
		push @tracks, \%it;
	}

	my $album = defined $disc->{album} && length $disc->{album} ? $disc->{album} : undef;
	my $artist = defined $disc->{artist} && length $disc->{artist} ? $disc->{artist} : undef;
	my $name = defined $album ? (defined $artist ? "$artist – $album" : $album) : _tr(\%o, 'PLUGIN_AUDIOCD_UI_UNTITLED');

	my @items;
	if (@audio) {
		# Disk je jedna stavka tipa playlist: Material zaglavlje otvorenog diska dobija Play/Add iz
		# njenih akcija (a.current.actions.play), pa Play ide preko "audiocd play track:1" (celi disk,
		# kes), a Add je podrazumevani "browselibrary playlist add" cele stavke (sve audiocd:// pesme).
		my $sub = _tr(\%o, 'PLUGIN_AUDIOCD_MENU_TRACKS', scalar @audio);
		$sub = "$disc->{year} · $sub" if defined $disc->{year} && length $disc->{year};
		push @items, {
			name        => $name,
			line2       => $sub,
			type        => 'playlist',
			image       => $image,
			items       => \@tracks,
			itemActions => {
				items => { command => [ 'browselibrary', 'items' ], fixedParams => { mode => 'audiocd', item_id => '0' } },
				%{ _play_action($audio[0]) },
			},
		};
	}
	push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOCD_MENU_RIP', _tr_or(\%o, $o{profile}, 'PLUGIN_AUDIOCD_UI_PROFILE_' . uc($o{profile}))),
		[ 'audiocd', 'rip' ], 'PLUGIN_AUDIOCD_UI_RIP_STARTED');
	push @items, _action(\%o, _tr(\%o, 'PLUGIN_AUDIOCD_UI_EJECT'), [ 'audiocd', 'eject' ], 'PLUGIN_AUDIOCD_UI_EJECTING');

	return $cb->({ name => _tr(\%o, 'PLUGIN_AUDIOCD'), cover => $image, items => \@items });
}

1;
