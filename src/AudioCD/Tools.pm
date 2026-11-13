package Plugins::AudioCD::Tools;

# Trazenje spoljnih alata (cyanrip, flac, ...). Cist Perl, bez Slim zavisnosti.
# Redosled: /usr/bin, /bin, pa PATH. Neizvrsni fajlovi i direktorijumi se preskacu.

use strict;
use warnings;
use utf8;

use POSIX ();
use Time::HiRes ();

our %PACKAGE = (
	'cyanrip'     => 'cyanrip',
	'cd-paranoia' => 'cd-paranoia',
	'flac'        => 'flac',
	'cd-info'     => 'libcdio-utils',
	'eject'       => 'eject',
);

sub default_dirs {
	my @dirs = ('/usr/bin', '/bin');
	push @dirs, grep { length } split /:/, ($ENV{PATH} // '');
	my %seen;
	return grep { !$seen{$_}++ } @dirs;
}

# find($name, dirs => [...]) -> $path | undef
sub find {
	my ($name, %opt) = @_;
	return undef unless defined $name && length $name && $name !~ m{/};
	my @dirs = $opt{dirs} ? @{ $opt{dirs} } : default_dirs();
	for my $dir (@dirs) {
		my $p = "$dir/$name";
		return $p if -f $p && -x _;
	}
	return undef;
}

# df_free($dir, df => $putanja, timeout => $s) -> slobodni bajtovi | undef (nepoznato)
# df -Pk bez shell-a. Citanje ima rok (podrazumevano DF_TIMEOUT s): df na mrtvom mreznom mount-u
# visi (i u D stanju, kad ga ni kill ne gasi), a poziva se iz LMS petlje. Posle roka se dete
# ubija, cevi se zatvara bez cekanja na proces (bez waitpid koji bi blokirao) i vraca se undef.
use constant DF_TIMEOUT => 5;

sub df_free {
	my ($dir, %o) = @_;
	return undef unless defined $dir && length $dir;
	my $df = $o{df} || find('df') || 'df';
	my $limit = $o{timeout} || DF_TIMEOUT;
	pipe(my $r, my $w) or return undef;
	my $pid = fork;
	unless (defined $pid) { close $r; close $w; return undef }
	if (!$pid) {
		# dete nikad ne sme da izadje iz ovog bloka (u LMS-u bi nastavilo kao kopija servera)
		eval {
			close $r;
			untie *STDOUT if tied *STDOUT;
			untie *STDERR if tied *STDERR;    # LMS vezuje STDERR za logger (tie bez OPEN)
			open(STDOUT, '>&', $w) or die;
			open(STDERR, '>', '/dev/null');
			local $ENV{LC_ALL} = 'C';
			exec { $df } $df, '-Pk', $dir;
		};
		POSIX::_exit(127);
	}
	close $w;
	my ($out, $deadline, $done) = ('', Time::HiRes::time() + $limit, 0);
	while (1) {
		my $left = $deadline - Time::HiRes::time();
		last if $left <= 0;
		my $rin = '';
		vec($rin, fileno($r), 1) = 1;
		my $n = select(my $rout = $rin, undef, undef, $left);
		next if $n < 0 && $!{EINTR};
		last if $n <= 0;
		my $got = sysread($r, my $buf, 4096);
		next if !defined $got && $!{EINTR};
		if (!$got) { $done = 1; last }
		$out .= $buf;
	}
	close $r;
	unless ($done) {
		kill 'KILL', $pid;
		waitpid($pid, POSIX::WNOHANG());
		return undef;
	}
	waitpid($pid, 0);    # df je zatvorio izlaz, pa vec izlazi (ako ga EV nije vec pokupio)
	my @lines = split /\n/, $out;
	return undef unless @lines >= 2;
	my @f = split ' ', $lines[1];
	return undef unless @f >= 4 && $f[3] =~ /^\d+\z/;
	return $f[3] * 1024;
}

# missing(@names) -> @names koji se ne nalaze
sub missing {
	my (@names) = @_;
	return grep { !defined find($_) } @names;
}

1;
