use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $sys = -d "$Bin/../system" ? "$Bin/../system" : "$Bin/../../system";
my $script = "$sys/audiocd-notify";

ok -f $script, 'audiocd-notify postoji' or BAIL_OUT('nema system/audiocd-notify');
is system('bash', '-n', $script), 0, 'bash -n audiocd-notify';

for my $f (qw(99-audiocd.rules audiocd-notify@.service tmpfiles-audiocd.conf)) {
	ok -f "$sys/$f", "$f postoji";
}

# udev pravilo: SYSTEMD_WANTS na "change" sa stalnom instancom (@sr0) pokrece servis samo pri
# prvoj promeni posle boot-a; zato RUN+= systemctl start --no-block za svaku promenu.
{
	open my $fh, '<', "$sys/99-audiocd.rules" or die $!;
	my @rules = grep { !/^\s*(?:#|$)/ } <$fh>;
	is scalar(@rules), 1, 'udev: jedno pravilo';
	my $r = $rules[0] // '';
	like $r, qr/ACTION=="change"/, 'udev: na change';
	like $r, qr/SUBSYSTEM=="block"/, 'udev: block';
	like $r, qr/KERNEL=="sr\[0-9\]\*"/, 'udev: sr uredjaji';
	like $r, qr{RUN\+="/usr/bin/systemctl start --no-block audiocd-notify\@%k\.service"}, 'udev: RUN+= systemctl start --no-block';
	unlike $r, qr/SYSTEMD_WANTS/, 'udev: bez SYSTEMD_WANTS';
}

my $tmp = tempdir(CLEANUP => 1);
my $log = "$tmp/curl.log";

sub write_exec {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "$path: $!";
	print $fh $body;
	close $fh;
	chmod 0755, $path;
}

write_exec("$tmp/udevadm", <<'SH');
#!/bin/sh
echo "ID_TYPE=cd"
echo "ID_CDROM_MEDIA_TRACK_COUNT_AUDIO=$FAKE_TRACKS"
SH
write_exec("$tmp/curl", <<'SH');
#!/bin/sh
echo "$@" >> "$FAKE_CURL_LOG"
exit "${FAKE_CURL_RC:-0}"
SH
write_exec("$tmp/udevadm-empty", "#!/bin/sh\necho ID_TYPE=cd\n");

open my $pf, '>', "$tmp/server.prefs" or die;
print $pf "---\nhttpport: 9123\nlanguage: SR\n";
close $pf;

local $ENV{AUDIOCD_UDEVADM} = "$tmp/udevadm";
local $ENV{AUDIOCD_CURL}    = "$tmp/curl";
local $ENV{AUDIOCD_PREFS}   = "$tmp/server.prefs";
local $ENV{FAKE_CURL_LOG}   = $log;

sub run_notify {
	my (%o) = @_;
	unlink $log;
	local $ENV{FAKE_TRACKS}   = $o{tracks} // 0;
	local $ENV{FAKE_CURL_RC}  = $o{rc} // 0;
	local $ENV{AUDIOCD_PREFS} = $o{prefs} if defined $o{prefs};
	local $ENV{AUDIOCD_UDEVADM} = $o{udevadm} if defined $o{udevadm};
	my $rc = system("sh '$script' sr0 2>/dev/null");
	my $out = '';
	if (open my $fh, '<', $log) { local $/; $out = <$fh>; close $fh }
	return ($rc >> 8, $out);
}

my ($rc, $out) = run_notify(tracks => 9);
is $rc, 0, 'izlaz 0 za disk sa 9 pesama';
like $out, qr/"audiocd","load"/, 'salje load';
unlike $out, qr/eject_event/, 'ne salje eject_event';
like $out, qr{http://127\.0\.0\.1:9123/jsonrpc\.js}, 'port iz server.prefs';
like $out, qr/-fsS/, 'curl -fsS';
like $out, qr/-m 5/, 'curl -m 5';

($rc, $out) = run_notify(tracks => 0);
is $rc, 0, 'izlaz 0 za prazan drajv';
like $out, qr/"audiocd","eject_event"/, 'salje eject_event za 0 pesama';

($rc, $out) = run_notify(udevadm => "$tmp/udevadm-empty");
like $out, qr/eject_event/, 'bez svojstva o pesmama -> eject_event';

($rc, $out) = run_notify(tracks => 9, prefs => "$tmp/nema.prefs");
like $out, qr{127\.0\.0\.1:9000/}, 'podrazumevani port 9000';

($rc, $out) = run_notify(tracks => 9, rc => 7);
is $rc, 0, 'izlaz 0 i kad curl ne uspe (LMS ne radi)';

done_testing;
