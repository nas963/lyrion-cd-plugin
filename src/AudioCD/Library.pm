package Plugins::AudioCD::Library;

# Premesti u biblioteku: gotov rip iz CD-Rips ide u folder biblioteke (isti raspored
# <Izvodjac>/<Album>), pa se skenira samo taj folder. Cist Perl, bez Slim zavisnosti.
# Putanje su Perl karakter stringovi; za fajl sistem se koduju preko Naming::fs_bytes.
# Nikad se ne prepisuje: ako odrediste postoji, nista se ne menja.

use strict;
use warnings;
use utf8;

use Encode ();
use File::Copy ();
use File::Path ();
use POSIX ();

use Plugins::AudioCD::Naming;

sub _fs { Plugins::AudioCD::Naming::fs_bytes($_[0]) }

sub _clean {
	my ($p) = @_;
	$p =~ s{/+}{/}g;
	$p =~ s{(?<=.)/\z}{};
	return $p;
}

# library_dir($iz_zahteva, $iz_prefs, \@muzicki_folderi) -> ($dir, undef) | (undef, 'bad_args'|'outside_library')
# Folder biblioteke: zahtev, pa pref, pa prvi LMS muzicki folder; apsolutan, bez '..', ispod muzickog foldera.
sub library_dir {
	my ($req, $pref, $media) = @_;
	my @m = map { _clean($_) } grep { defined && length } @{ $media || [] };
	my $lib = defined $req && length $req ? $req : defined $pref && length $pref ? $pref : $m[0];
	return (undef, 'bad_args') unless defined $lib && $lib =~ m{^/} && $lib !~ m{(?:^|/)\.\.(?:/|\z)};
	$lib = _clean($lib);
	return (undef, 'outside_library') unless grep { $lib eq $_ || index($lib, "$_/") == 0 } @m;
	return ($lib, undef);
}

# plan_move($src_album_dir, $library_dir, $rips_root) -> ($dest, $err)
sub plan_move {
	my ($src, $lib, $rips) = @_;
	return (undef, 'outside_rips')
		unless defined $src && defined $lib && defined $rips && length $src && length $lib && length $rips;
	($src, $lib, $rips) = map { _clean($_) } ($src, $lib, $rips);
	return (undef, 'outside_rips') if $src =~ m{(?:^|/)\.\.?(?:/|\z)};
	return (undef, 'outside_rips') unless index($src, "$rips/") == 0 && length($src) > length($rips) + 1;
	my $rel = substr($src, length($rips) + 1);
	return (undef, 'not_found') unless -d _fs($src);
	my $dest = "$lib/$rel";
	return (undef, 'exists') if -e _fs($dest) || -l _fs($dest);
	return ($dest, undef);
}

# ---------- izbor odredista (pregled foldera biblioteke) ----------

# Putanja je ispravna i lezi u nekom muzickom folderu (ili je to sam muzicki folder).
# -> ociscena putanja | undef
sub in_library {
	my ($path, $media) = @_;
	return undef unless defined $path && $path =~ m{^/} && $path !~ m{(?:^|/)\.\.?(?:/|\z)} && $path !~ /[\x00-\x1f]/;
	my $p = _clean($path);
	my @m = map { _clean($_) } grep { defined && length } @{ $media || [] };
	return (grep { $p eq $_ || index($p, "$_/") == 0 } @m) ? $p : undef;
}

# browse($path, \@muzicki_folderi, limit => 5000)
# -> ({ path, parent, roots => [...], dirs => [ { name, path } ], truncated }, undef) | (undef, $err)
# Bez putanje: koreni su muzicki folderi. Skriveni folderi (.xxx) se ne prikazuju. Sortirano bez obzira
# na velika/mala slova.
sub browse {
	my ($path, $media, %o) = @_;
	my @m = map { _clean($_) } grep { defined && length } @{ $media || [] };
	return (undef, 'no_library') unless @m;
	if (!defined $path || !length $path) {
		return ({ path => '', parent => undef, roots => \@m, dirs => [ map { { name => $_, path => $_ } } grep { -d _fs($_) } @m ] }, undef);
	}
	my $p = in_library($path, \@m) or return (undef, 'outside_library');
	opendir(my $dh, _fs($p)) or return (undef, 'not_found');
	my @names;
	while (defined(my $n = readdir $dh)) {
		next if $n =~ /\A\./;
		my $full = _fs($p) . "/$n";
		next unless -d $full;
		my $dec = eval { Encode::decode('UTF-8', $n, Encode::FB_CROAK | Encode::LEAVE_SRC) };
		push @names, defined $dec ? $dec : Encode::decode('ISO-8859-1', $n);
	}
	closedir $dh;
	@names = sort { lc($a) cmp lc($b) || $a cmp $b } @names;
	my $limit = $o{limit} || 5000;
	my $trunc = @names > $limit ? 1 : 0;
	splice(@names, $limit) if $trunc;
	my $parent;
	unless (grep { $_ eq $p } @m) { ($parent = $p) =~ s{/[^/]*\z}{} }
	return ({ path => $p, parent => $parent, roots => \@m, dirs => [ map { { name => $_, path => "$p/$_" } } @names ],
		truncated => $trunc }, undef);
}

