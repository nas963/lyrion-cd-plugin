use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp ();
use File::Path ();
use JSON::PP ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Ripper') }

my $R = 'Plugins::AudioCD::Ripper';

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my $root = File::Temp::tempdir('ripper-XXXXXX', DIR => '.', CLEANUP => 1);
my $n = 0;
sub fresh_rips { my $d = "$root/rips" . ++$n; File::Path::make_path($d); return $d }

sub slurp { open my $fh, '<:raw', $_[0] or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub mode_of { sprintf '%04o', (stat $_[0])[2] & 07777 }
sub ls { opendir my $d, $_[0] or return (); my @f = sort grep { !/^\.\.?\z/ } readdir $d; closedir $d; @f }

# TOC sa 3 pesme: 100 s + 200 s + 300 s (75 frejmova/s)
my $toc = { first => 1, last => 3, leadout => 600 * 75,
    tracks => [ { n => 1, lba => 0, data => 0 }, { n => 2, lba => 100 * 75, data => 0 }, { n => 3, lba => 300 * 75, data => 0 } ] };

sub mkdisc {
    my (%o) = @_;
    return {
        discid => $o{discid} // 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-',
        artist => $o{artist} // 'Izvođač', album => $o{album} // 'Album',
        disc_number => $o{disc_number} // 1, disc_total => $o{disc_total} // 1,
        tracks => [ map { { n => $_, title => "Naslov $_" } } 1 .. 3 ],
    };
}

# ---- needed_bytes ----
is($R->can('needed_bytes')->($toc), int(600 * 176400 * 0.7) + 50 * 1024 * 1024, 'needed_bytes');

# ---- lazni spawn ----
my @SPAWNS;       # { argv, on_line, on_exit, dir, killed }
my $AUTO;         # undef = rucno, inace sub($sp) koji se poziva odmah
my $fake = sub {
    my (%a) = @_;
    my @argv = @{ $a{argv} };
    my ($i) = grep { $argv[$_] eq '-D' } 0 .. $#argv;
    my $sp = { %a, dir => $argv[$i + 1], killed => 0 };
    push @SPAWNS, $sp;
    $sp->{job} = bless $sp, 'FakeJob';
    $AUTO->($sp) if $AUTO;
    return $sp;
};
{
    package FakeJob;
    sub kill { my ($s) = @_; $s->{killed}++; $s->{on_exit}->(143) if $s->{kill_exits} }
}

sub write_rip {
    my ($sp, %o) = @_;
    my $d = $sp->{dir};
    for my $t (1 .. 3) {
        next if $o{skip} && $o{skip} == $t;
        open my $fh, '>', "$d/$t.flac" or die; print {$fh} "flac$t"; close $fh;
        chmod 0664, "$d/$t.flac";
    }
    open my $l, '>:utf8', "$d/Albumˑ.log" or die;
    print {$l} "Tracks to rip:  all\nDisc tracks:    3\nTrack 1 ripped and encoded successfully!\nTrack 2 ripped and encoded successfully!\nTrack 3 ripped and encoded successfully!\nTracks ripped accurately: 2/3\n";
    close $l;
    open my $c, '>:utf8', "$d/Albumˑ.cue" or die;
    print {$c} qq{TITLE "Album"\nFILE "1.flac" WAVE\n  TRACK 01 AUDIO\nFILE "2.flac" WAVE\n  TRACK 02 AUDIO\nFILE "3.flac" WAVE\n  TRACK 03 AUDIO\n};
    close $c;
    chmod 0700, $d;
}

my $big_df = sub { 10 * 1024**3 };
my @CHANGES;
sub mk {
    my (%o) = @_;
    return $R->new(spawn => $fake, df => $big_df, history_file => $o{hist}, on_change => sub { push @CHANGES, 1 }, cyanrip => 'cyanrip');
}

# ---- uspesan rip ----
{
    my $rips = fresh_rips();
    my $cover = "$root/cov.jpg";
    open my $cf, '>', $cover; print {$cf} 'jpg'; close $cf;
    @SPAWNS = ();
    $AUTO = sub {
        my ($sp) = @_;
        write_rip($sp);
        $sp->{on_line}->("Ripping and encoding track 1, progress - 50.00%, ETA - 12s");
        $sp->{on_line}->("Track 1 ripped and encoded successfully!");
        $sp->{on_line}->("Accurip v1:  AAAA (not found, x)");
        $sp->{on_line}->("Accurip v2:  AAAA (accurately ripped, confidence 5)");
        $sp->{on_line}->("Track 2 ripped and encoded successfully!");
        $sp->{on_line}->("Accurip v2:  BBBB (accurately ripped, confidence 5)");
        $sp->{on_line}->("Track 3 ripped and encoded successfully!");
        $sp->{on_exit}->(0);
    };
    my $r = mk();
    my ($id, $err) = $r->enqueue(disc => mkdisc(), toc => $toc, device => '/dev/cdrom', profile => 'secure', flac_level => 5,
        rips_dir => $rips, quiet_speed => 4, offset => 6, eject_after => 1, cover_src => $cover);
    ok($id && !$err, 'enqueue vraca id') or diag explain $err;
    is(scalar @SPAWNS, 1, 'jedan spawn');
    my $argv = join ' ', @{ $SPAWNS[0]{argv} };
    like($argv, qr{-D \Q$rips\E/\.audiocd-tmp/\Q$id\E }, 'cyanrip u tmp folder');
    like($argv, qr/-S 4/, 'quiet_speed');
    like($argv, qr/-s 6/, 'offset');
    like($argv, qr/-C Front=\S+cover\.jpg/, 'cover prosledjen');
    like($argv, qr/ -Q\z/, 'eject_after dodaje -Q');
    is($SPAWNS[0]{umask}, 022, 'umask 022');

    my $dir = "$rips/Izvođač/Album";
    ok(-d $dir, 'folder albuma') or diag join ',', ls($rips);
    is_deeply([ ls($dir) ], [ '01 - Naslov 1.flac', '02 - Naslov 2.flac', '03 - Naslov 3.flac', 'Album.cue', 'Album.log', 'cover.jpg' ], 'fajlovi u albumu');
    is(mode_of("$dir/01 - Naslov 1.flac"), '0644', 'fajl 0644');
    is(mode_of("$dir/Album.log"), '0644', 'log 0644');
    is(mode_of($dir), '0755', 'folder albuma 0755');
    is(mode_of("$rips/Izvođač"), '0755', 'folder izvodjaca 0755');
    my $cue = slurp("$dir/Album.cue");
    like($cue, qr/FILE "01 - Naslov 1\.flac" WAVE/, 'cue FILE 1 prepravljen');
    like($cue, qr/FILE "03 - Naslov 3\.flac" WAVE/, 'cue FILE 3 prepravljen');
    unlike($cue, qr/FILE "\d\.flac"/, 'nema starih imena u cue');
    is_deeply([ ls("$rips/.audiocd-tmp") ], [], 'tmp folder obrisan');

    my $h = $r->history;
    is(scalar @$h, 1, 'jedan unos istorije');
    is($h->[0]{result}, 'ok', 'result ok');
    is($h->[0]{path}, $dir, 'path');
    is($h->[0]{discid}, 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-', 'discid');
    is($h->[0]{album}, 'Album', 'album');
    is($h->[0]{profile}, 'secure', 'profile');
    is($h->[0]{accurip}{state}, 'match', 'accurip state');
    is_deeply($h->[0]{accurip}{tracks}, { 1 => 'match', 2 => 'match' }, 'accurip po pesmama');
    is($h->[0]{accurip}{ok}, 2, 'accurip ok iz loga');
    is($h->[0]{accurip}{total}, 3, 'accurip total iz loga');
    ok(!$r->busy, 'nije zauzet');
    is($r->status->{current}, undef, 'nema tekuceg');
}

# ---- postojeci Album -> Album (2); vise diskova ----
{
    my $rips = fresh_rips();
    File::Path::make_path("$rips/Izvođač/Album");
    @SPAWNS = ();
    $AUTO = sub { write_rip($_[0]); $_[0]{on_exit}->(0) };
    my $r = mk();
    $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    ok(-f "$rips/Izvođač/Album (2)/01 - Naslov 1.flac", 'postojeci folder -> Album (2)');
    is_deeply([ ls("$rips/Izvođač/Album") ], [], 'stari folder netaknut');
    is($r->history->[0]{path}, "$rips/Izvođač/Album (2)", 'path sa (2)');

    my $r2 = mk();
    $r2->enqueue(disc => mkdisc(album => 'Dupli', disc_number => 2, disc_total => 2, discid => 'x' x 28), toc => $toc, rips_dir => $rips);
    ok(-f "$rips/Izvođač/Dupli/Disc 2/01 - Naslov 1.flac", 'vise diskova: Disc 2 podfolder');
    is(mode_of("$rips/Izvođač/Dupli/Disc 2"), '0755', 'podfolder 0755');
}

# ---- accurip mismatch / notfound ----
{
    my $rips = fresh_rips();
    $AUTO = sub {
        my ($sp) = @_;
        write_rip($sp);
        $sp->{on_line}->("Track 1 ripped and encoded successfully!");
        $sp->{on_line}->("Accurip v2:  AAAA (not found, x)");
        $sp->{on_exit}->(0);
    };
    my $r = mk();
    $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    is($r->history->[0]{result}, 'accurip_mismatch', 'mismatch -> accurip_mismatch');
    is($r->history->[0]{accurip}{tracks}{1}, 'mismatch', 'mismatch pesma 1');

    my $rips2 = fresh_rips();
    $AUTO = sub {
        my ($sp) = @_;
        write_rip($sp);
        $sp->{on_line}->("Track 3 ripped and encoded successfully!");
        $sp->{on_line}->("Accurip:  disc not found in database");
        $sp->{on_exit}->(0);
    };
    my $r2 = mk();
    $r2->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips2);
    is($r2->history->[0]{result}, 'ok', 'notfound -> ok');
    is($r2->history->[0]{accurip}{state}, 'notfound', 'notfound zabelezen');
}

# ---- nema mesta ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = undef;
    my $r = $R->new(spawn => $fake, df => sub { 1000 });
    my ($id, $err) = $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    is($id, undef, 'no_space: nema id');
    is($err->{error}, 'no_space', 'no_space greska');
    is($err->{free}, 1000, 'no_space free');
    is($err->{needed}, $R->can('needed_bytes')->($toc), 'no_space needed');
    is(scalar @SPAWNS, 0, 'ništa se ne pokrece');
    ok(!$r->busy, 'nije zauzet');
    is_deeply([ ls($rips) ], [], 'nista nije napravljeno u rips');
}

