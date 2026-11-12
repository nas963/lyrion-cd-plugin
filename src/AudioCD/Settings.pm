package Plugins::AudioCD::Settings;

# Stranica podesavanja (Slim::Web::Settings). Sva podesavanja iz Config::DEFAULTS su prefs ove klase,
# ali cuvanje ide kroz validate(): ili se sacuva sve, ili nista (greske se prikazuju uz uneto).
# FLAC nivo se ne prikazuje (cyanrip ga ignorise, Ruling 15): pref flacLevel ostaje u DEFAULTS i
# ne dira se; isto vazi za noRipWhileLocalPlays (nije u spec listi podesavanja).

use strict;
use warnings;
use utf8;
use base qw(Slim::Web::Settings);

use File::Spec ();

use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;

use Plugins::AudioCD::Config;
use Plugins::AudioCD::Library;
use Plugins::AudioCD::Profiles;

my @CHECKBOX = qw(quietDrive autoLoad autoRip ejectAfterRip notify polling secureCache);
my @SHOWN    = (qw(device ripsDir libraryDir profile quietSpeed driveOffset autoRipProfile), @CHECKBOX);

# Folder postoji (pa se u njega moze pisati) ili se moze napraviti: prvi postojeci predak je folder u koji se pise.
sub _creatable {
	my ($dir) = @_;
	my $p = $dir;
	while (length $p && !-e $p) {
		$p =~ s{/[^/]*\z}{};
	}
	$p = '/' unless length $p;
	return -d $p && -w _ ? 1 : 0;
}

sub _abs_clean {
	my ($v) = @_;
	return 0 unless defined $v && $v =~ m{^/} && $v !~ m{(?:^|/)\.\.(?:/|\z)} && $v !~ /[\x00-\x1f]/;
	return 1;
}

# validate(\%ulaz, media => \@muzicki_folderi) -> (\%za_cuvanje, \%greske)
# %greske: pref => token greske (SET_ERR_*); %za_cuvanje samo kad nema gresaka.
sub validate {
	my ($in, %opt) = @_;
	my (%clean, %err);
	my $s = sub { my $v = $in->{ $_[0] }; defined $v ? do { (my $t = $v) =~ s/^\s+|\s+$//g; $t } : '' };

	my $device = $s->('device');
	if ($device =~ m{^/dev/[A-Za-z0-9._/-]+\z} && _abs_clean($device)) { $clean{device} = $device }
	else { $err{device} = 'PLUGIN_AUDIOCD_SET_ERR_DEVICE' }

	my $rips = $s->('ripsDir');
	if ($rips eq '' || (_abs_clean($rips) && _creatable($rips))) { $clean{ripsDir} = $rips }
	else { $err{ripsDir} = 'PLUGIN_AUDIOCD_SET_ERR_RIPS_DIR' }

	my $lib = $s->('libraryDir');
	if ($lib eq '') { $clean{libraryDir} = '' }
	else {
		my ($dir, $e) = Plugins::AudioCD::Library::library_dir($lib, undef, $opt{media} || []);
		if (!$e && _creatable($dir)) { $clean{libraryDir} = $dir }
		else { $err{libraryDir} = 'PLUGIN_AUDIOCD_SET_ERR_LIBRARY_DIR' }
	}

	for my $k (qw(profile autoRipProfile)) {
		my $v = $s->($k);
		if (grep { $_ eq $v } @Plugins::AudioCD::Profiles::NAMES) { $clean{$k} = $v }
		else { $err{$k} = 'PLUGIN_AUDIOCD_SET_ERR_PROFILE' }
	}

	my $speed = $s->('quietSpeed');
	if ($speed =~ /^\d{1,2}\z/ && $speed >= 1 && $speed <= 52) { $clean{quietSpeed} = $speed + 0 }
	else { $err{quietSpeed} = 'PLUGIN_AUDIOCD_SET_ERR_QUIET_SPEED' }

	my $off = $s->('driveOffset');
	if ($off eq '') { $clean{driveOffset} = '' }
	elsif ($off =~ /^-?\d{1,4}\z/ && abs($off) <= 3000) { $clean{driveOffset} = $off + 0 }
	else { $err{driveOffset} = 'PLUGIN_AUDIOCD_SET_ERR_DRIVE_OFFSET' }

	# nestiklirana kucica se ne salje: odsustvo = 0
	$clean{$_} = $in->{$_} ? 1 : 0 for @CHECKBOX;

	return (\%clean, \%err);
}

# ---------- Slim::Web::Settings ----------

sub name { return Slim::Web::HTTP::CSRF->protectName('PLUGIN_AUDIOCD') }

sub page { return Slim::Web::HTTP::CSRF->protectURI('plugins/AudioCD/settings/basic.html') }

sub prefs {
	return (Slim::Utils::Prefs::preferences('plugin.audiocd'), sort keys %Plugins::AudioCD::Config::DEFAULTS);
}

sub handler {
	my ($class, $client, $params, @rest) = @_;
	my $prefs = Slim::Utils::Prefs::preferences('plugin.audiocd');
	my %view = map { $_ => $prefs->get($_) } @SHOWN;

	if ($params->{saveSettings}) {
		my %in = map { $_ => $params->{"pref_$_"} } @SHOWN;
		my ($clean, $err) = validate(\%in, media => Slim::Utils::Misc::getMediaDirs('audio'));
		if (%$err) {
			%view = (%view, %in);    # prikazuje se ono sto je korisnik uneo
			$view{$_} = $in{$_} ? 1 : 0 for @CHECKBOX;
			$params->{warning} = join '<br/>', map { Slim::Utils::Strings::string($err->{$_}) } grep { $err->{$_} } @SHOWN;
			$params->{audiocdErrors} = $err;
		}
		else {
			$prefs->set($_, $clean->{$_}) for @SHOWN;
			%view = (%view, %$clean);
			$params->{warning} = Slim::Utils::Strings::string('PLUGIN_AUDIOCD_SET_SAVED');
		}
	}

	$params->{audiocd} = \%view;
	$params->{audiocdProfiles} = [ @Plugins::AudioCD::Profiles::NAMES ];
	$params->{audiocdRipsDefault} = Plugins::AudioCD::Config::default_rips_dir();

	# osnovni handler samo prikazuje: cuvanje je gore (bez saveSettings ne postavlja prefs iz forme)
	delete $params->{saveSettings};
	return $class->SUPER::handler($client, $params, @rest);
}

1;
