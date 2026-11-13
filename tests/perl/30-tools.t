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

# df_free: df bez shell-a, sa rokom (mrtav mrezni mount ne sme da zaustavi LMS)
{
	my $df_free = $T->can('df_free');
	ok($df_free, 'df_free postoji') or BAIL_OUT('nema df_free');
	my $free = $df_free->('.');
	ok(defined $free && $free > 0, 'df_free za . vraca bajtove') or diag explain $free;
	is($df_free->("$d/nema/takvog"), undef, 'nepostojeci folder: undef');

	open my $s, '>', "$d/slow-df" or die;
	print {$s} "#!/bin/sh\nexec sleep 20\n";
	close $s;
	chmod 0755, "$d/slow-df";
	my $t0 = time;
	is($df_free->('.', df => "$d/slow-df", timeout => 1), undef, 'spor df: undef (nepoznato)');
	ok(time - $t0 <= 4, 'spor df: rok se postuje (' . (time - $t0) . ' s)');

	open $s, '>', "$d/fake-df" or die;
	print {$s} "#!/bin/sh\necho 'Filesystem 1024-blocks Used Available Capacity Mounted on'\necho \"tmpfs 1000 10 777 1% \$2\"\n";
	close $s;
	chmod 0755, "$d/fake-df";
	is($df_free->('/x', df => "$d/fake-df"), 777 * 1024, 'df -Pk: kolona Available * 1024');
}

is_deeply(\%Plugins::AudioCD::Tools::PACKAGE, {
	cyanrip => 'cyanrip', 'cd-paranoia' => 'cd-paranoia', flac => 'flac',
	'cd-info' => 'libcdio-utils', eject => 'eject',
}, 'mapa paketa');

done_testing;
