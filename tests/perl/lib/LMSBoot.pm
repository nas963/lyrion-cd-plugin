package LMSBoot;

# Za testove koji ucitavaju Slim::* (Ruling 6): LMS -I putanje i boot kod (konstante iz
# slimserver-a u main:: + OSDetect). Slim se ucitava u zasebnom perl procesu, jer LMS CPAN
# nosi star Test::More koji bi zasenio sistemski.

use strict;
use warnings;
use utf8;

my $LMS = '/usr/share/squeezeboxserver';

sub inc {
	my $v = sprintf('%d.%d', $^V->{version}[0], $^V->{version}[1]);
	return ('lib', "$LMS/CPAN/arch/$v", "$LMS/CPAN/arch/$v/x86_64-linux-thread-multi", "$LMS/CPAN",
		"$LMS/lib", $LMS, '/usr/share/perl5');
}

# Perl kod (za -e) koji pripremi main:: i OSDetect, pa izvrsi $code.
sub boot {
	my ($code) = @_;
	return q{BEGIN { require constant; constant->import({ SCANNER => 0, RESIZER => 0, ISWINDOWS => 0, ISMAC => 0, TRANSCODING => 1, PERFMON => 0, DEBUGLOG => 1, INFOLOG => 1, STATISTICS => 1, SB1SLIMP3SYNC => 0, WEBUI => 1, NOMYSB => 1, LOCALFILE => 0, NOBROWSECACHE => 0, SLIM_SERVICE => 0, NOUPNP => 0, ISACTIVEPERL => 0, HAS_AIO => 0 }) } require Slim::Utils::OSDetect; Slim::Utils::OSDetect::init(); } . $code;
}

sub _q { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }    # ' -> '\'' (u zameni \\ je jedna kosa crta)

# run($code, @args) -> izlaz (stdout+stderr) perl procesa sa LMS putanjama i boot kodom.
sub run {
	my ($code, @args) = @_;
	my $cmd = join ' ', 'perl', (map { '-I ' . _q($_) } inc()), '-e', _q(boot($code)), map { _q($_) } @args;
	return scalar `$cmd 2>&1`;
}

# Proverava da se modul ucitava u LMS okruzenju; vraca izlaz ("<fajl> syntax OK" na uspeh).
sub syntax {
	my ($file) = @_;
	return run(q{my $f = shift; require "./$f"; print qq{$f syntax OK\n};}, $file);
}

1;
