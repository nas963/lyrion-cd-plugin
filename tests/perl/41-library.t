use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp ();
use File::Path ();
use POSIX ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Library') }

my $L = 'Plugins::AudioCD::Library';
binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my $root = File::Temp::tempdir('library-XXXXXX', DIR => '.', CLEANUP => 1);
sub fs { Plugins::AudioCD::Naming::fs_bytes($_[0]) }
sub mkalbum {
	my ($rips, $rel) = @_;
	File::Path::make_path(fs("$rips/$rel/sub"));
	for my $f ("01.flac", "02.flac", "sub/cover.jpg") {
		open my $fh, '>:raw', fs("$rips/$rel/$f") or die $!;
		print {$fh} 'x' x (100 + length $f);
		close $fh;
	}
}
sub exists_p { -e fs($_[0]) ? 1 : 0 }

my $rips = "$root/rips";
my $lib  = "$root/lib";
File::Path::make_path($rips, $lib);
mkalbum($rips, 'Đorđe Balašević/Album Č');
my $src = "$rips/Đorđe Balašević/Album Č";

# plan_move
my ($dest, $err) = $L->can('plan_move')->($src, $lib, $rips);
is $dest, "$lib/Đorđe Balašević/Album Č", 'plan: odrediste preslikano';
is $err, undef, 'plan: bez greske';
(undef, $err) = $L->can('plan_move')->("$rips/../etc", $lib, $rips);
is $err, 'outside_rips', 'plan: ../ van rips-a';
(undef, $err) = $L->can('plan_move')->("$root/other/A", $lib, $rips);
is $err, 'outside_rips', 'plan: van rips-a';
(undef, $err) = $L->can('plan_move')->($rips, $lib, $rips);
is $err, 'outside_rips', 'plan: sam rips koren';
(undef, $err) = $L->can('plan_move')->("$rips/Nema/Album", $lib, $rips);
is $err, 'not_found', 'plan: izvor ne postoji';
File::Path::make_path(fs("$lib/Đorđe Balašević/Album Č"));
(undef, $err) = $L->can('plan_move')->($src, $lib, $rips);
is $err, 'exists', 'plan: odrediste postoji';
File::Path::remove_tree(fs("$lib/Đorđe Balašević"));

# move na istom FS: jedan rename
my @calls;
my ($ok, $merr) = $L->can('move')->($src, $dest, rename => sub { push @calls, [@_]; CORE::rename($_[0], $_[1]) });
ok $ok, 'move: uspeh' or diag $merr;
is scalar(@calls), 1, 'move: jedan rename';
ok exists_p("$dest/01.flac") && exists_p("$dest/sub/cover.jpg"), 'move: sadrzaj na odredistu';
ok !exists_p($src), 'move: izvor nestao';

# EXDEV bez spawn-a: sinhroni move ne kopira (za to je move_async)
mkalbum($rips, 'Artist/Album');
my $s2 = "$rips/Artist/Album";
($ok, $merr) = $L->can('move')->($s2, "$lib/Artist/Album", rename => sub { $! = POSIX::EXDEV(); return 0 });
ok !$ok && $merr eq 'move_failed', 'sync exdev: move_failed';
ok exists_p("$s2/01.flac") && !exists_p("$lib/Artist"), 'sync exdev: izvor ostao, bez praznog roditelja';

# odrediste postoji: exists, nista se ne menja
File::Path::make_path(fs("$lib/Ex/Album"));
open my $fh, '>:raw', fs("$lib/Ex/Album/keep.txt") or die $!; print {$fh} 'k'; close $fh;
mkalbum($rips, 'Ex/Album');
($ok, $merr) = $L->can('move')->("$rips/Ex/Album", "$lib/Ex/Album");
ok !$ok, 'exists: neuspeh';
is $merr, 'exists', 'exists: kod';
ok exists_p("$rips/Ex/Album/01.flac") && exists_p("$lib/Ex/Album/keep.txt") && !exists_p("$lib/Ex/Album/01.flac"), 'exists: nista promenjeno';

