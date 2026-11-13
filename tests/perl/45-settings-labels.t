use strict;
use warnings;
use utf8;
use Test::More;
use File::Basename qw(dirname);
use JSON::PP ();

use lib dirname(__FILE__) . '/lib';
use LMSBoot;

my $dir  = 'lib/Plugins/AudioCD';
my $tpl  = "$dir/HTML/EN/plugins/AudioCD/settings/basic.html";
sub slurp { my ($f) = @_; open my $fh, '<:encoding(UTF-8)', $f or die "$f: $!"; local $/; return <$fh> }

my $html = slurp($tpl);
unlike($html, qr/\|\s*string\b/, 'sablon ne koristi spojeni "| string" obrazac');
unlike($html, qr/PLUGIN_AUDIOCD_UI_PROFILE_'/, 'sablon ne spaja naziv tokena profila');
like($html, qr/p\.label \| html/, 'sablon prikazuje p.label');

# handler daje neprazne nazive za sve profile (string() se podmece: vraca token => dokaz koji se trazi)
my $code = q{
	require JSON::PP; require Plugins::AudioCD::Settings;
	no warnings 'redefine';
	local *Slim::Utils::Strings::string = sub { "L:$_[0]" };
	local *Slim::Utils::Strings::clientString = sub { "C:$_[1]" };
	my $o = Plugins::AudioCD::Settings::profile_options(undef);
	my $c = Plugins::AudioCD::Settings::profile_options(bless {}, 'X');
	print JSON::PP->new->canonical->encode({ names => [@Plugins::AudioCD::Profiles::NAMES], srv => $o, cli => $c });
};
my $out = LMSBoot::run($code);
my $r = eval { JSON::PP->new->decode($out) };
ok($r, 'profile_options se izvrsava') or diag $out;
$r ||= { names => [], srv => [], cli => [] };
is(scalar @{ $r->{srv} }, scalar @{ $r->{names} }, 'po jedna opcija za svaki profil');
ok(scalar @{ $r->{names} } >= 3, 'profila ima');

my $strings = slurp("$dir/strings.txt");
for my $i (0 .. $#{ $r->{srv} }) {
	my $o = $r->{srv}[$i];
	is($o->{value}, $r->{names}[$i], "vrednost: $o->{value}");
	like($o->{label}, qr/^L:PLUGIN_AUDIOCD_UI_PROFILE_[A-Z]+$/, "naziv trazi token ($o->{value})");
	(my $tok = $o->{label}) =~ s/^L://;
	like($strings, qr/^\Q$tok\E\n\tEN\t\S/m, "token $tok ima EN tekst u strings.txt");
	is($r->{cli}[$i]{label}, "C:$tok", "jezik klijenta se koristi kad klijent postoji");
}
done_testing;
