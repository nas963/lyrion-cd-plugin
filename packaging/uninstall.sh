#!/usr/bin/env bash
# Uklanja plugin AudioCD. Pokrece se kao root:
#   sudo bash uninstall.sh
# Restartuje Lyrion. Snimljeni albumi (CD-Rips) ostaju, a korisnik squeezeboxserver ostaje u grupi cdrom.
set -euo pipefail

PREFS=/var/lib/squeezeboxserver/prefs
PLUGIN=/var/lib/squeezeboxserver/Plugins/AudioCD
CUSTOM="$PREFS/material-skin/custom.js"

# Uklanja samo AudioCD blok iz fajla (od "// AudioCD start" do "// AudioCD end"); ostalo se ne dira.
# Upis je atomski (privremeni fajl u istom folderu pa rename). Fajl bez bloka se ne menja.
remove_audiocd_block() {
    perl -e '
        my $file = shift;
        open my $in, "<:raw", $file or die "$file: $!\n";
        local $/;
        my $text = <$in>;
        close $in;
        my ($s, $e) = ("// AudioCD start", "// AudioCD end");
        my $new = $text;
        $new =~ s/^\Q$s\E[ \t]*\r?\n.*?^\Q$e\E[ \t]*(?:\r?\n|\z)//ms;
        $new =~ s/^\Q$s\E[ \t]*(?:\r?\n|\z)(?:\(function \(\) \{[^\n]*\n.*?^\}\)\(\);[ \t]*(?:\r?\n|\z))?//ms;
        $new =~ s/^\Q$e\E[ \t]*(?:\r?\n|\z)//m;
        exit 0 if $new eq $text;
        my $mode = (stat $file)[2] & 07777;
        my $tmp = "$file.audiocd.$$";
        open my $out, ">:raw", $tmp or die "$tmp: $!\n";
        print {$out} $new or die "$tmp: $!\n";
        close $out or die "$tmp: $!\n";
        chmod $mode, $tmp;
        rename $tmp, $file or do { unlink $tmp; die "$file: $!\n" };
    ' "$1"
}

main() {
    [ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash uninstall.sh"; exit 1; }

    rm -rf "$PLUGIN"
    rm -f /etc/udev/rules.d/99-audiocd.rules \
          /etc/systemd/system/audiocd-notify@.service \
          /usr/local/lib/audioos/audiocd-notify \
          /etc/tmpfiles.d/audiocd.conf
    rmdir /usr/local/lib/audioos 2>/dev/null || true
    rm -rf /run/audiocd
    if command -v systemctl >/dev/null; then systemctl daemon-reload; fi
    if command -v udevadm >/dev/null; then udevadm control --reload; fi

    if [ -f "$CUSTOM" ]; then
        remove_audiocd_block "$CUSTOM"
    fi

    echo "Snimljeni albumi (CD-Rips) i korisnik u grupi cdrom ostaju netaknuti."
    systemctl restart lyrionmusicserver
    systemctl is-active lyrionmusicserver
    echo "UKLONJENO"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