# druga greska rename-a: izvor ostaje, nema praznih roditelja
mkalbum($rips, 'Perm/Album');
($ok, $merr) = $L->can('move')->("$rips/Perm/Album", "$lib/Perm/Album", rename => sub { $! = POSIX::EACCES(); return 0 });
is $merr, 'move_failed', 'eacces: move_failed';
ok exists_p("$rips/Perm/Album/01.flac") && !exists_p("$lib/Perm"), 'eacces: izvor ostao, bez praznog roditelja';

# move_async: isti FS = odmah rename, bez spawn-a
my @res;
my $exdev = sub { $! = POSIX::EXDEV(); 0 };
my $cb = sub { push @res, [@_] };
sub parts { opendir my $dh, fs("$lib/As") or return (); return grep { /\.part-/ } readdir $dh }
mkalbum($rips, 'As/One');
$L->can('move_async')->("$rips/As/One", "$lib/As/One", spawn => sub { fail 'spawn ne treba' }, on_done => $cb);
is_deeply \@res, [[1, undef]], 'async: isti FS, odmah gotovo';
ok exists_p("$lib/As/One/01.flac") && !exists_p("$rips/As/One"), 'async: premesteno';

# EXDEV: cp -a u .part, provera, rename, brisanje izvora
my @argv;
my $fake = sub { my ($a, $c) = @_; push @argv, [@$a]; $c->(system(@$a) >> 8) };
mkalbum($rips, 'As/Two');
@res = ();
$L->can('move_async')->("$rips/As/Two", "$lib/As/Two", rename => $exdev, spawn => $fake, on_done => $cb);
is_deeply \@res, [[1, undef]], 'async exdev: gotovo';
is_deeply [ @{ $argv[0] }[0 .. 2] ], [ 'cp', '-a', '--' ], 'async exdev: cp -a';
like $argv[0][4], qr{/\.Two\.part-\d+-\d+\z}, 'async exdev: cp u skriven .part';
ok exists_p("$lib/As/Two/sub/cover.jpg") && !exists_p("$rips/As/Two"), 'async exdev: kopija, izvor obrisan';
is_deeply [ parts() ], [], 'async exdev: nema .part ostataka';

# cp pada: delimicna kopija obrisana, izvor ostaje
mkalbum($rips, 'As/Three');
@res = ();
my $failing = sub { my ($a, $c) = @_; mkdir fs($a->[-1]); $c->(1) };
$L->can('move_async')->("$rips/As/Three", "$lib/As/Three", rename => $exdev, spawn => $failing, on_done => $cb);
is_deeply \@res, [[undef, 'copy_failed']], 'async fail: copy_failed';
ok exists_p("$rips/As/Three/01.flac") && !exists_p("$lib/As/Three"), 'async fail: izvor ostao';
is_deeply [ parts() ], [], 'async fail: nema .part ostataka';

# cp "uspe" ali velicine ne odgovaraju
mkalbum($rips, 'As/Four');
@res = ();
my $short = sub { my ($a, $c) = @_; mkdir fs($a->[-1]); $c->(0) };
$L->can('move_async')->("$rips/As/Four", "$lib/As/Four", rename => $exdev, spawn => $short, on_done => $cb);
is_deeply \@res, [[undef, 'verify_failed']], 'async verify: verify_failed';
ok exists_p("$rips/As/Four/01.flac") && !exists_p("$lib/As/Four") && !parts(), 'async verify: izvor ostao, bez ostataka';

# odrediste postoji
@res = ();
$L->can('move_async')->("$rips/Ex/Album", "$lib/Ex/Album", on_done => $cb);
is_deeply \@res, [[undef, 'exists']], 'async: exists';


# odrediste se pojavi (prazan folder) tokom kopiranja: rename bi ga tiho zamenio -> 'exists'
{
	mkalbum($rips, 'Race/Album');
	@res = ();
	my $racing = sub { my ($a, $c) = @_; mkdir fs("$lib/Race/Album"); $c->(system(@$a) >> 8) };
	$L->can('move_async')->("$rips/Race/Album", "$lib/Race/Album", rename => $exdev, spawn => $racing, on_done => $cb);
	is_deeply \@res, [[undef, 'exists']], 'race: exists';
	ok exists_p("$rips/Race/Album/01.flac"), 'race: izvor ostao';
	ok -d fs("$lib/Race/Album") && !exists_p("$lib/Race/Album/01.flac"), 'race: tudji folder netaknut';
	is_deeply [ grep { /part/ } do { opendir my $dh, fs("$lib/Race"); readdir $dh } ], [], 'race: .part obrisan';
}

