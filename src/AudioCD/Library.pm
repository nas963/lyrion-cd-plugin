package Plugins::AudioCD::Library;

# Premesti u biblioteku: gotov rip iz CD-Rips ide u folder biblioteke (isti raspored
# <Izvodjac>/<Album>), pa se skenira samo taj folder. Cist Perl, bez Slim zavisnosti.
# Putanje su Perl karakter stringovi; za fajl sistem se koduju preko Naming::fs_bytes.
# Nikad se ne prepisuje: ako odrediste postoji, nista se ne menja.

use strict;
use warnings;
use utf8;

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

# Svi fajlovi i folderi ispod $dir (relativno), folderi pre sadrzaja.
sub _walk {
	my ($dir, $rel, $out) = @_;
	my $here = length $rel ? "$dir/$rel" : $dir;
	opendir my $dh, _fs($here) or die "opendir: $!\n";
	my @kids = sort grep { !/^\.\.?\z/ } readdir $dh;
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
# procesu (cp -a u skriveni .part), da LMS petlja ne blokira dok se stotine MB pisu na disk koji se
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
		$spawn->([ 'cp', '-a', '--', $s, $pb ], sub {
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

1;
