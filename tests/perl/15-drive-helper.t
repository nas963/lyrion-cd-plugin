use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP ();
use File::Spec ();

use lib 'lib';
BEGIN { use_ok('Plugins::AudioCD::DriveHelper') }

my $H = 'Plugins::AudioCD::DriveHelper';
my $TOC = { first => 1, last => 2, leadout => 9000, tracks => [ { n => 1, lba => 0, data => 0 }, { n => 2, lba => 4500, data => 0 } ] };

# lazne ioctl funkcije: beleze pozive, vracaju ono sto je u $w
sub mk {
	my (%o) = @_;
	my $w = { status => [ 4, undef ], toc => [ $TOC, undef ], eject => [ 1, undef ], calls => [], out => [] };
	$w->{h} = $H->new(
		dev    => '/dev/sr0',
		poll   => $o{poll} // 2,
		paused => $o{paused},
		status => sub { push @{ $w->{calls} }, [ status => @_ ]; @{ $w->{status} } },
		toc    => sub { push @{ $w->{calls} }, [ toc => @_ ]; @{ $w->{toc} } },
		eject  => sub { push @{ $w->{calls} }, [ eject => @_ ]; @{ $w->{eject} } },
		out    => sub { push @{ $w->{out} }, $_[0] },
	);
	return $w;
}
sub events { my ($w) = @_; my @e = map { JSON::PP->new->decode($_) } @{ $w->{out} }; @{ $w->{out} } = (); return @e }
sub cmd { my ($w, $h) = @_; return $w->{h}->handle_line(JSON::PP->new->encode($h)) }

# ---- polling: status na startu, pa samo na promenu ----
{
	my $w = mk();
	$w->{h}->tick;
	my @e = events($w);
	is_deeply(\@e, [ { ev => 'status', code => 4 } ], 'start: status jednom');
	is_deeply($w->{calls}[0], [ status => '/dev/sr0' ], 'status za uredjaj');
	$w->{h}->tick;
	is_deeply([ events($w) ], [], 'isti status: nema dogadjaja');
	$w->{status} = [ 2, undef ];
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 2 } ], 'promena: dogadjaj');
	$w->{status} = [ undef, 'permission' ];
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => undef, err => 'permission' } ], 'greska drajva: code null, err');
	$w->{h}->tick;
	is_deeply([ events($w) ], [], 'ista greska: nema dogadjaja');
}

# ---- izlaz: jedna linija JSON-a, ASCII ----
{
	my $w = mk();
	$w->{h}->tick;
	like($w->{out}[0], qr/\A\{[^\n]*\}\n\z/, 'dogadjaj je jedna JSON linija sa \n');
}

# ---- pause / resume ----
{
	my $w = mk();
	$w->{h}->tick;
	events($w);
	cmd($w, { cmd => 'pause' });
	my $n = @{ $w->{calls} };
	$w->{status} = [ 1, undef ];
	$w->{h}->tick;
	is(scalar @{ $w->{calls} }, $n, 'pauza: nema ioctl-a');
	is_deeply([ events($w) ], [], 'pauza: nema dogadjaja');
	ok($w->{h}->paused, 'paused');
	cmd($w, { cmd => 'resume' });
	ok(!$w->{h}->paused, 'resume');
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 1 } ], 'resume: novi status');
	# resume: status se salje i ako se nije promenio (dogadjaj tokom posla je mozda propusten)
	cmd($w, { cmd => 'pause' });
	cmd($w, { cmd => 'resume' });
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 1 } ], 'resume: status ponovljen i bez promene');
}

# ---- pokretanje u pauzi: prvi status tek posle resume ----
{
	my $w = mk(paused => 1);
	$w->{h}->tick;
	is(scalar @{ $w->{calls} }, 0, 'start u pauzi: nema ioctl-a');
	cmd($w, { cmd => 'resume' });
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 4 } ], 'start u pauzi: status posle resume');
}

# ---- polling iskljucen: samo status na startu, zahtevi i dalje rade ----
{
	my $w = mk(poll => 0);
	ok(!defined $w->{h}->interval, 'poll 0: nema periodicnog tick-a');
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 4 } ], 'poll 0: status jednom na startu');
	$w->{status} = [ 2, undef ];
	$w->{h}->tick;
	is_deeply([ events($w) ], [], 'poll 0: nema periodicnog statusa');
	cmd($w, { cmd => 'pause' });
	cmd($w, { cmd => 'resume' });
	$w->{h}->tick;
	is_deeply([ events($w) ], [], 'poll 0: ni posle resume');
	cmd($w, { cmd => 'status', id => 7 });
	is_deeply([ events($w) ], [ { ev => 'status', id => 7, code => 2 } ], 'poll 0: status na zahtev');
	cmd($w, { cmd => 'config', poll => 2 });
	is($w->{h}->interval, 2, 'config: polling ukljucen');
	$w->{h}->tick;
	is_deeply([ events($w) ], [ { ev => 'status', code => 2 } ], 'config: polling ponovo javlja status');
}

