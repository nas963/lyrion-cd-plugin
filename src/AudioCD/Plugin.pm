package Plugins::AudioCD::Plugin;

# Audio CD plugin: pocetni skelet, samo loguje verziju.

use strict;
use warnings;
use utf8;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::PluginManager;

our $VERSION = '0.1.0';

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.audiocd',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_AUDIOCD',
});

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	$log->info("AudioCD $VERSION initialized");
	return;
}

sub getDisplayName { return 'PLUGIN_AUDIOCD' }

1;
