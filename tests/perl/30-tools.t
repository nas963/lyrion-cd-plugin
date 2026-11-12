use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Tools') }

my $T = 'Plugins::AudioCD::Tools';
my $d = tempdir(CLEANUP => 1);

open my $f, '>', "$d/exe-tool" or die; close $f; chmod 0755, "$d/exe-tool";
open $f, '>', "$d/plain-tool" or die; close $f; chmod 0644, "$d/plain-tool";
mkdir "$d/dir-tool"; chmod 0755, "$d/dir-tool";

is($T->can('find')->('exe-tool', dirs => [$d]), "$d/exe-tool", 'nalazi izvrsni fajl');
is($T->can('find')->('plain-tool', dirs => [$d]), undef, 'preskace neizvrsni');
is($T->can('find')->('dir-tool', dirs => [$d]), undef, 'preskace direktorijum');
is($T->can('find')->('nema-ga', dirs => [$d]), undef, 'nepostojeci');
is($T->can('find')->('../x', dirs => [$d]), undef, 'ime sa / se odbija');

my $d2 = tempdir(CLEANUP => 1);
open $f, '>', "$d2/exe-tool" or die; close $f; chmod 0755, "$d2/exe-tool";
is($T->can('find')->('exe-tool', dirs => [$d2, $d]), "$d2/exe-tool", 'prvi direktorijum pobedjuje');

is($T->can('find')->('sh'), (grep { -x $_ } '/usr/bin/sh', '/bin/sh')[0], 'podrazumevano trazi /usr/bin pa /bin');
is_deeply([ $T->can('missing')->('sh', 'nema-ga-nikako-xyz') ], ['nema-ga-nikako-xyz'], 'missing vraca samo nedostajuce');

is_deeply(\%Plugins::AudioCD::Tools::PACKAGE, {
	cyanrip => 'cyanrip', 'cd-paranoia' => 'cd-paranoia', flac => 'flac',
	'cd-info' => 'libcdio-utils', eject => 'eject',
}, 'mapa paketa');

done_testing;