# ---- TOC na zahtev ----
{
	my $w = mk();
	cmd($w, { cmd => 'toc', id => 3 });
	is_deeply([ events($w) ], [ { ev => 'toc', id => 3, toc => $TOC } ], 'toc: odgovor sa id-om');
	is_deeply($w->{calls}[-1], [ toc => '/dev/sr0' ], 'toc: podrazumevani uredjaj');
	cmd($w, { cmd => 'toc', id => 4, dev => '/dev/sr1' });
	is_deeply($w->{calls}[-1], [ toc => '/dev/sr1' ], 'toc: uredjaj iz zahteva');
	events($w);
	$w->{toc} = [ undef, 'no_disc' ];
	cmd($w, { cmd => 'toc', id => 5 });
	is_deeply([ events($w) ], [ { ev => 'toc', id => 5, toc => undef, err => 'no_disc' } ], 'toc: greska');
	# TOC radi i u pauzi (Plugin salje zahtev samo kad je drajv slobodan)
	cmd($w, { cmd => 'pause' });
	$w->{toc} = [ $TOC, undef ];
	cmd($w, { cmd => 'toc', id => 6 });
	is((events($w))[0]{id}, 6, 'toc u pauzi: odgovor');
	# ioctl koji pukne (die) ne obara pomocnika
	$w->{h}{toc} = sub { die "puklo\n" };
	cmd($w, { cmd => 'toc', id => 8 });
	is_deeply([ events($w) ], [ { ev => 'toc', id => 8, toc => undef, err => 'io' } ], 'toc: izuzetak -> io');
}

# ---- eject, config, losi zahtevi, quit ----
{
	my $w = mk();
	cmd($w, { cmd => 'eject', id => 9 });
	is_deeply([ events($w) ], [ { ev => 'eject', id => 9, ok => 1 } ], 'eject: ok');
	$w->{eject} = [ undef, 'io' ];
	cmd($w, { cmd => 'eject', id => 10 });
	is_deeply([ events($w) ], [ { ev => 'eject', id => 10, ok => 0, err => 'io' } ], 'eject: greska');

	cmd($w, { cmd => 'config', dev => '/dev/sr9' });
	$w->{h}->tick;
	is_deeply($w->{calls}[-1], [ status => '/dev/sr9' ], 'config: novi uredjaj');
	events($w);

	$w->{h}->handle_line('nije json');
	is((events($w))[0]{ev}, 'error', 'los JSON: error dogadjaj');
	cmd($w, { cmd => 'nepoznato' });
	is_deeply([ events($w) ], [ { ev => 'error', err => 'bad_cmd' } ], 'nepoznata komanda');
	is($w->{h}->handle_line(''), 1, 'prazna linija se ignorise');
	is(cmd($w, { cmd => 'quit' }), 0, 'quit: kraj petlje');
}

# ---- pravi proces: argv kao u Plugin-u, stdin/stdout, EOF na stdin-u gasi pomocnika ----
{
	my $lib = File::Spec->rel2abs('lib');
	my $script = 'Plugins::AudioCD::DriveHelper::main()';
	my $pid = open(my $out, '-|') // die "fork: $!";
	if (!$pid) {
		# dete: pipe za stdin pravi shell, uredjaj ne postoji -> status sa greskom no_device
		exec('sh', '-c', q{printf '{"cmd":"toc","id":1}\n' | "$0" -I"$1" -MPlugins::AudioCD::DriveHelper -e "$2" -- --dev /nema --poll 0}, $^X, $lib, $script);
		die "exec: $!";
	}
	local $SIG{ALRM} = sub { kill 'KILL', $pid; die "timeout\n" };
	alarm 10;
	my @lines = <$out>;
	close $out;
	alarm 0;
	is($?, 0, 'pomocnik izlazi sa 0 na EOF stdin-a');
	my @e = map { JSON::PP->new->decode($_) } @lines;
	is_deeply(\@e, [ { ev => 'status', code => undef, err => 'no_device' }, { ev => 'toc', id => 1, toc => undef, err => 'no_device' } ],
		'pravi proces: status na startu i odgovor na toc') or diag explain \@lines;
}

done_testing;