# make_dir($parent, $name, \@muzicki_folderi) -> ($nova_putanja, undef) | (undef, $err)
# Ime prolazi kroz Naming::sanitize (bezbedno za Windows/Sambu); postojeci folder je ok (vraca se).
sub make_dir {
	my ($parent, $name, $media) = @_;
	my $p = in_library($parent, $media) or return (undef, 'outside_library');
	return (undef, 'bad_name') unless defined $name && $name =~ /\S/;
	my $clean = Plugins::AudioCD::Naming::sanitize($name);
	my $dest = "$p/$clean";
	return ($dest, undef) if -d _fs($dest);
	return (undef, 'exists') if -e _fs($dest);
	return (undef, 'not_found') unless -d _fs($p);
	mkdir(_fs($dest), 0755) or return (undef, 'mkdir_failed');
	return ($dest, undef);
}

# plan_move_to($src_album_dir, $odredisni_folder, $ime, $rips_root, \@muzicki_folderi) -> ($dest, $err)
# Odrediste je <izabrani folder>/<ime> (ime podrazumevano = ime foldera rip-a); nikad se ne prepisuje.
sub plan_move_to {
	my ($src, $dir, $name, $rips, $media) = @_;
	return (undef, 'outside_rips') unless defined $src && defined $rips && length $src && length $rips;
	($src, $rips) = map { _clean($_) } ($src, $rips);
	return (undef, 'outside_rips') if $src =~ m{(?:^|/)\.\.?(?:/|\z)};
	return (undef, 'outside_rips') unless index($src, "$rips/") == 0 && length($src) > length($rips) + 1;
	return (undef, 'not_found') unless -d _fs($src);
	my $d = in_library($dir, $media) or return (undef, 'outside_library');
	return (undef, 'not_found') unless -d _fs($d);
	# npr. muzika sa mreznog deljenja (AudioOS ga montira samo za citanje): odmah jasna greska, ne posle kopiranja
	return (undef, 'not_writable') unless -w _fs($d);
	(my $base = $src) =~ s{\A.*/}{};
	my $n = defined $name && $name =~ /\S/ ? Plugins::AudioCD::Naming::sanitize($name) : $base;
	my $dest = "$d/$n";
	return (undef, 'same') if $dest eq $src;
	return (undef, 'exists') if -e _fs($dest) || -l _fs($dest);
	return ($dest, undef);
}

# Svi fajlovi i folderi ispod $dir (relativno), folderi pre sadrzaja.
sub _walk {
	my ($dir, $rel, $out) = @_;
	my $here = length $rel ? "$dir/$rel" : $dir;
	opendir my $dh, _fs($here) or die "opendir: $!\n";
	# imena su bajtovi: dekodiraj, da se _fs() kasnije ne primeni dvaput (nevalidan UTF-8 = greska, izvor ostaje)
	my @kids = sort map { Encode::decode('UTF-8', $_, Encode::FB_CROAK | Encode::LEAVE_SRC) } grep { !/^\.\.?\z/ } readdir $dh;
	closedir $dh;
	for my $k (@kids) {
		my $r = length $rel ? "$rel/$k" : $k;
		my $p = _fs("$dir/$r");
		if (-d $p && !-l $p) { push @$out, [ 'd', $r ]; _walk($dir, $r, $out) }
		else                 { push @$out, [ 'f', $r ] }
	}
	return $out;
}

