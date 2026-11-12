use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp ();
use File::Path ();
use File::Spec ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::Cache') }

my $C = 'Plugins::AudioCD::Cache';

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my $root = File::Spec->rel2abs(File::Temp::tempdir('cache-XXXXXX', DIR => '.', CLEANUP => 1));
my $n = 0;
sub fresh_dir { my $d = "$root/c" . ++$n; File::Path::make_path($d); return $d }

# TOC sa 5 audio pesama + data pesma 6 (enhanced CD), po 60 s
my $toc = { first => 1, last => 6, leadout => 400 * 75,
    tracks => [ (map { { n => $_, lba => ($_ - 1) * 60 * 75, data => 0 } } 1 .. 5), { n => 6, lba => 350 * 75, data => 1 } ] };
my $DISCID = 'dBFBpdDGyUnu4ofAwN5ZrxozKwM-';

sub mkdisc {
    my (%o) = @_;
    return {
        discid => $o{discid} // $DISCID, artist => 'Izvođač', album => 'Album',
        release_id => 'rel-1', album_artist_id => 'aa-1',
        tracks => [ map { { n => $_, title => "Naslov $_", recording_id => "rec-$_" } } 1 .. 5 ],
    };
}

# ---- lazni spawn ----
my @SPAWNS;    # { argv, cmd, out, n, on_exit, killed }
my $fake = sub {
    my (%a) = @_;
    my @argv = @{ $a{argv} };
    my $cmd  = $argv[-1];
    my ($out) = $cmd =~ /'-o' '([^']*)'/;
    my ($tn)  = $cmd =~ /'-d' '[^']*' '(\d+)'/;
    my $sp = bless { %a, cmd => $cmd, out => $out, n => $tn, killed => 0 }, 'FakeJob';
    if (defined $out) { open my $fh, '>', $out or die "$out: $!"; print {$fh} 'part'; close $fh }
    push @SPAWNS, $sp;
    return $sp;
};
{
    package FakeJob;
    sub kill { $_[0]{killed}++ }
}
sub finish { my ($sp, $st) = @_; $sp->{on_exit}->($st // 0) }
sub order { map { $_->{n} } @SPAWNS }

my $changes = 0;
sub mk {
    my (%o) = @_;
    @SPAWNS = ();
    return $C->new(spawn => $fake, dir => $o{dir} // fresh_dir(), device => '/dev/sr0', secure => $o{secure} // 0,
        on_change => sub { $changes++ }, paranoia => 'cd-paranoia', flac => 'flac');
}

# ---- cache_dir ----
{
    my $base = fresh_dir();
    my $ro = "$base/ro";
    File::Path::make_path($ro);
    chmod 0555, $ro;
    my $got = $C->can('cache_dir')->(candidates => [ "$ro", "$ro/sub", "$base/ok/audiocd" ]);
    is $got, "$base/ok/audiocd", 'cache_dir preskace neupisiv i nenapravljiv kandidat';
    ok -d $got, 'cache_dir pravi folder';
    is $C->can('cache_dir')->(candidates => [ "$base/ok/audiocd", "$base/x" ]), "$base/ok/audiocd", 'prvi upisiv pobedjuje';
    ok !-e "$base/x", 'kasniji kandidati se ne prave';
    is $C->can('cache_dir')->(candidates => [ $ro ]), undef, 'nijedan upisiv: undef';
    chmod 0755, $ro;
}

# ---- argv ----
{
    my $c = mk(secure => 0);
    $c->start(mkdisc(), $toc, 2);
    my $sp = $SPAWNS[0];
    is_deeply [ @{ $sp->{argv} }[0 .. 4] ], [ 'nice', '-n', '10', 'ionice', '-c3' ], 'argv pocinje sa nice -n 10 ionice -c3';
    like $sp->{cmd}, qr/^set -o pipefail; 'cd-paranoia' '-Z' '-d' '\/dev\/sr0' '2' '-' \| 'flac' '-0' '--silent' '-f' /, 'cd-paranoia -Z u pipe ka flac -0';
    like $sp->{cmd}, qr/'-T' 'TITLE=Naslov 2'/, 'TITLE';
    like $sp->{cmd}, qr/'-T' 'ARTIST=Izvođač'/, 'ARTIST (izvodjac diska kad pesma nema svog)';
    like $sp->{cmd}, qr/'-T' 'ALBUM=Album'/, 'ALBUM';
    like $sp->{cmd}, qr/'-T' 'TRACKNUMBER=2'/, 'TRACKNUMBER';
    like $sp->{cmd}, qr/'-T' 'MUSICBRAINZ_TRACKID=rec-2'/, 'MusicBrainz track ID';
    like $sp->{cmd}, qr/'-T' 'MUSICBRAINZ_ALBUMID=rel-1'/, 'MusicBrainz album ID';
    unlike $sp->{cmd}, qr/MUSICBRAINZ_RELEASEGROUPID/, 'prazni ID-jevi se izostavljaju';
    my $dir = $c->{dir};
    like $sp->{cmd}, qr/'-o' '\Q$dir\E\/\Q$DISCID\E\/02\.flac\.part' '-'$/, 'izlaz NN.flac.part, ulaz stdin';
    is $sp->{umask}, 022, 'umask 022';
    $c->stop;

    my $s = mk(secure => 1);
    $s->start(mkdisc(), $toc, 1);
    unlike $SPAWNS[0]{cmd}, qr/'-Z'/, 'secure => 1: bez -Z';
    like $SPAWNS[0]{cmd}, qr/^set -o pipefail; 'cd-paranoia' '-d' /, 'secure => 1: podrazumevana paranoia';
    $s->stop;
}

# ---- redosled, path, ready, status ----
{
    my $c = mk();
    $changes = 0;
    $c->start(mkdisc(), $toc, 3);
    ok $c->busy, 'busy posle start';
    is scalar(@SPAWNS), 1, 'jedna pesma u isto vreme';
    is $c->path($DISCID, 3), undef, 'path undef dok je .part';
    ok -f $SPAWNS[0]{out}, '.part postoji';
    is $c->ready(3), 0, 'ready 0 dok traje';
    is $c->status->{current}, 3, 'status current';
    finish($SPAWNS[0]);
    my $p = $c->path($DISCID, 3);
    ok defined $p && $p =~ m{/03\.flac\z} && -f $p, 'path posle zavrsetka';
    ok !-e "$p.part", '.part preimenovan';
    is sprintf('%04o', (stat $p)[2] & 07777), '0644', 'fajl 0644';
    is $c->ready(3), 1, 'ready 1';
    ok $changes > 0, 'on_change pozvan';
    finish($SPAWNS[-1]) for 1 .. 4;
    is_deeply [ order() ], [ 3, 4, 5, 1, 2 ], 'redosled 3,4,5,1,2 (data pesma se preskace)';
    ok !$c->busy, 'nije busy kad je sve gotovo';
    my $st = $c->status;
    is_deeply $st->{done}, [ 1 .. 5 ], 'status done';
    is $st->{current}, undef, 'nema current';
    is $st->{percent}, 100, 'percent 100';
    is $c->path('drugi', 3), undef, 'path za drugi disk: undef';
    is $c->path($DISCID, 6), undef, 'path za data pesmu: undef';

    # ponovni start istog diska ne izvlaci ponovo
    $c->start(mkdisc(), $toc, 1);
    is scalar(@SPAWNS), 5, 'gotove pesme se ne izvlace ponovo';
    ok !$c->busy, 'i dalje nije busy';
}

# ---- prioritize ----
{
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    $c->prioritize(5);
    is $c->status->{current}, 1, 'tekuca pesma se ne prekida';
    finish($SPAWNS[0]);
    is $SPAWNS[1]{n}, 5, 'prioritize(5): 5 je sledeca';
    is $c->status->{percent}, 20, 'percent 20 posle jedne od pet';
    $c->prioritize(1);
    finish($SPAWNS[1]);
    is $SPAWNS[2]{n}, 2, 'prioritize gotove pesme ne menja redosled';
    $c->stop;
}

# ---- greska pesme ----
{
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    my $out = $SPAWNS[0]{out};
    my @w;
    { local $SIG{__WARN__} = sub { push @w, @_ }; finish($SPAWNS[0], 1) }
    like "@w", qr/pesma 1 nije izvucena \(status 1\)/, 'greska se loguje';
    ok !-e $out, 'neuspela pesma: .part obrisan';
    is $c->path($DISCID, 1), undef, 'neuspela pesma: nema path';
    is_deeply $c->status->{failed}, [1], 'status failed';
    is $SPAWNS[1]{n}, 2, 'posle greske ide sledeca';
    $c->stop;
}

# ---- stop ----
{
    my $c = mk();
    $c->start(mkdisc(), $toc, 2);
    my $sp = $SPAWNS[0];
    $c->stop;
    is $sp->{killed}, 1, 'stop ubija posao';
    ok !-e $sp->{out}, 'stop brise .part';
    ok !$c->busy, 'posle stop nije busy';
    is $c->status->{current}, undef, 'posle stop nema current';
    finish($sp, 143);
    is $c->path($DISCID, 2), undef, 'kasni on_exit posle stop ne pravi fajl';
    is scalar(@SPAWNS), 1, 'posle stop se nista novo ne pokrece';
}

# ---- clear i drugi disk ----
{
    my $dir = fresh_dir();
    my $c = mk(dir => $dir);
    $c->start(mkdisc(), $toc, 1);
    finish($SPAWNS[0]);
    ok -d "$dir/$DISCID", 'folder diska postoji';
    File::Path::make_path("$dir/nije-disk", "$dir/kratak-");
    $c->start(mkdisc(discid => 'xBFBpdDGyUnu4ofAwN5ZrxozKwM-'), $toc, 1);
    ok !-e "$dir/$DISCID", 'start drugog diska brise keš prethodnog';
    ok -d "$dir/nije-disk" && -d "$dir/kratak-", 'folderi koji nisu disc ID ostaju';
    ok -d "$dir/xBFBpdDGyUnu4ofAwN5ZrxozKwM-", 'folder novog diska';
    is $c->path($DISCID, 1), undef, 'stari disk vise nije u kesu';
    $c->clear;
    ok !-e "$dir/xBFBpdDGyUnu4ofAwN5ZrxozKwM-", 'clear brise folder diska';
    ok !$c->busy, 'clear zaustavlja posao';
    is_deeply $c->status->{done}, [], 'clear prazni done';
    ok -d $dir, 'cache_dir ostaje';
}

# ---- new: dir mora biti apsolutna putanja ----
for my $bad (undef, '', 'relativ/dir', '/') {
    my $ok = eval { $C->new(spawn => $fake, dir => $bad, device => '/dev/sr0'); 1 };
    ok !$ok && $@ =~ /apsolutna putanja/, 'new odbija dir ' . (defined $bad ? "'$bad'" : 'undef');
}

# ---- start odbija neispravan disc ID ----
{
    my $c = mk();
    my @w;
    { local $SIG{__WARN__} = sub { push @w, @_ }; ok !$c->start(mkdisc(discid => '../x'), $toc, 1), 'start odbija ../x' }
    like "@w", qr/neispravan disk/, 'upozorenje za neispravan disk';
    is scalar(@SPAWNS), 0, 'nista se ne pokrece';
}

# ---- prazan izvodjac pesme -> izvodjac diska ----
{
    my $c = mk();
    my $d = mkdisc();
    $d->{tracks}[0]{artist} = '';
    $d->{tracks}[1]{artist} = 'Gost';
    $c->start($d, $toc, 1);
    like $SPAWNS[0]{cmd}, qr/'-T' 'ARTIST=Izvođač'/, 'prazan izvodjac pesme: izvodjac diska';
    finish($SPAWNS[0]);
    like $SPAWNS[1]{cmd}, qr/'-T' 'ARTIST=Gost'/, 'izvodjac pesme kad postoji';
    $c->stop;
    is $C->can('track_artist')->({ artist => '' }, { artist => 'D' }), 'D', 'track_artist: prazan -> disk';
    is $C->can('track_artist')->({}, { artist => 'D' }), 'D', 'track_artist: nema -> disk';
}

# ---- ostaci u folderu diska (_scan_existing) ----
{
    my $dir = fresh_dir();
    File::Path::make_path("$dir/$DISCID");
    for my $f ('03.flac', '04.flac.part') { open my $fh, '>', "$dir/$DISCID/$f" or die; print {$fh} 'x'; close $fh }
    my $c = mk(dir => $dir);
    $c->start(mkdisc(), $toc, 1);
    ok !-e "$dir/$DISCID/04.flac.part", 'stari .part obrisan';
    is $c->ready(3), 1, 'postojeci 03.flac je gotov';
    finish($SPAWNS[-1]) for 1 .. 3;
    is_deeply [ order() ], [ 1, 2, 4, 5 ], 'postojeca pesma se ne izvlaci ponovo';
}

# ---- spawn koji pada ili ne vrati posao ----
for my $case ([ 'die', sub { die "boom\n" } ], [ 'undef', sub { return undef } ]) {
    my ($name, $sp) = @$case;
    my $c = $C->new(spawn => $sp, dir => fresh_dir(), device => '/dev/sr0', paranoia => 'p', flac => 'f');
    my @w;
    { local $SIG{__WARN__} = sub { push @w, @_ }; $c->start(mkdisc(), $toc, 1) }
    is_deeply $c->status->{failed}, [ 1 .. 5 ], "spawn $name: sve pesme neuspele";
    ok !$c->busy, "spawn $name: nije busy";
    like "@w", ($name eq 'die' ? qr/boom/ : qr/nema posla/), "spawn $name: upozorenje";
}

# ---- start istog diska tokom izvlacenja ----
{
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    $c->start(mkdisc(), $toc, 1);
    is scalar(@SPAWNS), 1, 'ponovni start ne pokrece novi posao';
    is $SPAWNS[0]{killed}, 0, 'tekuci posao nije ubijen';
    finish($SPAWNS[-1]) for 1 .. 5;
    is_deeply [ order() ], [ 1 .. 5 ], 'tekuca pesma nije ponovo u redu';
}

# ---- waiter: jedan cekac po plejeru ----
{
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    my $w2 = $c->waiter(key => 'p1', discid => $DISCID, n => 2);
    my $w3 = $c->waiter(key => 'p1', discid => $DISCID, n => 3);
    my $w4 = $c->waiter(key => 'p1', discid => $DISCID, n => 4);
    my $o5 = $c->waiter(key => 'p2', discid => $DISCID, n => 5);
    is_deeply [ $w2->poll(1) ], ['stop'], 'stari cekac (preskok 1) staje';
    is_deeply [ $w3->poll(1) ], ['stop'], 'stari cekac (preskok 2) staje';
    is_deeply $c->{queue}, [ 2, 3, 4, 5 ], 'zastareli cekaci ne diraju red';
    is_deeply [ $w4->poll(1) ], ['wait'], 'najnoviji ceka';
    is $c->{queue}[0], 4, 'samo najnoviji prioritizuje';
    is_deeply [ $w2->poll(1) ], ['stop'], 'stari i dalje staje';
    is $c->{queue}[0], 4, 'red ostaje';
    is_deeply [ $o5->poll(1) ], ['wait'], 'drugi plejer ima svog cekaca';
    my $w5 = $c->waiter(key => 'p3', discid => $DISCID, n => 3);
    is_deeply [ $w5->poll(0) ], ['stop'], 'LMS vise ne ceka pesmu: stop';
    is $c->{queue}[0], 5, 'neaktivan cekac ne prioritizuje';
    finish($SPAWNS[0]);
    is $SPAWNS[1]{n}, 5, 'izvlaci se prioritizovana pesma';
    finish($SPAWNS[1]);
    my @r = $o5->poll(1);
    is $r[0], 'ready', 'ready kad je pesma gotova';
    like $r[1], qr{/05\.flac\z}, 'ready vraca putanju';
    my $wd = $c->waiter(key => 'p4', discid => 'xBFBpdDGyUnu4ofAwN5ZrxozKwM-', n => 1);
    is_deeply [ $wd->poll(1) ], [ 'fail', 'disk nije u kesu' ], 'drugi disk: fail';
    $c->stop;
    my $wi = $c->waiter(key => 'p4', discid => $DISCID, n => 2);
    is_deeply [ $wi->poll(1) ], [ 'fail', 'kes ne izvlaci pesme' ], 'kes stoji: fail';
}

# ---- waiter: rok 120 s, produzava se dok .part raste, najvise 600 s ----
{
    my $T = 0;
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    my $part = $SPAWNS[0]{out};
    my $grow = sub { open my $fh, '>>', $part or die; print {$fh} 'x' x 10; close $fh };

    my $q = $c->waiter(key => 'q', discid => $DISCID, n => 3, now => sub { $T });
    $T = 119;
    is_deeply [ $q->poll(1) ], ['wait'], 'pesma u redu: ceka do 120 s';
    $T = 120;
    is_deeply [ $q->poll(1) ], [ 'fail', 'isteklo cekanje' ], 'pesma u redu: posle 120 s fail';

    $T = 0;
    my $w = $c->waiter(key => 'w', discid => $DISCID, n => 1, now => sub { $T });
    is_deeply [ $w->poll(1) ], ['wait'], 'tekuca pesma: ceka';
    for my $t (100, 200, 300, 400, 500) {
        $T = $t;
        $grow->();
        is_deeply [ $w->poll(1) ], ['wait'], "t=$t: .part raste, rok produzen";
    }
    $T = 599;
    is_deeply [ $w->poll(1) ], ['wait'], 't=599: jos u roku';
    $T = 600;
    $grow->();
    is_deeply [ $w->poll(1) ], [ 'fail', 'isteklo cekanje' ], 't=600: tvrda granica i kad raste';

    $T = 0;
    my $s = $c->waiter(key => 's', discid => $DISCID, n => 1, now => sub { $T });
    $T = 50;
    $s->poll(1);
    $T = 171;
    is_deeply [ $s->poll(1) ], [ 'fail', 'isteklo cekanje' ], 'bez rasta: 120 s od poslednjeg rasta';
    $c->stop;
}

done_testing;
