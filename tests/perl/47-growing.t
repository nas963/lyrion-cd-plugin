use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Basename qw(dirname);
use JSON::PP ();

use lib dirname(__FILE__) . '/lib';
use LMSBoot;

# Citanje fajla koji raste (ProtocolHandler::Growing) sa pravim Slim::Player::Protocols::File.
my $dir = tempdir(CLEANUP => 1);
my $code = q{
	require JSON::PP; require Plugins::AudioCD::ProtocolHandler;
	my ($dir) = @ARGV;
	package FTrack; sub new { bless {%{$_[1]}}, $_[0] } sub url { $_[0]{url} } sub audio_size { $_[0]{size} } sub secs { 60 }
	sub AUTOLOAD { our $AUTOLOAD; return undef }
	package FSong; sub new { bless {%{$_[1]}}, $_[0] }
	sub currentTrack { $_[0]{track} }
	sub can { my ($s, $m) = @_; return $s->UNIVERSAL::can($m) }
	for my $m (qw(seekdata samplerate samplesize channels totalbytes duration offset blockalign streamLength stripHeader initialAudioBlock _canSeek startOffset)) {
		no strict 'refs'; *{"FSong::$m"} = sub { my $s = shift; if (@_) { $s->{$m} = $_[0] } $s->{$m} };
	}
	package FClient; sub new { bless {}, $_[0] } sub songBytes { }
	package FCache; sub new { bless {%{$_[1]}}, $_[0] }
	sub path { $_[0]{path} } sub growing { $_[0]{rec} }
	package main;
	no warnings 'redefine';
	*Slim::Music::Info::contentType = sub { 'flc' };
	my $filled = 0;
	*Plugins::AudioCD::ProtocolHandler::_fill_track = sub { $filled++; $_[1]{size} = 14 };
	my $url = 'audiocd://dBFBpdDGyUnu4ofAwN5ZrxozKwM-/1';
	my $part = "$dir/01.flac.part";
	my $app = sub { open my $fh, '>>', $part or die; print {$fh} $_[0]; close $fh };
	$app->('prvi');
	my $rec = { part => $part, state => 'part' };
	my $cache = FCache->new({ rec => $rec });
	Plugins::AudioCD::ProtocolHandler->set_cache($cache);
	my $song = FSong->new({ track => FTrack->new({ url => $url }), _canSeek => 0 });
	my $fh = Plugins::AudioCD::ProtocolHandler->new({ song => $song, client => FClient->new, transcoder => { streamformat => 'flc' } });
	my %o = (class => ref $fh, seek_grow => Plugins::AudioCD::ProtocolHandler->canSeek(undef, $song),
		data_grow => Plugins::AudioCD::ProtocolHandler->getSeekData(undef, $song, 100));
	my $rd = sub { my $b = ''; my $n = $fh->sysread($b, 100); return [ $n, $b, defined $n ? 0 : ($!{EINTR} ? 'EINTR' : "$!") ] };
	$o{r1} = $rd->(); $o{r2} = $rd->();
	$app->('drugi');
	$o{r3} = $rd->();
	$app->('kraj!');
	rename $part, "$dir/01.flac" or die;
	$rec->{state} = 'done'; $cache->{path} = "$dir/01.flac";
	$o{r4} = $rd->(); $o{r5} = $rd->();
	$o{canseek} = $song->{_canSeek};
	$o{data_done} = Plugins::AudioCD::ProtocolHandler->getSeekData(undef, $song, 100);
	$o{len} = $song->{streamLength};
	my $fh2 = Plugins::AudioCD::ProtocolHandler->new({ song => $song, client => FClient->new, transcoder => { streamformat => 'flc' } });
	$o{class2} = ref $fh2; $o{filled} = $filled;
	print JSON::PP->new->canonical->encode(\%o);
};
my $out = LMSBoot::run($code, $dir);
my ($json) = $out =~ /(\{.*\})/s;
my $r = eval { JSON::PP->new->decode($json // '') };
ok($r, 'izvrsava se u LMS okruzenju') or diag $out;
$r ||= {};
is($r->{class}, 'Plugins::AudioCD::ProtocolHandler::Growing', 'pesma u izvlacenju: Growing');
is($r->{seek_grow}, 0, 'dok raste nema premotavanja');
is($r->{data_grow}, undef, 'dok raste nema ni seekdata (CLI time)');
is_deeply($r->{r1}, [ 4, 'prvi', 0 ], 'cita sto postoji');
is_deeply($r->{r2}, [ undef, '', 'EINTR' ], 'kraj rastuceg fajla: EINTR, ne kraj pesme');
is_deeply($r->{r3}, [ 5, 'drugi', 0 ], 'nastavlja kad fajl poraste');
is_deeply($r->{r4}, [ 5, 'kraj!', 0 ], 'posle preimenovanja cita ostatak');
is_deeply($r->{r5}, [ 0, '', 0 ], 'gotova pesma: kraj');
is($r->{canseek}, undef, 'zapamcen odgovor o premotavanju je ponisten');
is_deeply($r->{data_done}, { timeOffset => 100 }, 'ucitana pesma ima seekdata');
is($r->{len}, undef, 'streamLength nepoznat');
is($r->{class2}, 'Plugins::AudioCD::ProtocolHandler', 'gotova pesma (premotavanje): obican fajl');
is($r->{filled}, 1, 'podaci o gotovom fajlu se popunjavaju pre otvaranja');

done_testing;