# ---- red: drugi ceka ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = undef;
    my $r = mk();
    my ($a) = $r->enqueue(disc => mkdisc(discid => 'a' x 28, album => 'A1'), toc => $toc, rips_dir => $rips);
    my ($b, $e) = $r->enqueue(disc => mkdisc(discid => 'b' x 28, album => 'A2'), toc => $toc, rips_dir => $rips);
    ok($b && !$e, 'drugi enqueue prihvacen');
    is(scalar @SPAWNS, 1, 'samo prvi radi');
    ok($r->busy, 'zauzet');
    my $st = $r->status;
    is($st->{current}{id}, $a, 'status current');
    is($st->{current}{state}, 'ripping', 'state ripping');
    is(scalar @{ $st->{queue} }, 1, 'jedan u redu');
    is($st->{queue}[0]{id}, $b, 'u redu je drugi');

    my (undef, $dup) = $r->enqueue(disc => mkdisc(discid => 'b' x 28), toc => $toc, rips_dir => $rips);
    is($dup->{error}, 'busy_disc', 'isti disk dvaput odbijen');

    # napredak
    $SPAWNS[0]{on_line}->("Ripping and encoding track 1, progress - 50.00%, ETA - 12s");
    $st = $r->status;
    is($st->{current}{track}, 1, 'track');
    is($st->{current}{track_percent}, 50, 'track_percent');
    is($st->{current}{percent}, 16, 'percent (1/3 * 50%)');
    $SPAWNS[0]{on_line}->("Track 1 ripped and encoded successfully!");
    is($r->status->{current}{percent}, 33, 'percent posle prve pesme');

    write_rip($SPAWNS[0]);
    $SPAWNS[0]{on_exit}->(0);
    is(scalar @SPAWNS, 2, 'drugi krece posle prvog');
    is($r->status->{current}{id}, $b, 'sada drugi tece');
    is(scalar @{ $r->status->{queue} }, 0, 'red prazan');
    $AUTO = sub { write_rip($_[0]); $_[0]{on_exit}->(0) };
    write_rip($SPAWNS[1]);
    $SPAWNS[1]{on_exit}->(0);
    ok(!$r->busy, 'sve gotovo');
    is_deeply([ map { $_->{result} } @{ $r->history } ], [ 'ok', 'ok' ], 'oba u istoriji');
    is($r->history->[0]{album}, 'A2', 'najnoviji prvi');
}

