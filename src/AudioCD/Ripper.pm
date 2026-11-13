package Plugins::AudioCD::Ripper;

# Red za rip-ovanje: provera slobodnog prostora, cyanrip u privremeni folder, premestanje u
# folder albuma, istorija. Cist Perl, bez Slim zavisnosti; spawn i df se ubacuju (testovi).
# Sva imena su Perl karakter stringovi; za fajl sistem se koduju preko Naming::fs_bytes.

use strict;
use warnings;
use utf8;

use Encode ();
use File::Copy ();
use File::Path ();
use JSON::PP ();

use Plugins::AudioCD::DiscId;
use Plugins::AudioCD::Jobs;
use Plugins::AudioCD::Naming;
use Plugins::AudioCD::Profiles;
use Plugins::AudioCD::Tools;

use constant TMP_NAME      => '.audiocd-tmp';
use constant HISTORY_MAX   => 200;
use constant BYTES_PER_SEC => 176400;
use constant RESERVE       => 50 * 1024 * 1024;

my $SEQ = 0;

sub _fs { Plugins::AudioCD::Naming::fs_bytes($_[0]) }

# ---------- pomocne funkcije ----------

# Potrebno mesto: trajanje * 176400 * 0.7 (FLAC) + 50 MiB rezerve.
sub needed_bytes {
    my ($toc) = @_;
    my $lens = Plugins::AudioCD::DiscId::track_lengths($toc);
    my $secs = 0;
    $secs += $_ for values %$lens;
    return int($secs * BYTES_PER_SEC * 0.7) + RESERVE;
}

# Brise ostatke prekinutih rip-ova: <rips>/.audiocd-tmp/*. Poziva se pri startu, dok nista ne radi.
sub cleanup_stale {
    my ($rips_dir) = @_;
    return 0 unless defined $rips_dir && length $rips_dir;
    my $tmp = _fs("$rips_dir/" . TMP_NAME);
    return 0 if -l $tmp || !-d $tmp;
    opendir(my $dh, $tmp) or return 0;
    my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    my $n = 0;
    for my $k (@kids) {
        File::Path::remove_tree("$tmp/$k", { error => \my $err });
        $n++;
    }
    return $n;
}

# df -Pk <dir> bez shell-a, sa rokom (Tools::df_free); slobodni bajtovi ili undef ako se ne moze
# saznati (i kad df ne odgovori u roku: mrtav mrezni mount ne sme da zaustavi LMS).
sub default_df {
    my ($dir) = @_;
    return Plugins::AudioCD::Tools::df_free(_fs($dir));
}

# ---------- objekat ----------

sub new {
    my ($class, %a) = @_;
    my $self = bless {
        spawn        => $a{spawn} || sub { Plugins::AudioCD::Jobs->spawn(@_) },
        df           => $a{df} || \&default_df,
        history_file => (defined $a{history_file} ? _fs($a{history_file}) : undef),
        rename       => $a{rename} || sub { CORE::rename($_[0], $_[1]) },
        on_change    => $a{on_change},
        cyanrip      => $a{cyanrip} || Plugins::AudioCD::Tools::find('cyanrip') || 'cyanrip',
        now          => $a{now} || sub { time },
        current      => undef,
        queue        => [],
        history      => [],
    }, $class;
    $self->_load_history;
    return $self;
}

