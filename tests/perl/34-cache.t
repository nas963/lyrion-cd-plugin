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
    return $C->new(spawn => $fake, dir => $o{dir} // fresh_dir(), device => '/dev/sr0', secure => $o{secure} // 0, speed => $o{speed}, early => $o{early},
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

# ---- duzina izvucene pesme ----
{
    my $flac = sub {
        my ($sp, $secs) = @_;
        my $samples = 44100 * $secs;
        open my $fh, '>:raw', $sp->{out} or die $!;
        print {$fh} 'fLaC', pack('C4', 0, 0, 0, 34), pack('n2', 4096, 4096), "\0" x 6,
            pack('NN', (44100 << 12) | (1 << 9) | (15 << 4) | int($samples / 4294967296), $samples % 4294967296), "\0" x 16;
        close $fh;
    };
    my ($mm, $dir) = (0, fresh_dir());
    @SPAWNS = ();
    my $c = $C->new(spawn => $fake, dir => $dir, device => '/dev/sr0', on_mismatch => sub { $mm++ }, paranoia => 'p', flac => 'f');
    $c->start(mkdisc(), $toc, 1);
    $flac->($SPAWNS[0], 60.5); finish($SPAWNS[0]);
    ok $c->ready(1), 'duzina kao u TOC-u: pesma je gotova';
    is $mm, 0, '...bez provere diska';
    $flac->($SPAWNS[1], 140); finish($SPAWNS[1]);
    ok !$c->ready(2), 'pesma drugog diska nije prihvacena';
    ok !-e $SPAWNS[1]{out}, '...i obrisana je';
    is_deeply $c->status->{failed}, [2], '...vodi se kao neuspela';
    is $mm, 1, '...trazi se provera diska';
    $flac->($SPAWNS[2], 30); finish($SPAWNS[2]);
    ok !$c->ready(3), 'prekratka pesma nije prihvacena';
    finish($SPAWNS[3]);
    ok $c->ready(4), 'nepoznata duzina se ne proverava';
    $flac->($SPAWNS[4], 20); finish($SPAWNS[4]);
    ok $c->ready(5), 'poslednja pesma pred data pesmom se ne proverava';
}

# ---- napredak tokom pesme ----
{
    my $grow = sub { my ($sp, $bytes) = @_; truncate $sp->{out}, $bytes or die "truncate: $!" };
    my $c = mk();
    $c->start(mkdisc(), $toc, 1);
    is $c->status->{percent}, 0, 'pocetak: 0%';
    $grow->($SPAWNS[0], 60 * 176400 * 0.65 / 2);
    my $all = 60 * 4 + (350 * 75 - 11400 - 4 * 4500) / 75;    # pesma 5 do data pesme
    is $c->status->{percent}, int(30 / $all * 100), 'pola prve pesme se vidi';
    $grow->($SPAWNS[0], 60 * 176400 * 2);
    my $top = $c->status->{percent};
    ok $top > 15 && $top * $all < 60 * 100, 'tekuca pesma najvise 99%';
    $grow->($SPAWNS[0], 1000);
    is $c->status->{percent}, $top, 'napredak se ne vraca';
    $grow->($SPAWNS[0], 60 * 50000);
    finish($SPAWNS[0]);
    $grow->($SPAWNS[1], 30 * 50000);
    is $c->status->{percent}, int(90 / $all * 100), 'kompresija procenjena iz gotove pesme';
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

    # tisi drajv: brzina se cita za svaku pesmu
    my $speed = 8;
    my $q = mk(speed => sub { $speed });
    $q->start(mkdisc(), $toc, 1);
    like $SPAWNS[0]{cmd}, qr/'cd-paranoia' '-Z' '-S' '8' '-d' '\/dev\/sr0' '1' '-'/, 'speed 8: -S 8';
    $speed = undef;
    finish($SPAWNS[0]);
    unlike $SPAWNS[1]{cmd}, qr/'-S'/, 'ogranicenje iskljuceno: sledeca pesma bez -S';
    $q->stop;

    for my $bad ('', 0, 'abc', '-3', 100) {
        my $b = mk(speed => $bad);
        $b->start(mkdisc(), $toc, 1);
        unlike $SPAWNS[0]{cmd}, qr/'-S'/, "neispravna brzina '$bad': bez -S";
        $b->stop;
    }
}

# ---- device i secure kao code ref: citaju se za svaku pesmu ----
{
    @SPAWNS = ();
    my ($dev, $sec) = ('/dev/sr0', 0);
    my $c = $C->new(spawn => $fake, dir => fresh_dir(), device => sub { $dev }, secure => sub { $sec },
        paranoia => 'cd-paranoia', flac => 'flac');
    $c->start(mkdisc(), $toc, 1);
    like $SPAWNS[0]{cmd}, qr/'cd-paranoia' '-Z' '-d' '\/dev\/sr0' '1'/, 'code ref: /dev/sr0, brzo';
    ($dev, $sec) = ('/dev/sr1', 1);
    finish($SPAWNS[0]);
    like $SPAWNS[1]{cmd}, qr/'cd-paranoia' '-d' '\/dev\/sr1' '2'/, 'code ref: promena uredjaja i secure vazi za sledecu pesmu';
    $c->stop;
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
    is $c->status->{percent}, 30, 'percent po trajanju pesama, ne po broju';
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

# ---- waiter + ensure: kes nije pokrenut za ovaj disk (lista posle restarta, Add, ponovo ubacen disk) ----
{
    my $T = 0;
    my $c = mk();
    my @calls;
    my @answer = (1, undef);
    my $ensure = sub { push @calls, [@_]; my @a = @answer; $c->start(mkdisc(), $toc, $_[1]) if $a[0]; return @a };

    my $w = $c->waiter(key => 'e', discid => $DISCID, n => 3, now => sub { $T }, ensure => $ensure);
    is_deeply [ $w->poll(1) ], ['wait'], 'ensure: kes pokrenut, ceka';
    is_deeply \@calls, [ [ $DISCID, 3 ] ], 'ensure pozvan sa discid i pesmom';
    is $SPAWNS[0]{n}, 3, 'izvlaci se trazena pesma';
    $w->poll(1);
    is scalar(@calls), 1, 'ensure samo jednom dok kes radi';
    finish($SPAWNS[0]);
    is(($w->poll(1))[0], 'ready', 'ensure: pesma gotova -> ready');
    $c->stop;

    # drugi disk u drajvu: odmah fail (bez cekanja 120 s)
    @calls = ();
    @answer = (undef, { error => 'wrong_disc' });
    my $x = $c->waiter(key => 'e', discid => 'xBFBpdDGyUnu4ofAwN5ZrxozKwM-', n => 1, now => sub { $T }, ensure => $ensure);
    my @r = $x->poll(1);
    is $r[0], 'fail', 'ensure wrong_disc -> fail odmah';
    like $r[1], qr/wrong_disc/, 'razlog wrong_disc';

    # rip u toku: fail odmah
    @answer = (undef, { error => 'drive_busy', busy => 'rip' });
    my $rp = $c->waiter(key => 'e', discid => $DISCID, n => 1, now => sub { $T }, ensure => $ensure);
    is(($rp->poll(1))[0], 'fail', 'ensure drive_busy rip -> fail');

    # cd-info / proces koji umire / disk se cita: ponavlja se do 60 s
    for my $e ([ 'drive_busy', 'lookup' ], [ 'drive_busy', 'process' ], [ 'not_ready', undef ]) {
        @calls = ();
        @answer = (undef, { error => $e->[0], defined $e->[1] ? (busy => $e->[1]) : () });
        $T = 0;
        my $b = $c->waiter(key => 'e', discid => $DISCID, n => 2, now => sub { $T }, ensure => $ensure);
        is_deeply [ $b->poll(1) ], ['wait'], "ensure $e->[0]/" . ($e->[1] // '') . ': ceka';
        $T = 59;
        is_deeply [ $b->poll(1) ], ['wait'], 'jos u roku za ponavljanje';
        is scalar(@calls), 2, 'ensure se ponavlja';
        $T = 60;
        is(($b->poll(1))[0], 'fail', 'posle 60 s fail');
    }

    # posle ponavljanja drajv slobodan: kes krece
    @calls = ();
    $T = 0;
    @answer = (undef, { error => 'drive_busy', busy => 'lookup' });
    my $l = $c->waiter(key => 'e', discid => $DISCID, n => 2, now => sub { $T }, ensure => $ensure);
    $l->poll(1);
    @answer = (1, undef);
    $T = 1;
    is_deeply [ $l->poll(1) ], ['wait'], 'drajv slobodan: kes pokrenut, ceka';
    is $SPAWNS[-1]{n}, 2, 'izvlaci se pesma 2';
    $c->stop;

    # bez ensure: staro ponasanje
    my $o = $c->waiter(key => 'e', discid => $DISCID, n => 2, now => sub { $T });
    is_deeply [ $o->poll(1) ], [ 'fail', 'kes ne izvlaci pesme' ], 'bez ensure: fail';
}

# ---- slobodan prostor: /run je mali tmpfs; potrebno ~ sekunde * 176400 * 0.65 + 20 MB ----
{
    # $toc: 5 audio pesama (enhanced CD: audio leadout je pre data sesije)
    my $secs = 0;
    $secs += $_ for values %{ Plugins::AudioCD::DiscId::track_lengths($toc) };
    ok $secs > 0, "audio sekunde: $secs";
    my $need = int($secs * 176400 * 0.65) + 20 * 1024 * 1024;
    is $C->can('needed_bytes')->($toc), $need, 'needed_bytes: audio sekunde * 176400 * 0.65 + 20 MB';

    my ($a, $b, $c3) = (fresh_dir(), fresh_dir(), fresh_dir());
    my %free = ($a => $need - 1, $b => $need, $c3 => 10 * $need);
    my @asked;
    my $df = sub { push @asked, $_[0]; return $free{ $_[0] } };
    @SPAWNS = ();
    my $c = $C->new(spawn => $fake, dir => $a, candidates => [ $a, $b, $c3 ], df => $df,
        device => '/dev/sr0', paranoia => 'cd-paranoia', flac => 'flac');
    ok $c->start(mkdisc(), $toc, 1), 'start: prvi folder nema mesta, drugi ima';
    is $c->dir, $b, 'kes je u drugom kandidatu';
    like $SPAWNS[0]{cmd}, qr/'-o' '\Q$b\E\/\Q$DISCID\E\/01\.flac\.part'/, 'pesma se pise u drugi folder';
    is_deeply \@asked, [ $a, $b ], 'df redom, staje na prvom koji ima mesta';
    is $c->last_error, undef, 'bez greske';
    my $p = $c->waiter(key => 'z', discid => $DISCID, n => 1);
    finish($SPAWNS[0]);
    like(($p->poll(1))[1], qr{^\Q$b\E/}, 'path iz novog foldera');
    $c->stop;

    # isti disk ponovo: bez nove provere (kes vec postoji)
    @asked = ();
    ok $c->start(mkdisc(), $toc, 2), 'isti disk: nastavlja';
    is_deeply \@asked, [], 'isti disk: df se ne pita';
    $c->stop;

    # nigde nema mesta: jasna greska, nista se ne pokrece
    %free = ($a => 1, $b => 1, $c3 => 1);
    @SPAWNS = ();
    my $n2 = $C->new(spawn => $fake, dir => $a, candidates => [ $a, $b, $c3 ], df => $df,
        device => '/dev/sr0', paranoia => 'cd-paranoia', flac => 'flac');
    ok !$n2->start(mkdisc(), $toc, 1), 'nigde nema mesta: start 0';
    my $e = $n2->last_error;
    is ref $e eq 'HASH' && $e->{error}, 'cache_no_space', 'greska cache_no_space';
    is $e->{needed}, $need, 'greska: potrebno';
    is scalar(@SPAWNS), 0, 'nista nije pokrenuto';
    ok !$n2->busy, 'kes ne radi';

    # df ne zna (spor, mrtav mount): dozvoljava se
    @SPAWNS = ();
    my $u = $C->new(spawn => $fake, dir => $a, candidates => [ $a ], df => sub { undef },
        device => '/dev/sr0', paranoia => 'cd-paranoia', flac => 'flac');
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, $_[0] };
    ok $u->start(mkdisc(), $toc, 1), 'df nepoznat: start radi';
    ok scalar(grep { /slobodan prostor/ } @warn), 'df nepoznat: upozorenje';
    $u->stop;
}

# ---- kes ostaje posle izbacivanja diska (stop bez clear) ----
{
    my $dir = fresh_dir();
    my $c = mk(dir => $dir);
    $c->start(mkdisc(), $toc, 1);
    finish($SPAWNS[0]);                  # pesma 1 gotova, 2 se izvlaci
    is $SPAWNS[1]{n}, 2, 'pesma 2 u toku';
    $c->stop;                            # izbacivanje: stop, ne clear
    ok $SPAWNS[1]{killed}, 'izvlacenje prekinuto';
    ok !$c->busy, 'posle stop nema posla';
    ok -f "$dir/$DISCID/01.flac", 'gotova pesma ostaje na disku';
    ok !-e "$dir/$DISCID/02.flac.part", 'nedovrsena pesma obrisana';
    is $c->discid, $DISCID, 'discid kesa ostaje';
    is $c->path($DISCID, 1), "$dir/$DISCID/01.flac", 'gotova pesma se i dalje servira';
    is $c->path($DISCID, 2), undef, 'nedovrsena pesma se ne servira';
    is_deeply $c->status->{done}, [1], 'status.done ostaje';
    is_deeply $c->status->{failed}, [], 'prekinuta pesma nije failed';

    # ProtocolHandler cekac: gotova -> ready; nedovrsena -> odmah fail (bez cekanja 120 s)
    my $w = $c->waiter(key => 'p1', discid => $DISCID, n => 1);
    my ($what, $arg) = $w->poll(1);
    is $what, 'ready', 'cekac: gotova pesma ejektovanog diska se pusta';
    is $arg, "$dir/$DISCID/01.flac", 'cekac: putanja';
    $w = $c->waiter(key => 'p1', discid => $DISCID, n => 3);
    ($what, $arg) = $w->poll(1);
    is $what, 'fail', 'cekac: nedovrsena pesma ejektovanog diska odmah pada';
    like $arg, qr/ne izvlaci/, 'cekac: razlog';

    # nova pesma ne pokrece spawn-ove dok disk nije vracen
    my $n0 = @SPAWNS;
    is scalar(@SPAWNS), $n0, 'nista se ne pokrece samo od sebe';

    # resumable: isti disk, ima nedostajucih pesama, nista ne radi
    ok $c->resumable($DISCID), 'resumable: isti disk sa nedostajucim pesmama';
    ok !$c->resumable('xBFBpdDGyUnu4ofAwN5ZrxozKwM-'), 'resumable: drugi disk ne';

    # isti disk ponovo: nastavlja samo nedostajuce pesme
    @SPAWNS = ();
    ok $c->start(mkdisc(), $toc, 1), 'start istog diska posle stop';
    is_deeply [ order() ], [2], 'nastavlja od prve nedostajuce pesme (1 se ne izvlaci ponovo)';
    finish($SPAWNS[-1]);
    is_deeply [ order() ], [2, 3], 'pa sledeca';
    ok -f "$dir/$DISCID/01.flac", 'pesma 1 netaknuta';

    # svi gotovi: nije resumable
    for (1 .. 3) { finish($SPAWNS[-1]) if $c->busy }
    ok !$c->resumable($DISCID), 'resumable: sve gotovo -> ne';

    # drugi disk brise kes ejektovanog
    my $dir2 = fresh_dir();
    my $c2 = mk(dir => $dir2);
    $c2->start(mkdisc(), $toc, 1);
    finish($SPAWNS[0]);
    $c2->stop;
    $c2->start(mkdisc(discid => 'xBFBpdDGyUnu4ofAwN5ZrxozKwM-'), $toc, 1);
    ok !-e "$dir2/$DISCID", 'drugi disk posle ejekta: kes prethodnog obrisan';
    is $c2->path($DISCID, 1), undef, 'stari disk vise nije servisan';
}

# ---- nastavak (resume) ne ponavlja neuspele pesme; eksplicitan start ih ponavlja ----
{
    my $dir = fresh_dir();
    my $c = mk(dir => $dir);
    $c->start(mkdisc(), $toc, 1);
    finish($SPAWNS[0]);                              # 1 gotova
    { local $SIG{__WARN__} = sub { }; finish($SPAWNS[1], 1) }    # 2 neuspela (los sektor)
    finish($SPAWNS[2]);                              # 3 gotova
    $c->stop;                                        # 4 prekinuta izbacivanjem, 5 nikad pokusana
    is_deeply $c->status->{failed}, [2], 'resume: pesma 2 neuspela';
    ok $c->resumable($DISCID), 'resume: ima nedostajucih (4, 5)';

    @SPAWNS = ();
    ok $c->start(mkdisc(), $toc, 4, resume => 1), 'resume start';
    is_deeply [ order() ], [4], 'resume: pocinje od nedostajuce pesme';
    finish($SPAWNS[-1]);
    finish($SPAWNS[-1]);
    is_deeply [ order() ], [4, 5], 'resume: neuspela pesma 2 se ne ponavlja';
    ok !$c->busy, 'resume: gotovo';
    is_deeply $c->status->{failed}, [2], 'resume: pesma 2 ostaje neuspela';
    ok !$c->resumable($DISCID), 'resumable: samo neuspele pesme fale -> ne';

    # eksplicitan Play/ensure: neuspela pesma se ponavlja
    @SPAWNS = ();
    ok $c->start(mkdisc(), $toc, 2), 'eksplicitan start';
    is_deeply [ order() ], [2], 'eksplicitan start: neuspela pesma se ponavlja';
    is_deeply $c->status->{failed}, [], 'eksplicitan start: failed obrisan';
    finish($SPAWNS[-1]);

    # izbacivanje: greske nastale jer je disk izvadjen se zaboravljaju (forget_failed)
    my $c2 = mk(dir => fresh_dir());
    $c2->start(mkdisc(), $toc, 1);
    { local $SIG{__WARN__} = sub { }; finish($SPAWNS[-1], 1) for 1 .. 5 }
    is_deeply $c2->status->{failed}, [1 .. 5], 'disk izvadjen: sve pesme pukle';
    ok !$c2->resumable($DISCID), 'pre forget_failed: nije resumable';
    $c2->forget_failed;
    is_deeply $c2->status->{failed}, [], 'forget_failed brise neuspehe';
    ok $c2->resumable($DISCID), 'posle forget_failed: resumable';
}

# ---- rano pustanje ----
{
    is mk()->early_bytes, undef, 'early: iskljuceno';
    is mk(early => 1, speed => 2)->early_bytes, undef, 'early: prespor drajv';
    my $base = mk(early => 1)->early_bytes;
    ok $base > 1_000_000, 'early: zaliha';
    is mk(early => sub { 1 }, speed => 8)->early_bytes, $base, 'early: brzina 8';
    is mk(early => 1, secure => 1)->early_bytes, 2 * $base, 'early: sigurno citanje dupla zaliha';

    my $c = mk(early => 1);
    $c->start(mkdisc(), $toc, 1);
    is $c->track_secs($DISCID, 1), 60, 'trajanje iz TOC-a';
    my $w = $c->waiter(key => 'p', discid => $DISCID, n => 1, early => 10);
    is(($w->poll(1))[0], 'wait', 'early: zaliha jos mala');
    { open my $fh, '>>', $SPAWNS[0]{out} or die; print {$fh} 'x' x 20; close $fh }
    is(($w->poll(1))[0], 'early', 'early: dovoljna zaliha');
    my $w2 = $c->waiter(key => 'q', discid => $DISCID, n => 1);
    is(($w2->poll(1))[0], 'wait', 'bez early: ceka celu pesmu');
    my $w3 = $c->waiter(key => 'r', discid => $DISCID, n => 2, early => 1);
    is(($w3->poll(1))[0], 'wait', 'early: pesma koja se ne izvlaci ceka');

    my $rec = $c->growing($DISCID, 1);
    is $rec->{state}, 'part', 'growing: raste';
    is $c->growing($DISCID, 2), undef, 'growing: samo tekuca';
    is $c->growing('xBFBpdDGyUnu4ofAwN5ZrxozKwM-', 1), undef, 'growing: drugi disk';
    finish($SPAWNS[0]);
    is $rec->{state}, 'done', 'growing: gotova';
    is(($w2->poll(1))[0], 'ready', 'gotova -> ready');
    my $r2 = $c->growing($DISCID, 2);
    $c->stop;
    is $r2->{state}, 'gone', 'growing: prekinuta';
    my $c2 = mk(early => 1);
    $c2->start(mkdisc(), $toc, 1);
    my $r3 = $c2->growing($DISCID, 1);
    { local $SIG{__WARN__} = sub { }; finish($SPAWNS[0], 1) }
    is $r3->{state}, 'gone', 'growing: neuspela';
    $c2->stop;
}

done_testing;