# ---- cancel tekuceg / reda ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = sub { $_[0]{kill_exits} = 1; mkdir "$_[0]{dir}/x" ; write_rip($_[0]) };
    my $r = mk();
    my ($a) = $r->enqueue(disc => mkdisc(discid => 'a' x 28), toc => $toc, rips_dir => $rips);
    my ($b) = $r->enqueue(disc => mkdisc(discid => 'b' x 28, album => 'B'), toc => $toc, rips_dir => $rips);
    ok(-d "$rips/.audiocd-tmp/$a", 'tmp postoji tokom rip-a');
    ok($r->cancel($b), 'cancel iz reda');
    is($r->history->[0]{result}, 'cancelled', 'otkazan iz reda u istoriji');
    is(scalar @{ $r->status->{queue} }, 0, 'red prazan');
    ok($r->cancel($a), 'cancel tekuceg');
    is($SPAWNS[0]{killed}, 1, 'job ubijen');
    ok(!-e "$rips/.audiocd-tmp/$a", 'tmp obrisan');
    is($r->history->[0]{result}, 'cancelled', 'istorija cancelled');
    ok(!-e "$rips/Izvođač/Album", 'nema albuma');
    ok(!$r->busy, 'slobodan');
    ok(!$r->cancel('nepostoji'), 'nepoznat id');
}

