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

sub _copy_tree {
	my ($src, $dest, $deadline) = @_;
	mkdir _fs($dest), 0755 or die "mkdir: $!\n";
	my $items = _walk($src, '', []);
	for my $it (@$items) {
		die "timeout\n" if time() > $deadline;
		my ($type, $r) = @$it;
		if ($type eq 'd') { mkdir _fs("$dest/$r"), 0755 or die "mkdir: $!\n" }
		else {
			File::Copy::copy(_fs("$src/$r"), _fs("$dest/$r")) or die "copy $r: $!\n";
			chmod 0644, _fs("$dest/$r");
		}
	}
	_verify_tree($src, $dest, $items);
	return 1;
}

# Svaki fajl iz izvora mora postojati na odredistu iste velicine.
sub _verify_tree {
	my ($src, $dest, $items) = @_;
	$items ||= _walk($src, '', []);
	for my $it (grep { $_->[0] eq 'f' } @$items) {
		my $r = $it->[1];
		my ($a, $b) = ((-s _fs("$src/$r")), (-s _fs("$dest/$r")));
		die "verify $r\n" unless defined $a && defined $b && $a == $b;
	}
	return 1;
}

sub _rmdirs { rmdir _fs($_) for reverse @_; return }

# move($src, $dest, timeout => 60, rename => sub) -> ($ok, $err)
sub move {
	my ($src, $dest, %o) = @_;
	my $rename = $o{rename} || sub { CORE::rename($_[0], $_[1]) };
	my $deadline = time() + ($o{timeout} // 60);
	my ($s, $d) = (_fs($src), _fs($dest));
	return (undef, 'not_found') unless -d $s;
	return (undef, 'exists') if -e $d || -l $d;

	# roditeljski folderi odredista (pamti koje smo napravili, za ciscenje pri gresci)
	(my $parent = $dest) =~ s{/[^/]*\z}{};
	my @missing;
	for (my $p = $parent; length $p && !-d _fs($p); $p =~ s{/[^/]*\z}{}) { unshift @missing, $p }
	my @made;
	for my $p (@missing) {
		unless (mkdir _fs($p), 0755) { _rmdirs(@made); return (undef, 'mkdir_failed') }
		push @made, $p;
	}

	$! = 0;
	return (1, undef) if $rename->($s, $d);
	my $errno = $! + 0;
	unless ($errno == POSIX::EXDEV()) {
		_rmdirs(@made);
		return (undef, 'move_failed');
	}

	# razlicit fajl sistem: kopija, provera velicina, pa brisanje izvora
	my $ok  = eval { _copy_tree($src, $dest, $deadline) };
	my $why = $@;
	unless ($ok) {
		File::Path::remove_tree($d, { error => \my $e }) if -e $d;
		_rmdirs(@made);
		$why =~ s/\n\z//;
		return (undef, $why =~ /^timeout/ ? 'timeout' : $why =~ /^verify/ ? 'verify_failed' : 'copy_failed');
	}
	File::Path::remove_tree($s, { error => \my $err });
	return (undef, 'source_not_removed') if -e $s;
	return (1, undef);
}

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

# move_async($src, $dest, spawn => sub(\@argv, $on_exit->($status)), on_done => sub($ok, $err), rename => sub)
# Isti FS: rename odmah (jedna operacija nad direktorijumom). Pri EXDEV kopiranje ide u spoljnom
# procesu (cp -a u $dest.part-<pid>), da LMS petlja ne blokira dok se stotine MB pisu na disk koji
# se budi. Posle cp: provera velicina, rename .part -> $dest, brisanje izvora. Na gresku se brise
# delimicna kopija, izvor ostaje. on_done se poziva tacno jednom.
sub move_async {
	my ($src, $dest, %o) = @_;
	my $cb = $o{on_done} || sub { };
	my $called;
	my $done = sub { return if $called++; return $cb->(@_) };
	my $rename = $o{rename}  || sub { CORE::rename($_[0], $_[1]) };
	my ($s, $d) = (_fs($src), _fs($dest));
	return $done->(undef, 'not_found') unless -d $s;
	return $done->(undef, 'exists') if -e $d || -l $d;
	my $made = _make_parents($dest) or return $done->(undef, 'mkdir_failed');

	$! = 0;
	return $done->(1, undef) if $rename->($s, $d);
	my $errno = $! + 0;
	my $spawn = $o{spawn};
	unless ($errno == POSIX::EXDEV() && $spawn) {
		_rmdirs(@$made);
		return $done->(undef, 'move_failed');
	}

	my $part = "$dest.part-$$";
	my $pb   = _fs($part);
	my $fail = sub {
		my ($code) = @_;
		File::Path::remove_tree($pb, { error => \my $e }) if -e $pb || -l $pb;
		_rmdirs(@$made);
		return $done->(undef, $code);
	};
	my $started = eval {
		$spawn->([ 'cp', '-a', '--', $s, $pb ], sub {
			my ($status) = @_;
			return $fail->('copy_failed') if $status;
			return $fail->('verify_failed') unless eval { _verify_tree($src, $part); 1 };
			return $fail->('move_failed') unless CORE::rename($pb, $d);
			File::Path::remove_tree($s, { error => \my $e });
			return $done->(undef, 'source_not_removed') if -e $s;
			return $done->(1, undef);
		});
		1;
	};
	return $fail->('copy_failed') unless $started;
	return;
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
