package Plugins::AudioCD::Tools;

# Trazenje spoljnih alata (cyanrip, flac, ...). Cist Perl, bez Slim zavisnosti.
# Redosled: /usr/bin, /bin, pa PATH. Neizvrsni fajlovi i direktorijumi se preskacu.

use strict;
use warnings;
use utf8;

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

# missing(@names) -> @names koji se ne nalaze
sub missing {
	my (@names) = @_;
	return grep { !defined find($_) } @names;
}

1;