# ---- cancel sa asinhronim izlazom ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = undef;
    my $r = mk();
    my ($a) = $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    write_rip($SPAWNS[0]);
    $r->cancel($a);
    is($r->status->{current}{state}, 'cancelling', 'state cancelling');
    ok($r->busy, 'zauzet dok proces ne izadje');
    $SPAWNS[0]{on_exit}->(0);    # utrka: zavrsio je uspesno posle cancel-a
    is($r->history->[0]{result}, 'cancelled', 'cancel pobedjuje i kad izlaz bude 0');
    ok(!-e "$rips/Izvođač", 'nista nije premesteno');
    ok(!-e "$rips/.audiocd-tmp/$a", 'tmp obrisan');
}

# ---- neASCII rips_dir: tmp, stage i odrediste ----
{
    my $rips = "$root/Ripovi ćšž";
    File::Path::make_path($rips);
    @SPAWNS = ();
    $AUTO = sub { write_rip($_[0]); $_[0]{on_exit}->(0) };
    my $r = mk();
    my ($id, $err) = $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    ok($id && !$err, 'neASCII rips_dir: enqueue') or diag explain $err;
    ok(!utf8::is_utf8($SPAWNS[0]{cwd}), 'cwd je bajtovi (ne karakter string)');
    like($SPAWNS[0]{cwd}, qr/\.audiocd-tmp\//, 'cwd u tmp folderu');
    is($r->history->[0]{result}, 'ok', 'neASCII: result ok') or diag explain $r->history->[0];
    ok(-f "$rips/Izvođač/Album/01 - Naslov 1.flac", 'neASCII: fajl na odredistu');
    ok(-f "$rips/Izvođač/Album/Album.cue", 'neASCII: cue na odredistu');
    is_deeply([ ls("$rips/.audiocd-tmp") ], [], 'neASCII: tmp obrisan');
}

# ---- neuspeh usred premestanja: nista ne ostaje ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = sub { write_rip($_[0]); $_[0]{on_exit}->(0) };
    my $cnt = 0;
    my $r = $R->new(spawn => $fake, df => $big_df, cyanrip => 'cyanrip',
        rename => sub { if (++$cnt == 2) { $! = 13; return 0 } CORE::rename($_[0], $_[1]) });
    $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    is($r->history->[0]{result}, 'error', 'neuspeh premestanja -> error');
    like($r->history->[0]{message}, qr/premestanje/, 'poruka pominje premestanje');
    ok(!-e "$rips/Izvođač", 'nema albuma ni novog praznog foldera izvodjaca');
    is_deeply([ ls($rips) ], ['.audiocd-tmp'], 'u rips ostaje samo .audiocd-tmp');
    is_deeply([ ls("$rips/.audiocd-tmp") ], [], 'tmp (i stage) obrisan');
    ok(!$r->busy, 'slobodan posle neuspeha');

    # postojeci folder izvodjaca ostaje netaknut
    my $rips2 = fresh_rips();
    File::Path::make_path("$rips2/Izvođač");
    $cnt = 0;
    my $r2 = $R->new(spawn => $fake, df => $big_df, cyanrip => 'cyanrip',
        rename => sub { if (++$cnt == 3) { $! = 13; return 0 } CORE::rename($_[0], $_[1]) });
    $r2->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips2);
    is($r2->history->[0]{result}, 'error', 'drugi neuspeh -> error');
    is_deeply([ ls("$rips2/Izvođač") ], [], 'postojeci folder izvodjaca prazan i na mestu');

    # tokom gradnje se ne dira odrediste: tek kompletan album se pojavljuje odjednom
    my $rips3 = fresh_rips();
    my @seen;
    my $r3 = $R->new(spawn => $fake, df => $big_df, cyanrip => 'cyanrip',
        rename => sub { push @seen, (-e "$rips3/Izvođač" ? 1 : 0); CORE::rename($_[0], $_[1]) });
    $r3->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips3);
    is_deeply([ grep { $_ } @seen ], [], 'odrediste se ne pojavljuje dok se album gradi');
    ok(-f "$rips3/Izvođač/Album/02 - Naslov 2.flac", 'a posle je kompletan');
}