# Svaki fajl iz izvora mora postojati na odredistu iste velicine.
sub _verify_tree {
	my ($src, $dest) = @_;
	my $items = _walk($src, '', []);
	for my $it (grep { $_->[0] eq 'f' } @$items) {
		my $r = $it->[1];
		my ($a, $b) = ((-s _fs("$src/$r")), (-s _fs("$dest/$r")));
		die "verify $r\n" unless defined $a && defined $b && $a == $b;
	}
	return 1;
}

sub _rmdirs { rmdir _fs($_) for reverse @_; return }

# Roditeljski folderi odredista; vraca \@napravljeni (za ciscenje) ili prazno pri gresci.
sub _make_parents {
	my ($dest) = @_;
	(my $parent = $dest) =~ s{/[^/]*\z}{};
	my @missing;
	for (my $p = $parent; length $p && !-d _fs($p); $p =~ s{/[^/]*\z}{}) { unshift @missing, $p }
	my @made;
	for my $p (@missing) {
		unless (mkdir _fs($p), 0755) { _rmdirs(@made); return }
		push @made, $p;
	}
	return \@made;
}

my %ACTIVE;    # odredista u toku (guard) -> 1
my %PART;      # .part folderi u toku (sweep ih ne dira) -> 1
my $SEQ = 0;

# Skriveno, jedinstveno ime kopije: <roditelj>/.<Album>.part-<pid>-<brojac> (skener preskace skrivene).
sub part_path {
	my ($dest) = @_;
	my ($parent, $name) = $dest =~ m{\A(.*)/([^/]*)\z} ? ($1, $2) : ('', $dest);
	return "$parent/.$name.part-$$-" . ++$SEQ;
}

# Brise zaostale .part folderi (stari prekinuti prenosi) u $parent, osim onih koji su u toku.
sub sweep_parts {
	my ($parent) = @_;
	my $pb = _fs($parent);
	opendir my $dh, $pb or return 0;
	my @old = grep { /\A\..*\.part-\d+-\d+\z/ } readdir $dh;
	closedir $dh;
	my $n = 0;
	for my $name (@old) {
		my $full = "$pb/$name";
		next if $PART{$full};
		next unless -d $full && !-l $full;
		File::Path::remove_tree($full, { error => \my $e });
		$n++;
	}
	return $n;
}

# Posle premestanja: prazan folder izvodjaca u CD-Rips se uklanja (rmdir, nikad rekurzivno;
# nikad sam rips koren).
sub _prune_empty {
	my ($src, $rips) = @_;
	return unless defined $rips && length $rips;
	($src, $rips) = map { _clean($_) } ($src, $rips);
	my $p = $src;
	while ($p =~ s{/[^/]*\z}{} && length($p) > length($rips) && index($p, "$rips/") == 0) {
		last unless rmdir _fs($p);
	}
	return;
}

