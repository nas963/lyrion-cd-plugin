#!/usr/bin/env bash
# Instalira plugin AudioCD. Pokrece se kao root iz raspakovanog paketa:
#   sudo bash install.sh
# Na kraju restartuje Lyrion, sto prekida reprodukciju na svim plejerima.
# Pakete (cyanrip i ostalo) ne instalira sam: samo ispise sta fali.
set -euo pipefail

STAGE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT=/var/lib/squeezeboxserver/Plugins
PLUGIN="$PLUGIN_ROOT/AudioCD"
NOTIFY_DIR=/usr/local/lib/audioos

# alat -> Debian paket
TOOLS="cyanrip:cyanrip cd-paranoia:cd-paranoia flac:flac cd-info:libcdio-utils eject:eject curl:curl"

[ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash install.sh"; exit 1; }
command -v systemctl >/dev/null || { echo "Paket je za Debian/Ubuntu sa systemd-om."; exit 1; }
systemctl cat lyrionmusicserver >/dev/null 2>&1 || { echo "Nije nadjen servis lyrionmusicserver."; exit 1; }
[ -f "$STAGE/AudioCD/install.xml" ] || { echo "Nema plugina u $STAGE"; exit 1; }

echo "Ova instalacija na kraju restartuje Lyrion (reprodukcija se prekida)."

# Paket je u privremenom folderu koji get.sh brise na izlazu: vracanje ide preko get.sh.
trap 'echo "GREŠKA: instalacija nije završena. Vraćanje: curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash -s uninstall"' ERR

# Plugin: vlasnik squeezeboxserver, folderi 755, fajlovi 644.
mkdir -p "$PLUGIN_ROOT"
chown squeezeboxserver:nogroup "$PLUGIN_ROOT"
rm -rf "$PLUGIN"
cp -r "$STAGE/AudioCD" "$PLUGIN"
chown -R squeezeboxserver:nogroup "$PLUGIN"
find "$PLUGIN" -type d -exec chmod 755 {} +
find "$PLUGIN" -type f -exec chmod 644 {} +
echo "Plugin je u $PLUGIN"

# Sistemski fajlovi: otkrivanje diska preko udev-a.
if command -v udevadm >/dev/null && [ -d "$STAGE/system" ]; then
    install -d -m 755 "$NOTIFY_DIR"
    install -m 644 "$STAGE/system/99-audiocd.rules" /etc/udev/rules.d/99-audiocd.rules
    install -m 644 "$STAGE/system/audiocd-notify@.service" /etc/systemd/system/audiocd-notify@.service
    install -m 755 "$STAGE/system/audiocd-notify" "$NOTIFY_DIR/audiocd-notify"
    install -m 644 "$STAGE/system/tmpfiles-audiocd.conf" /etc/tmpfiles.d/audiocd.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/audiocd.conf
    systemctl daemon-reload
    udevadm control --reload
    echo "Sistemski fajlovi su instalirani (udev pravilo, servis, audiocd-notify, tmpfiles)."
else
    echo "Nema udevadm-a: preskacem udev pravilo (disk se tada otkriva samo preko provere u pozadini)."
fi

# Pristup CD uredjaju.
if getent group cdrom >/dev/null && id squeezeboxserver >/dev/null 2>&1; then
    usermod -aG cdrom squeezeboxserver
    echo "Korisnik squeezeboxserver je u grupi cdrom."
fi

# Alati: samo provera.
missing=""
for pair in $TOOLS; do
    tool="${pair%%:*}"
    pkg="${pair#*:}"
    if [ ! -x "/usr/bin/$tool" ] && [ ! -x "/bin/$tool" ] && ! command -v "$tool" >/dev/null; then
        missing="$missing $pkg"
    fi
done
if [ -n "$missing" ]; then
    echo
    echo "Nedostaju alati. Instaliraj ih ovako, pa ponovo pokreni Lyrion:"
    echo "  sudo apt install$missing"
    echo
fi

systemctl restart lyrionmusicserver
systemctl is-active lyrionmusicserver
echo "INSTALIRANO"