# ---- greska ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = sub { write_rip($_[0]); $_[0]{on_line}->("greska citanja"); $_[0]{on_exit}->(1) };
    my $r = mk();
    my ($a) = $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    is($r->history->[0]{result}, 'error', 'exit 1 -> error');
    is($r->history->[0]{status}, 1, 'status sacuvan');
    like($r->history->[0]{message}, qr/greska citanja/, 'poruka iz izlaza');
    ok(!-e "$rips/.audiocd-tmp/$a", 'tmp obrisan');
    ok(!-e "$rips/Izvođač", 'nema albuma');

    # exit 0 ali nedostaje fajl
    my $rips2 = fresh_rips();
    $AUTO = sub { write_rip($_[0], skip => 2); $_[0]{on_exit}->(0) };
    my $r2 = mk();
    $r2->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips2);
    is($r2->history->[0]{result}, 'error', 'nedostaje pesma -> error');
    like($r2->history->[0]{message}, qr/2\.flac/, 'poruka kaze koja');
    ok(!-e "$rips2/Izvođač", 'nema delimicnog albuma');
    is_deeply([ ls("$rips2/.audiocd-tmp") ], [], 'tmp obrisan i ovde');

    # spawn baca izuzetak
    my $rips3 = fresh_rips();
    my $r3 = $R->new(spawn => sub { die "nema cyanrip\n" }, df => $big_df);
    $r3->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips3);
    is($r3->history->[0]{result}, 'error', 'spawn izuzetak -> error');
    ok(!$r3->busy, 'nije zauzet posle greske spawn-a');
    is_deeply([ ls("$rips3/.audiocd-tmp") ], [], 'tmp obrisan posle greske spawn-a');
}

# ---- abort_all ----
{
    my $rips = fresh_rips();
    @SPAWNS = ();
    $AUTO = sub { $_[0]{kill_exits} = 1 };
    my $r = mk();
    my ($a) = $r->enqueue(disc => mkdisc(discid => 'a' x 28), toc => $toc, rips_dir => $rips);
    $r->enqueue(disc => mkdisc(discid => 'b' x 28, album => 'B'), toc => $toc, rips_dir => $rips);
    $r->enqueue(disc => mkdisc(discid => 'c' x 28, album => 'C'), toc => $toc, rips_dir => $rips);
    is($r->abort_all('ejected'), 3, 'abort_all vraca broj');
    ok(!$r->busy, 'sve otkazano');
    is(scalar @SPAWNS, 1, 'nista novo nije pokrenuto');
    is($SPAWNS[0]{killed}, 1, 'tekuci ubijen');
    my $h = $r->history;
    is(scalar @$h, 3, 'tri unosa');
    is_deeply([ map { $_->{result} } @$h ], [ ('cancelled') x 3 ], 'svi cancelled');
    is_deeply([ map { $_->{reason} } @$h ], [ ('ejected') x 3 ], 'razlog ejected');
    ok(!-e "$rips/.audiocd-tmp/$a", 'tmp obrisan');
    is($r->abort_all('x'), 0, 'prazan abort_all');
}

