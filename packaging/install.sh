#!/usr/bin/env bash
# Instalira plugin AudioCD. Pokrece se kao root iz raspakovanog paketa:
#   sudo bash install.sh
# Plugin ide tamo gde ga stavlja i Lyrion (cache/InstalledPlugins) i upisuje se u Lyrion sa svojim
# repozitorijumom, pa ga Lyrion posle azurira sam, kao bilo koji drugi plugin. Ova skripta je potrebna
# samo jednom, zbog sistemskog dela (udev pravilo, tmpfiles, grupa cdrom) koji Lyrion ne moze sam.
# Lyrion stoji dok se menjaju plugin i podesavanja, sto prekida reprodukciju na svim plejerima.
# Pakete (cyanrip i ostalo) ne instalira sam: samo ispise sta fali.
set -euo pipefail

STAGE="$(cd "$(dirname "$0")" && pwd)"
LMS=/var/lib/squeezeboxserver
INSTALLED="$LMS/cache/InstalledPlugins/Plugins"
PLUGIN="$INSTALLED/AudioCD"
OLD_PLUGIN="$LMS/Plugins/AudioCD"    # rucna instalacija do 1.6.0: Lyrion je ne azurira
EXT_PREFS="$LMS/prefs/plugin/extensions.prefs"
REPO_URL=https://nas963.github.io/lyrion-cd-plugin/repo.xml
NOTIFY_DIR=/usr/local/lib/audioos

# alat -> Debian paket
TOOLS="cyanrip:cyanrip cd-paranoia:cd-paranoia flac:flac cd-info:libcdio-utils eject:eject curl:curl"

[ "$(id -u)" -eq 0 ] || { echo "Pokreni kao root: sudo bash install.sh"; exit 1; }
command -v systemctl >/dev/null || { echo "Paket je za Debian/Ubuntu sa systemd-om."; exit 1; }
systemctl cat lyrionmusicserver >/dev/null 2>&1 || { echo "Nije nadjen servis lyrionmusicserver."; exit 1; }
[ -f "$STAGE/AudioCD/install.xml" ] || { echo "Nema plugina u $STAGE"; exit 1; }

command -v python3 >/dev/null || { echo "Potreban je python3."; exit 1; }
echo "Lyrion se zaustavlja dok traje instalacija (reprodukcija se prekida)."

# Paket je u privremenom folderu koji get.sh brise na izlazu: vracanje ide preko get.sh.
trap 'echo "GREŠKA: instalacija nije završena. Vraćanje: curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash -s uninstall"; systemctl start lyrionmusicserver || true' ERR

# Plugin: kao da ga je instalirao Lyrion (vlasnik squeezeboxserver, folderi 755, fajlovi 644), i upis
# u extensions.prefs (plugin + repozitorijum). Lyrion mora da stoji: pri gasenju upisuje svoje prefs.
systemctl stop lyrionmusicserver
rm -rf "$OLD_PLUGIN"
mkdir -p "$INSTALLED"
chown squeezeboxserver:nogroup "$LMS/cache/InstalledPlugins" "$INSTALLED"
rm -rf "$PLUGIN"
cp -r "$STAGE/AudioCD" "$PLUGIN"
chown -R squeezeboxserver:nogroup "$PLUGIN"
find "$PLUGIN" -type d -exec chmod 755 {} +
find "$PLUGIN" -type f -exec chmod 644 {} +
install -d -o squeezeboxserver -g nogroup -m 755 "$(dirname "$EXT_PREFS")"
python3 "$STAGE/lms-repo.py" add "$EXT_PREFS" AudioCD "$REPO_URL"
chown squeezeboxserver:nogroup "$EXT_PREFS"
echo "Plugin je u $PLUGIN; azurira ga Lyrion (repozitorijum $REPO_URL)."

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

systemctl start lyrionmusicserver
systemctl is-active lyrionmusicserver
echo "INSTALIRANO"