# .part je skriven i jedinstven; stari ostaci se brisu, aktivan se ne dira; guard po odredistu
{
	my $p1 = $L->can('part_path')->("$lib/Sw/Album");
	my $p2 = $L->can('part_path')->("$lib/Sw/Album");
	like $p1, qr{\A\Q$lib\E/Sw/\.Album\.part-\d+-\d+\z}, 'part_path: skriveno ime';
	isnt $p1, $p2, 'part_path: jedinstveno';

	File::Path::make_path(fs("$lib/Sw/.Old.part-1-1"));
	open my $o, '>:raw', fs("$lib/Sw/.Old.part-1-1/x") or die $!; close $o;
	mkalbum($rips, 'Sw/Album');
	mkalbum($rips, 'Sw/Other');
	@res = ();
	my (@busy, $active_seen, $part_seen);
	my $spawn = sub {
		my ($a, $c) = @_;
		$L->can('move_async')->("$rips/Sw/Album", "$lib/Sw/Album", on_done => sub { push @busy, [@_] });
		$part_seen = $a->[-1];
		# drugi premestaj u isti roditelj pokrece sweep dok je nas .part u toku
		$L->can('move_async')->("$rips/Sw/Other", "$lib/Sw/Other");
		$active_seen = -d fs($a->[-1]) ? 0 : 1;
		$c->(system(@$a) >> 8);
	};
	# .part mora da postoji pre sweep-a drugog premestaja: napravimo ga u spawn-u pre cp
	my $spawn2 = sub { my ($a, $c) = @_; mkdir fs($a->[-1]); $spawn->($a, sub { }); File::Path::remove_tree(fs($a->[-1])); $c->(system(@$a) >> 8) };
	$L->can('move_async')->("$rips/Sw/Album", "$lib/Sw/Album", rename => $exdev, spawn => $spawn2, on_done => $cb);
	is_deeply \@busy, [[undef, 'busy']], 'guard: drugi premestaj istog odredista -> busy';
	like $part_seen, qr{/\.Album\.part-\d+-\d+\z}, 'async: cp pise u skriven .part';
	is $active_seen, 0, 'sweep: aktivan .part nije obrisan';
	ok !exists_p("$lib/Sw/.Old.part-1-1"), 'sweep: stari ostatak obrisan';
	is_deeply \@res, [[1, undef]], 'guard: prvi premestaj uspeo';
	ok exists_p("$lib/Sw/Album/01.flac"), 'guard: sadrzaj na odredistu';
}

# izvor se ne moze obrisati posle provere kopije: uspeh sa upozorenjem
SKIP: {
	skip 'root brise sve', 3 if $> == 0;
	mkalbum($rips, 'Sn/Album');
	@res = ();
	my $lock = sub { my ($a, $c) = @_; my $r = system(@$a) >> 8; chmod 0555, fs("$rips/Sn"); $c->($r) };
	$L->can('move_async')->("$rips/Sn/Album", "$lib/Sn/Album", rename => $exdev, spawn => $lock, on_done => $cb);
	chmod 0755, fs("$rips/Sn");
	is_deeply \@res, [[1, undef, 'source_not_removed']], 'warn: uspeh sa upozorenjem';
	ok exists_p("$lib/Sn/Album/01.flac"), 'warn: kopija na odredistu';
	File::Path::remove_tree(fs("$rips/Sn"));
}

# prazan folder izvodjaca u rips-u se uklanja; neprazan i koren ne
{
	mkalbum($rips, 'Pr/One');
	mkalbum($rips, 'Pr/Two');
	$L->can('move')->("$rips/Pr/One", "$lib/Pr/One", rips_root => $rips);
	ok -d fs("$rips/Pr"), 'prune: izvodjac sa drugim albumom ostaje';
	$L->can('move')->("$rips/Pr/Two", "$lib/Pr/Two", rips_root => $rips);
	ok !-e fs("$rips/Pr"), 'prune: prazan izvodjac uklonjen';
	ok -d fs($rips), 'prune: koren ostaje';
}