# ---- istorija: trajnost i ogranicenje ----
{
    my $hist = "$root/hist/history.json";
    my $rips = fresh_rips();
    $AUTO = sub { write_rip($_[0]); $_[0]{on_exit}->(0) };
    my $r = mk(hist => $hist);
    $r->enqueue(disc => mkdisc(), toc => $toc, rips_dir => $rips);
    ok(-f $hist, 'istorija upisana');
    is(mode_of($hist), '0644', 'istorija 0644');
    my $r2 = mk(hist => $hist);
    is(scalar @{ $r2->history }, 1, 'istorija ucitana iz fajla');
    is($r2->history->[0]{album}, 'Album', 'sadrzaj istorije');

    my @big = map { { id => "h$_", result => 'ok' } } 1 .. 250;
    open my $fh, '>:raw', $hist; print {$fh} JSON::PP->new->utf8->encode(\@big); close $fh;
    my $r3 = mk(hist => $hist);
    is(scalar @{ $r3->history }, 200, 'ucitano najvise 200');
    my $rips2 = fresh_rips();
    $r3->enqueue(disc => mkdisc(discid => 'q' x 28), toc => $toc, rips_dir => $rips2);
    is(scalar @{ $r3->history }, 200, 'ostaje 200');
    is($r3->history->[0]{album}, 'Album', 'najnoviji na vrhu');

    open $fh, '>:raw', $hist; print {$fh} '{pokvareno'; close $fh;
    is(scalar @{ mk(hist => $hist)->history }, 0, 'pokvarena istorija se tolerise');
}

# ---- cleanup_stale ----
{
    my $rips = fresh_rips();
    File::Path::make_path("$rips/.audiocd-tmp/rip-1/sub", "$rips/.audiocd-tmp/rip-2", "$rips/Artist/Album");
    open my $fh, '>', "$rips/.audiocd-tmp/rip-1/sub/1.flac"; close $fh;
    open $fh, '>', "$rips/Artist/Album/keep.flac"; close $fh;
    is($R->can('cleanup_stale')->($rips), 2, 'cleanup_stale broji');
    is_deeply([ ls("$rips/.audiocd-tmp") ], [], 'ostaci obrisani');
    ok(-f "$rips/Artist/Album/keep.flac", 'albumi netaknuti');
    is($R->can('cleanup_stale')->("$rips/nema"), 0, 'nepostojeci folder je ok');
}

# ---- default df ----
{
    my $free = $R->can('default_df')->('.');
    ok(defined $free && $free > 0, 'default_df vraca bajtove') or diag explain $free;
    is($R->can('default_df')->("$root/nema/takvog"), undef, 'default_df za nepostojeci folder je undef');

    # LMS vezuje STDERR za svoj logger (tie bez OPEN): dete ne sme da pukne
    {
        package TiedNoOpenDf;
        sub TIEHANDLE { bless {}, shift }
        sub PRINT { 1 }
        sub PRINTF { 1 }
    }
    my $parent = $$;
    tie *STDERR, 'TiedNoOpenDf';
    my $f2 = $R->can('default_df')->('.');
    untie *STDERR;
    exit 0 if $$ != $parent;    # zastita: dete ne sme da nastavi test
    ok(defined $f2 && $f2 > 0, 'default_df sa vezanim STDERR vraca bajtove') or diag explain $f2;
}

# ---- loši argumenti ----
{
    my $r = mk();
    my (undef, $e) = $r->enqueue(disc => mkdisc(), toc => $toc);
    is($e->{error}, 'bad_args', 'bez rips_dir');
    (undef, $e) = $r->enqueue(toc => $toc, rips_dir => fresh_rips());
    is($e->{error}, 'bad_args', 'bez diska');
}

# ---- on_change ----
ok(scalar @CHANGES > 0, 'on_change pozivan');

done_testing;
