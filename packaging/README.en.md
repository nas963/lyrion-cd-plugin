# AudioCD for Lyrion

A plugin that turns a Lyrion server with an optical drive into a proper CD player and album ripper, in the spirit of Daphile.

## What it does
- **Automatic disc reading.** When you insert a CD, the plugin reads its table of contents and looks the disc up (MusicBrainz, then GnuDB, plus CD-Text if the disc has it). You get album title, artist, tracks and cover art. If MusicBrainz finds only a fuzzy match, you are offered a choice of releases.
- **Playback.** Tracks are first read into a RAM cache (`/run/audiocd`) and played from there: bit-perfect and gapless.
- **Ripping.** The album is ripped to FLAC with `cyanrip` in three profiles: `fast`, `balanced` and `secure` (more retries, lower speed). The result is checked against the AccurateRip database.
- **Move to library.** A ripped album goes to your music folder with one click, and Lyrion scans it (if Lyrion is already scanning the library, the album scan waits for it to finish, at most 30 minutes).
- **Material Skin.** The CD appears on the Material home screen with cover, track list and buttons for play, rip and eject. In the **Audio CD** menu (My Music) the disc is a single item: open it to get the track list with **Play** and **Add** in the header. Next to the disc are the **Rip** and **Eject** items. The plugin page opened from Material follows its theme (light/dark), plays on the player selected in Material (no separate player picker), and **Settings** opens in a new tab.

The UI language follows the Lyrion language (Serbian or English).

## Requirements
- Lyrion Music Server 9.x on Debian or Ubuntu, installed as a package (`lyrionmusicserver` service).
- An optical drive visible to the system, usually `/dev/cdrom`.
- Packages: `cyanrip`, `cd-paranoia`, `flac`, `libcdio-utils` (provides `cd-info`), `eject`, `curl`.

The installer does not install packages itself. If something is missing, it prints the exact command:

```bash
sudo apt install cyanrip cd-paranoia flac libcdio-utils eject curl
```

## Install and update
On the server, over SSH:

```bash
curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash
```

If it reports that `curl` or `python3` is missing: `sudo apt install curl python3`.

The command downloads the latest release, verifies it and runs the installer. The same command updates an existing installation.

The installer copies the plugin to `/var/lib/squeezeboxserver/Plugins/AudioCD`, adds a udev rule and a service that tells Lyrion when a disc is inserted, adds the `squeezeboxserver` user to the `cdrom` group and **restarts Lyrion** (playback stops). Afterwards, reload Material in your browser.

## Settings
Lyrion: Settings, Plugins, **AudioCD**.

| Setting | Default | Meaning |
|---|---|---|
| Device | `/dev/cdrom` | CD device |
| Rips folder | (empty) | see below |
| Library folder | (empty) | where albums are moved; empty = first Lyrion music folder |
| Profile | balanced | ripping profile |
| Quiet drive | off | lower the read speed |
| Quiet drive speed | 8 | speed (x) when quiet drive is on |
| Drive offset | (empty) | read offset correction for AccurateRip; find it with `cyanrip -f` (needs a disc that is in the AccurateRip database) |
| Load disc automatically | on | read metadata as soon as a disc is inserted |
| Auto rip | off | rip every inserted disc |
| Auto rip profile | balanced | |
| Eject after rip | off | |
| Notifications | on | udev reports disc insert and eject |
| Background polling | on | fallback when udev is not available |
| Secure cache read | off | tracks are read into the cache slower and more carefully |

There is no FLAC compression level: `cyanrip` always uses the maximum.

## Where rips go
The rips folder is looked up in this order:
1. the **Rips folder** setting, if set;
2. `CD_RIPS_DIR` in `/etc/audioos/audioos.conf`;
3. `CD_RIPS_DIR` in `/usr/local/lib/audioos/defaults.conf`;
4. `/var/lib/squeezeboxserver/CD-Rips`.

Each album gets its own folder; an existing album folder is never overwritten. Files are 0644, folders 0755.

## Known limitations
- One optical drive is supported. The drive does one thing at a time: reading into the cache or ripping.
- `cyanrip` versions differ (Ubuntu 0.9.2, Debian trixie 0.9.3): output and tags may differ slightly.
- AccurateRip reports "not found" for discs that are not in its database; that is not an error in the rip. If the disc is found but no track matches, the drive offset is missing or wrong (see Drive offset).
- The effect on a USB DAC on the same controller has not been measured yet.

## Uninstall
```bash
curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash -s uninstall
```

Removes the plugin, the system files and the AudioCD block from `custom.js` (the rest of the file is untouched) and restarts Lyrion. Ripped albums (CD-Rips) stay, and the `squeezeboxserver` user stays in the `cdrom` group.

## License
GPL-2.0, see `LICENSE`.