# izuzetak u on_done ne menja ishod premestanja
{
	mkalbum($rips, 'Ex2/Album');
	my @w;
	local $SIG{__WARN__} = sub { push @w, @_ };
	my @r = $L->can('move')->("$rips/Ex2/Album", "$lib/Ex2/Album");
	ok $r[0], 'sync move uspeo';
	@w = ();
	mkalbum($rips, 'Ex3/Album');
	$L->can('move_async')->("$rips/Ex3", "$lib/Ex3x", on_done => sub { die "boom\n" });
	ok exists_p("$lib/Ex3x/Album/01.flac"), 'on_done izuzetak: premestaj ostaje';
	like $w[0] // '', qr/boom/, 'on_done izuzetak: zabelezen';
}

# Ripper::update_path: istorija pokazuje na novu putanju (i posle ponovnog ucitavanja)
{
	require Plugins::AudioCD::Ripper;
	my $hf = "$root/history.json";
	open my $h, '>:raw', $hf or die $!;
	print {$h} '[{"id":"r1","path":"/old/A","result":"ok"},{"id":"r2","path":"/old/B","result":"ok"}]';
	close $h;
	my $r = Plugins::AudioCD::Ripper->new(history_file => $hf);
	is $r->update_path('r2', '/new/B'), 1, 'update_path: nadjen';
	is $r->update_path('nema', '/x'), 0, 'update_path: nepoznat id';
	my $r2 = Plugins::AudioCD::Ripper->new(history_file => $hf);
	is_deeply [ map { $_->{path} } @{ $r2->history } ], [ '/old/A', '/new/B' ], 'update_path: sacuvano';
	is_deeply [ map { $_->{moved} ? 1 : 0 } @{ $r2->history } ], [ 0, 1 ], 'update_path: moved=1 samo premestenom unosu, sacuvano';
}

# rescan_cmd
is_deeply $L->can('rescan_cmd')->('/mnt/m/CD/Đ B/Album #1'),
	[ 'rescan', 'full', 'file:///mnt/m/CD/%C4%90%20B/Album%20%231' ], 'rescan_cmd: file URL';

# library_dir: folder biblioteke iz zahteva / prefs-a / prvog muzickog foldera, samo ispod muzickih foldera
{
	my $f = $L->can('library_dir');
	my $media = [ '/mnt/m/Muzika/', '/srv/music' ];
	is_deeply [ $f->(undef, undef, $media) ], [ '/mnt/m/Muzika', undef ], 'library_dir: podrazumevano prvi muzicki folder';
	is_deeply [ $f->('', '/srv/music/CD', $media) ], [ '/srv/music/CD', undef ], 'library_dir: iz prefs-a';
	is_deeply [ $f->('/mnt/m/Muzika/CD/', 'x', $media) ], [ '/mnt/m/Muzika/CD', undef ], 'library_dir: iz zahteva, bez / na kraju';
	is_deeply [ $f->('/mnt/m/Muzika/../etc', undef, $media) ], [ undef, 'bad_args' ], 'library_dir: .. odbijen';
	is_deeply [ $f->('/mnt/m/Muzika/CD/..', undef, $media) ], [ undef, 'bad_args' ], 'library_dir: .. na kraju odbijen';
	is_deeply [ $f->('relativno/CD', undef, $media) ], [ undef, 'bad_args' ], 'library_dir: relativna putanja odbijena';
	is_deeply [ $f->('/mnt/m/MuzikaX', undef, $media) ], [ undef, 'outside_library' ], 'library_dir: slican prefiks nije ispod';
	is_deeply [ $f->('/etc', undef, $media) ], [ undef, 'outside_library' ], 'library_dir: van muzickih foldera';
	is_deeply [ $f->(undef, undef, []) ], [ undef, 'bad_args' ], 'library_dir: nema muzickih foldera';
}

done_testing;