# move_async($src, $dest, spawn => sub(\@argv, $on_exit->($status)), on_done => sub($ok, $err, $warn),
#            rename => sub, rips_root => $dir)
# Isti FS: rename odmah (jedna operacija nad direktorijumom). Pri EXDEV kopiranje ide u spoljnom
# procesu (cp -R u skriveni .part), da LMS petlja ne blokira dok se stotine MB pisu na disk koji se
# budi. Posle cp: provera velicina, ponovna provera odredista (rename bi tiho zamenio prazan folder),
# rename .part -> $dest, brisanje izvora. Na gresku se brise delimicna kopija, izvor ostaje.
# Ako izvor posle provere kopije ne moze da se obrise: uspeh sa upozorenjem 'source_not_removed'.
# on_done se poziva tacno jednom; izuzetak u njemu nikad ne menja ishod premestanja.
sub move_async {
	my ($src, $dest, %o) = @_;
	my $cb = $o{on_done} || sub { };
	my ($called, $owned, $made_ref);
	my $done = sub {
		return if $called++;
		delete $ACTIVE{$dest} if $owned;
		eval { $cb->(@_); 1 } or warn "Library on_done: $@";
		return;
	};
	my $rename = $o{rename} || sub { CORE::rename($_[0], $_[1]) };
	my ($s, $d) = (_fs($src), _fs($dest));
	return $done->(undef, 'busy') if $ACTIVE{$dest};
	return $done->(undef, 'not_found') unless -d $s;
	return $done->(undef, 'exists') if -e $d || -l $d;
	$ACTIVE{$dest} = $owned = 1;
	$made_ref = _make_parents($dest) or do { $done->(undef, 'mkdir_failed'); return };
	(my $parent = $dest) =~ s{/[^/]*\z}{};
	sweep_parts($parent);

	$! = 0;
	if ($rename->($s, $d)) {
		_prune_empty($src, $o{rips_root});
		return $done->(1, undef);
	}
	my $errno = $! + 0;
	my $spawn = $o{spawn};
	unless ($errno == POSIX::EXDEV() && $spawn) {
		_rmdirs(@$made_ref);
		return $done->(undef, 'move_failed');
	}

	my $part = part_path($dest);
	my $pb   = _fs($part);
	$PART{$pb} = 1;
	my $fail = sub {
		my ($code) = @_;
		File::Path::remove_tree($pb, { error => \my $e }) if -e $pb || -l $pb;
		delete $PART{$pb};
		_rmdirs(@$made_ref);
		return $done->(undef, $code);
	};
	my $started = eval {
		# cp -R bez -a/-p: vlasnik i prava se ne prenose. Na exFAT/NTFS (AudioOS muzicki disk, mount sa
		# uid=/umask=) chown nije dozvoljen, pa je cp -a zavrsavao greskom ("failed to preserve ownership")
		# iako su fajlovi kopirani -> copy_failed. Kopija dobija prava odredista (umask procesa).
		$spawn->([ 'cp', '-R', '--', $s, $pb ], sub {
			my ($status) = @_;
			return $fail->('copy_failed') if $status;
			return $fail->('verify_failed') unless eval { _verify_tree($src, $part); 1 };
			return $fail->('exists') if -e $d || -l $d;
			return $fail->('move_failed') unless CORE::rename($pb, $d);
			delete $PART{$pb};
			File::Path::remove_tree($s, { error => \my $e });
			if (-e $s) { return $done->(1, undef, 'source_not_removed') }
			_prune_empty($src, $o{rips_root});
			return $done->(1, undef);
		});
		1;
	};
	return $fail->('copy_failed') unless $started;
	return;
}

# move($src, $dest, rename => sub, rips_root => $dir) -> ($ok, $err, $warn)
# Sinhrono, samo isti fajl sistem (jedan rename); preko FS granice javlja 'move_failed' (za to
# postoji move_async).
sub move {
	my ($src, $dest, %o) = @_;
	my @r;
	move_async($src, $dest, %o, spawn => undef, on_done => sub { @r = @_ });
	return @r;
}

# CLI za skeniranje samo tog foldera: Slim::Control::Commands::rescanCommand uzima 'full' + file URL
# (_target) kao singledir. URL je UTF-8 procenat-kodiran.
sub rescan_cmd {
	my ($dest) = @_;
	my $url = _fs($dest);
	$url =~ s{([^A-Za-z0-9_.~/-])}{sprintf '%%%02X', ord $1}ge;
	return [ 'rescan', 'full', "file://$url" ];
}

use constant RESCAN_STEP => 30;      # s izmedju provera da li LMS jos skenira
use constant RESCAN_MAX  => 1800;    # s, najduze cekanje

# rescan_when_idle($dest, still_scanning => sub, timer => sub($s, $cb), run => sub(\@cmd), log => sub($msg))
# LMS preskace (bez poruke) rescan dok traje drugo skeniranje: tada se ceka da skeniranje zavrsi
# (provera na RESCAN_STEP s, najvise RESCAN_MAX s), pa se skenira samo taj folder; posle roka odustaje.
sub rescan_when_idle {
	my ($dest, %o) = @_;
	my $cmd = rescan_cmd($dest);
	my $log = $o{log} || sub { };
	my $waited = 0;
	my $try;
	$try = sub {
		unless ($o{still_scanning}->()) {
			undef $try;
			return $o{run}->($cmd);
		}
		if ($waited >= RESCAN_MAX) {
			undef $try;
			return $log->("skeniranje $dest nije pokrenuto: LMS skenira duze od " . RESCAN_MAX . " s, odustajem");
		}
		$log->("skeniranje $dest ceka da LMS zavrsi tekuce skeniranje") unless $waited;
		$waited += RESCAN_STEP;
		$o{timer}->(RESCAN_STEP, $try);
	};
	$try->();
	return;
}

1;