sub _load_history {
    my ($self) = @_;
    my $f = $self->{history_file};
    return unless defined $f && -f $f;
    open my $fh, '<:raw', $f or return;
    local $/;
    my $text = <$fh>;
    close $fh;
    my $data = eval { JSON::PP->new->utf8->decode($text) };
    $self->{history} = [ @$data[ 0 .. (@$data > HISTORY_MAX ? HISTORY_MAX - 1 : $#$data) ] ]
        if ref $data eq 'ARRAY';
    return;
}

sub _save_history {
    my ($self) = @_;
    my $f = $self->{history_file};
    return unless defined $f && length $f;
    my $tmp = "$f.tmp$$";
    eval {
        (my $dir = $f) =~ s{/[^/]*\z}{};
        File::Path::make_path($dir, { mode => 0755 }) if length $dir && !-d $dir;
        open my $fh, '>:raw', $tmp or die "open: $!\n";
        print {$fh} JSON::PP->new->utf8->canonical->encode($self->{history}) or die "write: $!\n";
        close $fh or die "close: $!\n";
        chmod 0644, $tmp;
        rename $tmp, $f or die "rename: $!\n";
        1;
    } or do {
        unlink $tmp;
        warn "Ripper: istorija nije sacuvana: $@";
    };
    return;
}

sub _notify {
    my ($self) = @_;
    my $cb = $self->{on_change} or return;
    eval { $cb->(); 1 } or warn "Ripper on_change: $@";
    return;
}

# note: 'no_speed' (rip ponovljen bez -S; vazi i kad ponovni pokusaj odustane u _start),
# 'check_offset' (sve pesme AccurateRip mismatch, a disk je u bazi); vise napomena: zarezom.
sub _add_history {
    my ($self, $rec, $result, %extra) = @_;
    my $d = $rec->{disc};
    my @notes = (($rec->{no_speed} ? 'no_speed' : ()), (defined $extra{note} ? $extra{note} : ()));
    delete $extra{note};
    $extra{note} = join ',', @notes if @notes;
    unshift @{ $self->{history} }, {
        id      => $rec->{id},
        time    => $self->{now}->(),
        discid  => $d->{discid},
        artist  => $d->{artist},
        album   => $d->{album},
        profile => $rec->{profile},
        result  => $result,
        (defined $rec->{started} ? (started => $rec->{started}) : ()),
        %extra,
    };
    splice @{ $self->{history} }, HISTORY_MAX if @{ $self->{history} } > HISTORY_MAX;
    $self->_save_history;
    return;
}

# ---------- javni API ----------

sub _free {
    my ($self, $dir) = @_;
    my $free = $self->{df}->($dir);
    warn "Ripper: ne mogu da saznam slobodan prostor za $dir; provera se preskace
" unless defined $free;
    return $free;
}

sub busy {
    my ($self) = @_;
    return ($self->{current} || @{ $self->{queue} }) ? 1 : 0;
}

sub history { return [ @{ $_[0]{history} } ] }

# Posle premestanja u biblioteku istorija pokazuje na novu putanju.
sub update_path {
    my ($self, $id, $path) = @_;
    my ($e) = grep { defined $_->{id} && defined $id && $_->{id} eq $id } @{ $self->{history} };
    return 0 unless $e;
    $e->{path} = $path;
    $e->{moved} = 1;    # u biblioteci (cinjenica sa servera, ne nagadjanje po putanji)
    $self->_save_history;
    return 1;
}

sub _brief {
    my ($rec) = @_;
    return {
        id      => $rec->{id},
        disc    => $rec->{disc}{discid},
        artist  => $rec->{disc}{artist},
        album   => $rec->{disc}{album},
        profile => $rec->{profile},
    };
}

sub status {
    my ($self) = @_;
    my $c = $self->{current};
    return {
        current => $c ? {
            %{ _brief($c) },
            percent       => $c->{percent},
            track         => $c->{track},
            track_percent => $c->{track_percent},
            state         => $c->{cancel} ? 'cancelling' : 'ripping',
            eject_after   => $c->{eject_after} ? 1 : 0,    # cyanrip -Q sam otvara fioku na kraju
        } : undef,
        queue => [ map { _brief($_) } @{ $self->{queue} } ],
    };
}

# enqueue(disc, toc, device, profile, flac_level, rips_dir, quiet_speed, offset, eject_after, cover_src)
#   -> ($job_id, undef) | (undef, { error => 'no_space', needed, free } | { error => 'bad_args'|'rips_dir'|'busy_disc', message })
sub enqueue {
    my ($self, %a) = @_;
    my $disc = $a{disc};
    return (undef, { error => 'bad_args', message => 'disc (sa pesmama), toc i rips_dir su obavezni' })
        unless ref $disc eq 'HASH' && ref $disc->{tracks} eq 'ARRAY' && @{ $disc->{tracks} }
        && ref $a{toc} eq 'HASH' && defined $a{rips_dir} && length $a{rips_dir};

    for my $r ($self->{current} ? $self->{current} : (), @{ $self->{queue} }) {
        return (undef, { error => 'busy_disc', message => 'ovaj disk je vec u redu' })
            if defined $r->{disc}{discid} && defined $disc->{discid} && $r->{disc}{discid} eq $disc->{discid};
    }

    my $rips = $a{rips_dir};
    unless (-d _fs($rips)) {
        eval { File::Path::make_path(_fs($rips), { mode => 0755 }); 1 } or do {
            return (undef, { error => 'rips_dir', message => "ne mogu da napravim $rips" });
        };
    }
    my $needed = needed_bytes($a{toc});
    my $free   = $self->_free($rips);
    return (undef, { error => 'no_space', needed => $needed, free => $free })
        if defined $free && $free < $needed;

    my $id = sprintf('rip-%d-%d', $self->{now}->(), ++$SEQ);
    push @{ $self->{queue} }, {
        id          => $id,
        disc        => $disc,
        toc         => $a{toc},
        device      => $a{device},
        profile     => $a{profile} // 'balanced',
        flac_level  => $a{flac_level},
        rips_dir    => $rips,
        quiet_speed => $a{quiet_speed},
        offset      => $a{offset},
        eject_after => $a{eject_after},
        cover_src   => $a{cover_src},
        tmp         => "$rips/" . TMP_NAME . "/$id",
    };
    $self->_notify;
    $self->_pump;
    return ($id, undef);
}

sub cancel {
    my ($self, $id) = @_;
    return 0 unless defined $id;
    my $c = $self->{current};
    if ($c && $c->{id} eq $id) {
        return 1 if $c->{cancel};
        $c->{cancel} = 'cancelled';
        $c->{job}->kill if $c->{job};
        $self->_notify;
        return 1;
    }
    my ($i) = grep { $self->{queue}[$_]{id} eq $id } 0 .. $#{ $self->{queue} };
    return 0 unless defined $i;
    my ($rec) = splice @{ $self->{queue} }, $i, 1;
    $self->_add_history($rec, 'cancelled');
    $self->_notify;
    return 1;
}

# Otkazuje tekuci i sve u redu (npr. disk izvadjen). $reason ide u istoriju.
sub abort_all {
    my ($self, $reason) = @_;
    $reason = 'aborted' unless defined $reason && length $reason;
    my @q = splice @{ $self->{queue} };
    $self->_add_history($_, 'cancelled', reason => $reason) for @q;
    my $c = $self->{current};
    if ($c && !$c->{cancel}) {
        $c->{cancel} = 'cancelled';
        $c->{reason} = $reason;
        $c->{job}->kill if $c->{job};
    }
    $self->_notify;
    return scalar(@q) + ($c ? 1 : 0);
}

# Gasenje LMS-a: kill_all ne zove callback-ove, pa istoriju za tekuci rip i red upisujemo ovde,
# sinhrono (istorija je na disku pre izlaska). Red se belezi kao 'cancelled' kao i tekuci.
# Ne pokrece nista novo i ne zove on_change.
sub shutdown {
    my ($self, $reason) = @_;
    $reason = 'shutdown' unless defined $reason && length $reason;
    my @q = splice @{ $self->{queue} };
    $self->_add_history($_, 'cancelled', reason => $reason) for @q;
    my $c = $self->{current};
    if ($c && !$c->{finished}++) {
        $self->{current} = undef;
        $c->{job} = undef;
        $self->_add_history($c, 'cancelled', reason => $reason);
    }
    return scalar(@q) + ($c ? 1 : 0);
}

# Marker u tmp folderu rip-a: posle pada (kill -9) pri sledecem startu daje istoriju 'interrupted'.
sub _write_marker {
    my ($self, $rec) = @_;
    my $d = $rec->{disc};
    my $f = _fs($rec->{tmp}) . '/job.json';
    eval {
        open my $fh, '>:raw', $f or die "open: $!\n";
        print {$fh} JSON::PP->new->utf8->canonical->encode({
            id => $rec->{id}, discid => $d->{discid}, artist => $d->{artist}, album => $d->{album},
            profile => $rec->{profile}, started => $rec->{started} // $self->{now}->(),
        }) or die "write: $!\n";
        close $fh or die "close: $!\n";
        1;
    } or warn "Ripper: marker nije upisan: $@";
    return;
}

# Pri startu: za svaki ostatak sa markerom i bez unosa u istoriji upisi error/interrupted, pa
# obrisi ostatke (cleanup_stale). Vraca broj obrisanih foldera.
sub recover_interrupted {
    my ($self, $rips_dir) = @_;
    return 0 unless defined $rips_dir && length $rips_dir;
    my $tmp = _fs("$rips_dir/" . TMP_NAME);
    if (!-l $tmp && -d $tmp && opendir(my $dh, $tmp)) {
        my @kids = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $k (@kids) {
            my $mf = "$tmp/$k/job.json";
            next unless -f $mf;
            my $m = eval { JSON::PP->new->utf8->decode(_slurp($mf)) };
            next unless ref $m eq 'HASH' && defined $m->{id};
            next if grep { defined $_->{id} && $_->{id} eq $m->{id} } @{ $self->{history} };
            $self->_add_history({ id => $m->{id}, profile => $m->{profile},
                disc => { discid => $m->{discid}, artist => $m->{artist}, album => $m->{album} } },
                'error', message => 'interrupted', started => $m->{started});
        }
    }
    return cleanup_stale($rips_dir);
}

# ---------- izvrsavanje ----------

sub _pump {
    my ($self) = @_;
    return if $self->{current} || $self->{starting};
    local $self->{starting} = 1;
    while (!$self->{current} && @{ $self->{queue} }) {
        my $rec = shift @{ $self->{queue} };
        $self->_start($rec);
    }
    return;
}

sub _start {
    my ($self, $rec) = @_;
    $rec->{started}     //= $self->{now}->();    # pocetak ripa (ponovni pokusaj bez -S ga ne menja)
    $rec->{percent}       = 0;
    $rec->{track}         = undef;
    $rec->{track_percent} = 0;
    $rec->{done}          = [];
    $rec->{accurip}       = {};
    $rec->{tail}          = [];

    my $free = $self->_free($rec->{rips_dir});
    my $need = needed_bytes($rec->{toc});
    if (defined $free && $free < $need) {
        $self->_add_history($rec, 'error', message => "no_space: potrebno $need, slobodno $free");
        $self->_notify;
        return;
    }

    my $tmp = _fs($rec->{tmp});
    my $argv = eval {
        File::Path::make_path($tmp, { mode => 0755 });
        die "tmp folder nije napravljen\n" unless -d $tmp;
        my $cover;
        if (defined $rec->{cover_src} && -f _fs($rec->{cover_src})) {
            File::Copy::copy(_fs($rec->{cover_src}), "$tmp/cover.jpg") and $cover = "$rec->{tmp}/cover.jpg";
        }
        $rec->{has_cover} = defined $cover ? 1 : 0;
        $self->_write_marker($rec);
        my @c = Plugins::AudioCD::Profiles::rip_argv(
            cyanrip     => $self->{cyanrip},
            disc        => $rec->{disc},
            device      => $rec->{device},
            profile     => $rec->{profile},
            flac_level  => $rec->{flac_level},
            quiet_speed => $rec->{quiet_speed},
            no_speed    => $rec->{no_speed},
            offset      => $rec->{offset},
            out_dir     => $rec->{tmp},
            cover       => $cover,
        );
        push @c, '-Q' if $rec->{eject_after};
        [@c];
    };
    unless ($argv) {
        $self->_add_history($rec, 'error', message => "priprema: " . ($@ || 'nepoznata greska'));
        $self->_remove_tmp($rec);
        $self->_notify;
        return;
    }

    $self->{current} = $rec;
    my $job = eval {
        $self->{spawn}->(
            argv    => $argv,
            cwd     => _fs($rec->{tmp}),
            umask   => 022,
            on_line => sub { $self->_on_line($rec, $_[0]) },
            on_exit => sub { $self->_on_exit($rec, $_[0]) },
        );
    };
    if (!$job && !$rec->{finished}) {
        my $err = $@ || 'spawn nije vratio posao';
        $self->_finish($rec, 'error', message => "spawn: $err");
        return;
    }
    $rec->{job} = $job unless $rec->{finished};
    $self->_notify;
    return;
}

sub _on_line {
    my ($self, $rec, $line) = @_;
    return if $rec->{finished};
    push @{ $rec->{tail} }, $line;
    shift @{ $rec->{tail} } while @{ $rec->{tail} } > 8;

    my $p = Plugins::AudioCD::Profiles::parse_progress($line) or return;
    my $total = scalar @{ $rec->{disc}{tracks} };
    my $changed = 0;
    if (defined $p->{track}) {
        my $pct = int($p->{percent});
        $changed = 1 if !defined $rec->{track} || $rec->{track} != $p->{track} || $rec->{track_percent} != $pct;
        $rec->{track}         = $p->{track};
        $rec->{track_percent} = $pct;
        $rec->{percent}       = int((@{ $rec->{done} } + $p->{percent} / 100) / $total * 100);
        $rec->{percent}       = 99 if $rec->{percent} > 99;
    }
    elsif (defined $p->{done_track}) {
        push @{ $rec->{done} }, $p->{done_track};
        $rec->{last_done}     = $p->{done_track};
        $rec->{track_percent} = 100;
        $rec->{percent}       = int(@{ $rec->{done} } / $total * 100);
        $rec->{percent}       = 99 if $rec->{percent} > 99;
        $changed = 1;
    }
    elsif (defined $p->{accurip}) {
        # Linije Accurip stizu posle linije zavrsene pesme; pripadaju poslednjoj
        # cyanrip javlja v1 i v2 posebno: pesma je tacna ako se bar jedna slaze
        if (defined $rec->{last_done}) {
            my $cur = $rec->{accurip}{ $rec->{last_done} };
            $rec->{accurip}{ $rec->{last_done} } = $p->{accurip}
                if !defined $cur || $cur eq 'notfound' || $p->{accurip} eq 'match';
        }
        $rec->{accurip_seen}{ $p->{accurip} } = 1;
    }
    $self->_notify if $changed;
    return;
}

sub _on_exit {
    my ($self, $rec, $status) = @_;
    return if $rec->{finished};
    if ($rec->{cancel}) {
        $self->_finish($rec, 'cancelled', defined $rec->{reason} ? (reason => $rec->{reason}) : ());
    }
    elsif ($status != 0 && !$rec->{no_speed} && grep { /does not support changing speeds/i } @{ $rec->{tail} }) {
        # neki USB drajvovi ne menjaju brzinu pa cyanrip staje na -S: ponovi isti rip bez -S
        $rec->{no_speed} = 1;
        $self->{current} = undef;
        $rec->{job}      = undef;
        $self->_remove_tmp($rec);
        $self->_start($rec);
        $self->_pump unless $self->{current};    # _start je mogao da odustane: red ne sme da zastane
    }
    elsif ($status == 0) {
        my %res = eval { $self->_collect($rec) };
        if ($@) {
            my $e = $@;
            chomp $e;
            $self->_finish($rec, 'error', message => "premestanje: $e");
        }
        else {
            $self->_finish($rec, delete $res{result}, %res);
        }
    }
    else {
        $self->_finish($rec, 'error', status => $status, message => join(' | ', @{ $rec->{tail} }));
    }
    return;
}

sub _finish {
    my ($self, $rec, $result, %extra) = @_;
    return if $rec->{finished}++;
    $self->_remove_tmp($rec);
    $self->{current} = undef if $self->{current} && $self->{current} == $rec;
    $rec->{job} = undef;
    $self->_add_history($rec, $result, %extra);
    $self->_notify;
    $self->_pump;
    return;
}

sub _remove_tmp {
    my ($self, $rec) = @_;
    my $tmp = _fs($rec->{tmp});
    File::Path::remove_tree($tmp, { error => \my $err }) if -d $tmp && $tmp =~ m{/\Q@{[ TMP_NAME ]}\E/[^/]+\z};
    return;
}

# Fajlovi u folderu sa datom ekstenzijom (bajt imena), sortirano; $ext undef = svi fajlovi.
# cyanrip: <N>.flac (N bez nula) + jedan .log i .cue sa unicode znakovima u imenu.
sub _glob_files {
    my ($dir, $ext) = @_;
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { $_ ne '.' && $_ ne '..' && -f "$dir/$_" && (!defined $ext || /\.\Q$ext\E\z/i) } readdir $dh;
    closedir $dh;
    return @f;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "ne mogu da citam $path: $!\n";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Premestanje unutar istog fajl sistema (tmp je pod rips folderom); hook $self->{rename} za testove.
sub _move {
    my ($self, $from, $to) = @_;
    $self->{rename}->($from, $to) or die "ne mogu da premestim $from: $!\n";
    return 1;
}

# Gradi album u <tmp>/stage, pa ga jednim rename-om postavlja na odrediste. Greska ne ostavlja
# nista sem sto brise tmp (a to radi pozivalac); nove prazne roditeljske foldere ukloni.
# Vraca (result =>, accurip =>, path =>).
sub _collect {
    my ($self, $rec) = @_;
    my $disc = $rec->{disc};
    my $tmp  = _fs($rec->{tmp});
    my @tracks = @{ $disc->{tracks} };

    for my $t (@tracks) {
        die "nedostaje $t->{n}.flac\n" unless -f "$tmp/$t->{n}.flac";
    }

    my $stage = "$tmp/stage";
    mkdir $stage, 0755 or die "ne mogu da napravim stage: $!\n";

    my (%newname, $log_text);
    $log_text = '';
    for my $t (@tracks) {
        my $name = Plugins::AudioCD::Naming::track_file($disc, $t);
        $newname{ $t->{n} } = $name;
        $self->_move("$tmp/$t->{n}.flac", "$stage/" . _fs($name));
    }
    $self->_move("$tmp/cover.jpg", "$stage/cover.jpg") if -f "$tmp/cover.jpg";

    my $album = Plugins::AudioCD::Naming::sanitize($disc->{album});
    my ($log) = _glob_files($tmp, 'log');
    my ($cue) = _glob_files($tmp, 'cue');
    if (defined $log) {
        $log_text = Encode::decode('UTF-8', _slurp("$tmp/$log"));
        $self->_move("$tmp/$log", "$stage/" . _fs("$album.log"));
    }
    if (defined $cue) {
        my $text = _slurp("$tmp/$cue");
        # cyanrip 0.9 pise ceo put privremenog foldera ispred broja: FILE "var/.../1.flac"
        $text =~ s{(FILE\s+")(?:[^"]*/)?(\d+)(\.flac")}{
            my ($pre, $n, $post) = ($1, $2, $3);
            defined $newname{ $n + 0 } ? $pre . _fs($newname{ $n + 0 }) . '"' : "$pre$n$post"
        }ge;
        my $out = "$stage/" . _fs("$album.cue");
        open my $fh, '>:raw', $out or die "ne mogu da pisem $out: $!\n";
        print {$fh} $text;
        close $fh or die "ne mogu da zatvorim $out: $!\n";
    }

    # cyanrip pravi 0700/0664; Samba i ostali citaoci traze 0755/0644
    chmod 0644, map { "$stage/$_" } _glob_files($stage);
    chmod 0755, $stage;

    my $base = Plugins::AudioCD::Naming::album_dir($rec->{rips_dir}, $disc);
    my $sub  = Plugins::AudioCD::Naming::disc_subdir($disc);
    $base .= "/$sub" if length $sub;
    my $dest   = Plugins::AudioCD::Naming::unique_dir($base, sub { -e _fs($_[0]) });
    my $dest_b = _fs($dest);
    (my $parent = $dest_b) =~ s{/[^/]*\z}{};

    my @created;
    my $ok = eval {
        @created = File::Path::make_path($parent, { mode => 0755 });
        chmod 0755, @created;
        die "folder $dest se u medjuvremenu pojavio\n" if -e $dest_b || -l $dest_b;
        rename $stage, $dest_b or die "ne mogu da postavim $dest: $!\n";
        1;
    };
    unless ($ok) {
        my $e = $@ || 'nepoznata greska';
        rmdir $_ for reverse @created;    # samo prazne, samo koje je ovaj rip napravio
        die $e;
    }

    my %states = %{ $rec->{accurip} };
    my %seen   = (map { $_ => 1 } values %states);
    $seen{notfound} = 1 if $rec->{accurip_seen}{notfound};
    my $overall = $seen{mismatch} ? 'mismatch' : $seen{match} ? 'match' : $seen{notfound} ? 'notfound' : 'none';
    my $sum = Plugins::AudioCD::Profiles::summary($log_text);
    # Disk je u AccurateRip bazi, a nijedna pesma se ne slaze: klasican znak pogresnog ofseta drajva
    # (bez podesenog ofseta cyanrip dobija -s 0). Delimican mismatch je losa kopija, ne ofset.
    my $all_bad = %states && !grep { $_ ne 'mismatch' } values %states;
    return (
        result  => $overall eq 'mismatch' ? 'accurip_mismatch' : 'ok',
        ($all_bad ? (note => 'check_offset') : ()),
        path    => $dest,
        accurip => {
            state  => $overall,
            tracks => { %states },
            ok     => $sum->{accurip_ok},
            total  => $sum->{accurip_total},
        },
    );
}

1;
