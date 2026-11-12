package Plugins::AudioCD::Config;

# Cist Perl, bez LMS-a: folder za rip-ove i podrazumevane vrednosti prefs-a.

use strict;
use warnings;
use utf8;

use constant AUDIOOS_CONF  => '/etc/audioos/audioos.conf';
use constant DEFAULTS_CONF => '/usr/local/lib/audioos/defaults.conf';
use constant FALLBACK_RIPS => '/var/lib/squeezeboxserver/CD-Rips';

our %DEFAULTS = (
	device               => '/dev/cdrom',
	profile              => 'balanced',
	flacLevel            => 5,
	quietDrive           => 0,
	quietSpeed           => 8,
	driveOffset          => '',
	autoLoad             => 1,
	autoRip              => 0,
	autoRipProfile       => 'balanced',
	ejectAfterRip        => 0,
	notify               => 1,
	polling              => 1,
	secureCache          => 0,
	libraryDir           => '',
	ripsDir              => '',
	noRipWhileLocalPlays => 0,
);

# Cita KEY=value fajl (shell stil). Nepostojeci fajl daje {}.
sub parse_env_file {
	my ($path) = @_;
	my %kv;
	return \%kv unless defined $path && open(my $fh, '<', $path);

	while (my $line = <$fh>) {
		$line =~ s/\r?\n\z//;
		$line =~ s/\A\s+//;
		next if $line eq '' || $line =~ /\A#/;
		$line =~ s/\Aexport\s+//;
		next unless $line =~ /\A([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/;
		my ($key, $val) = ($1, $2);

		if ($val =~ /\A"([^"]*)"/ || $val =~ /\A'([^']*)'/) {
			$val = $1;
		} else {
			$val =~ s/\s+#.*\z//;    # komentar na kraju linije
			$val =~ s/\s+\z//;
		}
		$kv{$key} = $val;
	}
	close $fh;
	return \%kv;
}

# audioos.conf > defaults.conf > ugradjeni podrazumevani.
sub default_rips_dir {
	my (%opt) = @_;
	my @files = (
		$opt{audioos_conf}  // AUDIOOS_CONF,
		$opt{defaults_conf} // DEFAULTS_CONF,
	);
	for my $file (@files) {
		my $val = parse_env_file($file)->{CD_RIPS_DIR};
		return $val if defined $val && length $val;
	}
	return FALLBACK_RIPS;
}

# Neprazan pref pobedjuje; inace podrazumevani.
sub rips_dir {
	my ($pref, %opt) = @_;
	return $pref if defined $pref && length $pref;
	return default_rips_dir(%opt);
}

1;
