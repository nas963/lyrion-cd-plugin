# AudioCD za Audio$OS: uputstvo za integraciju

Za Audio$OS sesiju. Plugin AudioCD (Lyrion/LMS 9.1.1) cita audio CD, daje metapodatke (MusicBrainz, GnuDB, CD-Text),
omogucava Play direktno sa diska (kes u RAM-u) i rip u FLAC. Ovaj fajl opisuje sta treba ugraditi u ISO, sta se
ocekuje od sistema i kako se proverava da radi. Podaci o merenjima su iz `docs/verification-2026-11.md`.

## 1. Paketi (Debian 13 trixie)

| Paket (verzija) | Alat | Zasto |
|---|---|---|
| `cyanrip` 0.9.3.1 | `/usr/bin/cyanrip` | rip u FLAC, tagovi, omot, AccurateRip, `.log`/`.cue` |
| `cd-paranoia` | `/usr/bin/cd-paranoia` | citanje pesama za Play kes (`cd-paranoia \| flac`) |
| `flac` 1.5.0 | `/usr/bin/flac` | kodiranje Play kesa (`flac -0`) |
| `libcdio-utils` 2.2.0 | `/usr/bin/cd-info` | TOC i CD-Text |
| `eject` (util-linux 2.41) | `/usr/bin/eject` | OBAVEZAN: izbacivanje diska (USB slim drajvovi ignorisu CDROMEJECT ioctl, koji je samo rezerva) |
| `curl` | `/usr/bin/curl` | `audiocd-notify` javlja Lyrion-u preko JSON-RPC |

- Alati se traze redom `/usr/bin`, `/bin`, pa `PATH`. `nice`/`ionice` dolaze iz coreutils/util-linux (vec u sistemu).
- `udevadm` i `systemctl` su vec u sistemu (notify skripta i pravilo).
- LMS vec nosi sve Perl module koje plugin koristi; plugin ne trazi nikakav XS modul iz CPAN-a. Ne instalirati
  dodatne `lib*-perl` pakete zbog njega.
- `python3` plugin NE trazi (build skripta paketa je samo za razvoj).
- cyanrip 0.9.3.1 nije testiran (razvoj je na Ubuntu 24.04 sa cyanrip 0.9.2, koji ispisuje "0.9.0"). Vidi odeljak 9.

## 2. Gde se plugin instalira

- `/var/lib/squeezeboxserver/Plugins/AudioCD`, vlasnik `squeezeboxserver:nogroup`, folderi 755, fajlovi 644.
  Taj folder je na `/data` (bind-mount), pa preziveljava restart.
- `/usr/share/squeezeboxserver/Plugins` je read-only (deo paketa i root FS-a): tamo se ne instalira.
- Za ugradnju u ISO: kopirati sadrzaj `src/AudioCD/` (ili raspakovan `dist/audiocd.zip`, folder `AudioCD`) u gornju
  putanju pri prvom pokretanju (ako je folder prazan) ili u sloj koji se kopira na `/data`. Bez `install.xml` plugin se
  ne ucitava. Posle promene plugina treba restart `lyrionmusicserver`.
- Alternativa: `packaging/install.sh` (root, na pravom Debian/Ubuntu-u). Radi iste korake kao dole, ali menja `/etc`,
  sto na read-only root-u mora biti u ISO-u.

## 3. Sistemski fajlovi (`system/`)

Root je read-only sa overlay-em u RAM-u, pa ovi fajlovi moraju u ISO (ne pisu se pri radu):

| Izvor | Odrediste | Mod |
|---|---|---|
| `system/99-audiocd.rules` | `/etc/udev/rules.d/99-audiocd.rules` | 644 |
| `system/audiocd-notify@.service` | `/etc/systemd/system/audiocd-notify@.service` | 644 |
| `system/audiocd-notify` | `/usr/local/lib/audioos/audiocd-notify` | 755 |
| `system/tmpfiles-audiocd.conf` | `/etc/tmpfiles.d/audiocd.conf` | 644 |

- Pravilo: na `change` blok-dogadjaju za `sr[0-9]*` pokrece
  `/usr/bin/systemctl start --no-block audiocd-notify@%k.service`. Namerno `RUN+=` a ne `SYSTEMD_WANTS`:
  `SYSTEMD_WANTS` sa istom instancom (`@sr0`) se najverovatnije aktivira samo pri prvoj promeni posle boot-a.
- NIJE testirano na pravoj instalaciji: dve uzastopne promene diska (ubaci, izvadi, ubaci) sa iskljucenim pollingom.
  Plugin ima rezervu: polling drajva na svakih 2 s (u pomocnom procesu `audiocd-drive`, odeljak 4) je UKLJUCEN
  podrazumevano (`polling=1`), pa disk bude otkriven i ako udev propusti dogadjaj. Audio$OS sesija treba da proveri pravilo (odeljak 10) i javi rezultat.
- Servis: `Type=oneshot`, `User=squeezeboxserver`, `Nice=10`, `IOSchedulingClass=idle`. Poziva
  `audiocd-notify %I`.
- `audiocd-notify`: cita `udevadm info` (`ID_CDROM_MEDIA_TRACK_COUNT_AUDIO`), pa salje `audiocd load` (ima audio
  pesama) ili `audiocd eject_event` na `http://127.0.0.1:<httpport>/jsonrpc.js`. Port cita iz
  `/var/lib/squeezeboxserver/prefs/server.prefs` (`httpport:`), podrazumevano 9000. Uvek izlazi sa 0 (nikad ne
  pravi "failed" jedinicu kad Lyrion ne radi).
- tmpfiles: `d /run/audiocd 0755 squeezeboxserver nogroup -` (kes za Play u RAM-u).

## 4. Grupe i prava

- `usermod -aG cdrom squeezeboxserver` (u ISO: korisnik `squeezeboxserver` mora biti u grupi `cdrom`).
- `/dev/sr0` treba da bude `root:cdrom` mod 660 (podrazumevano udev/Debian). Ioctl-ove (status drajva, TOC,
  rezervni CDROMEJECT) radi pomocni proces `audiocd-drive` (dete LMS-a, `nice 10`, ionice `idle`; pokrece ga
  plugin, ne systemd), nikad sam LMS proces; cyanrip i cd-paranoia citaju sa uredjaja.
- Pomocni proces otvara uredjaj za svaku operaciju (`O_RDONLY|O_NONBLOCK`, deljeno) i odmah ga zatvara, a dok
  drajv cita drugi proces je u pauzi (bez polling-a, koji inace ide na 2 s). Pauza je asinhrona, salje se tek
  posle pokretanja posla i ne prekida zahtev koji pomocni proces vec radi. Polling ioctl traje milisekunde, ali
  citanje TOC-a na disku koji se tek zavrce traje sekundama (USB slim drajv). Zato:
  - izbacivanje ceka (provera na 1.5 s, najvise 30 s) dok pomocni proces ima zahtev u toku i dok procesi
    prekinutog posla ne izadju, pa alat `eject` nikad ne krece usred TOC ioctl-a;
  - `cd-paranoia`/`cyanrip` mogu da krenu dok se TOC jos cita (npr. Play odmah posle ubacivanja). To ne smeta:
    niko ne otvara uredjaj ekskluzivno i svi samo citaju; ako TOC zbog toga pukne, ucitan disk ostaje.
- Izbacivanje: alat `eject` (util-linux) je glavni put, jer USB slim drajvovi ignorisu CDROMEJECT ioctl;
  CDROMEJECT u pomocnom procesu je samo rezerva kad alata nema. Posle izbacivanja pomocni proces nastavlja
  polling i ponovo javlja stanje drajva, pa se disk zamenjen tokom posla (rip, kes) ipak procita.
- Podrazumevani uredjaj je `/dev/cdrom` (symlink ka `sr0`). Moze se promeniti u podesavanjima.

## 5. Putanje

**Folder za rip-ove** (`ripsDir`), prvi koji je postavljen u lancu:
1. pref `ripsDir` (podesavanja plugina), ako je neprazan;
2. `CD_RIPS_DIR` iz `/etc/audioos/audioos.conf`;
3. `CD_RIPS_DIR` iz `/usr/local/lib/audioos/defaults.conf`;
4. `/var/lib/squeezeboxserver/CD-Rips`.

Konf. fajlovi su `KEY=value` (shell stil, UTF-8). Na Audio$OS treba da bude `CD_RIPS_DIR=/data/CD-Rips`
(Samba share `CD-Rips`, `force user = squeezeboxserver`, da fajlovi koje plugin pravi i oni koje korisnik brise preko
mreze imaju istog vlasnika). Folder mora biti upisiv za `squeezeboxserver`. Fajlovi rip-a su 0644, folderi 0755;
postojeci folder albuma se nikad ne prepisuje (dobija sufiks `(2)`, `(3)`...). Privremeni rad ide u skriveni
`.audiocd-tmp` unutar tog foldera (isti FS, pa je konacno premestanje rename). Napomena: `docs/DIZAJN.md` Audio$OS-a
pominje `/music/CD-Rips`; ako to ostane, `CD_RIPS_DIR` treba postaviti na tu putanju. Plugin ne pretpostavlja nijednu.

**Kes za Play** (cd-paranoia | flac, cela pesma u FLAC-u, nizak prioritet): za svaki novi disk bira se prvi upisivi
folder sa dovoljno mesta, redom:
1. `/run/audiocd` (tmpfiles.d, odeljak 3);
2. `/dev/shm/audiocd`;
3. LMS cache, `.../cache/AudioCD/play`.

Potrebno mesto = trajanje x 176400 x 0.65 + 20 MB (80 min CD je oko 500 MB). Slobodno mesto se meri sa `df -Pk`
(rok 5 s po kandidatu); ako nema mesta nigde, Play vraca gresku `cache_no_space`. Preporuka: `/run` (tmpfs) treba da
ima bar 600 MB slobodno za 80-minutni disk (podrazumevano je to deo RAM-a, proveriti `df -h /run /dev/shm`), ili
napraviti poseban tmpfs na `/run/audiocd` (npr. `size=700M`). Ako je RAM mali, treci kandidat je disk (`/data`),
sporije ali radi.

Kes PREZIVLJAVA izbacivanje diska: gotove pesme se i dalje sviraju, a isti disk ponovo ubacen nastavlja izvlacenje
pesama koje fale. Brise se tek kad se procita DRUGI disk (ili disk bez audio pesama) ili pri restartu LMS-a
(pokretanje/gasenje plugina). Za procenu RAM-a: do oko 500 MB u `/run` (tmpfs) moze ostati zauzeto i kad je
drajv prazan, sve do sledeceg drugog diska ili restarta.

**Metapodaci i omot**: LMS cache, `.../cache/AudioCD/meta` (JSON + omot po ID-u diska). Perzistentno ako je
LMS cache na `/data`.

## 6. Podesavanja i podrazumevane vrednosti

Prefs `plugin.audiocd` (iz `Config::DEFAULTS`); sve se menja na stranici podesavanja plugina:

| Podesavanje | Podrazumevano | Napomena |
|---|---|---|
| `device` | `/dev/cdrom` | |
| `profile` | `balanced` | `fast` (-P 0), `balanced`, `secure` (-P 3 -r 5) |
| `flacLevel` | 5 | NE postoji u cyanrip-u: uvek max kompresija; vrednost se ignorise (nije u UI-ju) |
| `quietDrive` / `quietSpeed` | 0 / 8 | smanjuje brzinu drajva (`-S`) pri ripu i pri izvlačenju za Play (cd-paranoia); drajv koji ne menja brzinu: rip se ponavlja bez `-S` |
| `driveOffset` | prazno | cyanrip `-s`; prazno znaci `-s 0` |
| `autoLoad` | 1 | procita disk cim se ubaci |
| `onInsert` | `none` | `none` / `play` / `rip`; zamenjuje `autoRip` (ukljucen `autoRip` se prenosi kao `rip`) |
| `autoPlayPlayer` | prazno | ID plejera za `onInsert` = `play`; pusta se samo stvarno ubacen disk i samo ako plejer ne svira |
| `autoRipProfile` | `balanced` | |
| `ejectAfterRip` | 0 | |
| `notify` | 1 | |
| `polling` | 1 | provera drajva na 2 s u pomocnom procesu `audiocd-drive` (rezerva za udev) |
| `secureCache` | 0 | |
| `libraryDir` | prazno | |
| `ripsDir` | prazno | vidi odeljak 5 |
| `noRipWhileLocalPlays` | 0 | |

**Ofset citanja drajva (`driveOffset`)**. Bez ispravnog ofseta AccurateRip daje "mismatch" na svim pesmama iako je
disk u bazi (rip se tada u istoriji oznaci `check_offset`). Izmereno: ASUS SDRW-08U7M-U, firmware A112 = **+6**
(`cyanrip -f` dao `Drive offset of +6 found (confidence: 9)`, isto kao AccurateRip lista drajvova; rip sa `-s 6` na
drugom disku: AccurateRip v1 197, v2 200, tacno). Plugin ga NE upisuje sam. Preporuka: Audio$OS ili korisnik
postavlja `driveOffset` (u Podesavanjima, "Ofset drajva"). Za drugi drajv ofset se nalazi sa pravim audio diskom koji
je u AccurateRip bazi: `cyanrip -f` (opcija za trazenje ofseta; vidi `cyanrip -h`) ili lista drajvova na
accuraterip.com.

## 7. Prioritet procesa

Svaki spoljni proces koji plugin pokrene ide kao `nice -n 10 ionice -c3 <cmd>` (`Jobs::low_prio`): `cyanrip`,
`cd-paranoia | flac`, `cd-info`, `cp -a` (premestanje albuma preko FS granice), `eject` i pomocni proces
`audiocd-drive`. `df -Pk` se pokrece
direktno (bez nice-a, kratak, sa rokom 5 s). Nista nije RT (`SCHED_FIFO/RR`), nista ne ide u `audio.slice`.
Procesi nasledjuju cgroup servisa `lyrionmusicserver`. Izmereno: `NI 10`, ionice `idle`, raspored `TS`. Ako
Audio$OS stavlja LMS u neki slice, rip ce biti u njemu: ne dizati mu prioritet i ne stavljati ga u `audio.slice`
sa RT nitima DAC-a.

## 8. USB i DAC

Na razvojnom serveru nema lokalnog DAC-a ni squeezelite-a, pa merenje "rip na istom xHCI kontroleru kao USB DAC" nije
uradjeno. Izmereno je samo: Protodac HiFi (mrezni plejer) svirao je 15 min iz kesa tokom `fast` rip-a bez prekida
(297 od 297 uzoraka `mode=play`); opterecenje: cyanrip 55-73% jednog jezgra (4 jezgra), stanje `D`, load oko 1.8;
kesiranje oko 1% CPU po procesu. Preporuka za Audio$OS: izmeriti sa lokalnim DAC-om na istom kontroleru kao CD drajv
(komande su predlog):

```sh
lsusb -t                                  # da li DAC i CD drajv dele xHCI kontroler/hab
# tokom ripa (pokrenuti rip sa web stranice) i sviranja sa DAC-a:
journalctl -k -f | grep -iE 'xrun|underrun|usb'   # i log plejera
vmstat 3; ps -eo pid,ni,cls,pri,cmd | grep -E 'cyanrip|cd-paranoia|flac|squeezelite'
```

Ako dolazi do prekida, ukljuciti `noRipWhileLocalPlays` (rip se ne pokrece dok svira lokalni plejer; podrazumevano
0) ili staviti CD drajv na drugi kontroler.

## 9. Rezultati provere i poznata ogranicenja

Pravi disk, Lyrion 9.1.1: Play prva pesma spremna za oko 34 s (8.6x brze od realnog), ceo disk (43:11) u kesu oko
207 s; premotavanje i prelaz pesama rade (bez greske u logu). Rip 9 pesama: `fast` 1016 s, `balanced` 1400 s,
`secure` 1447 s; audio deo svih rip-ova je bajt-identican (isti MD5), 12 fajlova po albumu, 0644/0755, tagovi i
ugradjen omot ispravni. Restart LMS-a usred ripa ne ostavlja procese ni tmp. Test paket (1.0.1): 1963 provere, PASS.

Poznata ogranicenja i otvorena pitanja:

- **udev**: dve uzastopne promene bez pollinga nisu testirane (odeljak 3).
- **Ofset**: AccurateRip poklapanje je potvrdjeno samo na drugom disku (Enigma, +6); 9/9 mismatch na "The Story of
  Jazz" je verovatno ofset, ali taj disk nije ponovo ripovan.
- **SR11 auto-advance**: FiiO SR11 (UPnPBridge) ne prelazi sam na sledecu pesmu na kraju pesme (isto i sa pesmom iz
  biblioteke), vec stoji dok se ne preskoci. To je bridge/plejer, ne plugin.
- **Prekinut rip** (restart LMS-a) se ne pojavljuje u istoriji.
- Parkirano (prihvaceno): (a) resen u 1.0.1: dok se ponovo ubacen disk cita, `request_cache` vraca `not_ready`
  (pesma ceka i ponavlja), a `wrong_disc` samo za prazan drajv ili poznat drugi disk; (b) automatsko kesiranje (Play) moze preduhitriti auto-rip koji tek
  treba da krene (auto-rip se zabelezi kao "nije pokrenut", korisnik pokrece rucno); (c) `df` ogranicen na 5 s po
  kandidatu (retko kasnjenje do 15 s na novom disku); (d) zaostala delimicna kopija kesa u drugom kandidat-folderu
  do sledeceg diska ili restarta (samo RAM); (e) putanja u Latin-1 u konf. fajlu bi se dvaput kodirala (Audio$OS
  koristi ASCII).
- **cyanrip verzije**: razvoj i sve provere su na 0.9.2 (ispisuje "0.9.0"); Audio$OS cilj je 0.9.3.1. Koriscene opcije:
  `-N -s -d -P -r -S -o flac -D -F '{track}' -c -C -a -t`, nikad `-Q` (izbacuje) ni `-R`. `-s` je obavezan u 0.9.0
  (bez njega odbija rip); 0.9.3.1 mozda sam trazi ofset, `-s` se i dalje prihvata. U 0.9.3.1 treba proveriti: format
  izlaza `Ripping and encoding track N, progress - X%` (plugin ga parsira), imena fajlova `<N>.flac` bez nule,
  `.log`/`.cue` u folderu albuma (trazi se glob `*.log`/`*.cue`), i da `-N` i dalje iskljucuje MusicBrainz upit.
  Nema opcije za FLAC nivo.
- **Jezik UI-a** (web stranica, poruke) prati jezik LMS-a (engleski ili srpski).
- `cd-info` na pravom disku traje 40 s do 2 min; plugin ga prekida posle 10 s, a polling ne dira drajv dok radi.

## 10. Provera da radi (smoke test)

```sh
id squeezeboxserver                              # mora imati grupu cdrom
for t in cyanrip cd-paranoia flac cd-info eject curl; do command -v $t || echo "NEMA $t"; done
cyanrip -V; flac --version; cd-info --version | head -1
ls -l /dev/sr0                                   # brw-rw---- root cdrom
ls -ld /var/lib/squeezeboxserver/Plugins/AudioCD  # squeezeboxserver nogroup, 755
ls -l /etc/udev/rules.d/99-audiocd.rules /usr/local/lib/audioos/audiocd-notify /etc/tmpfiles.d/audiocd.conf
ls -ld /run/audiocd; df -h /run /dev/shm         # squeezeboxserver nogroup 755

# ubaciti audio CD, pa:
systemctl status audiocd-notify@sr0              # oneshot: "inactive (dead)" sa status=0/SUCCESS je ispravno
journalctl -u 'audiocd-notify@*' -n 20           # "audiocd-notify: sr0 -> load"
# izvaditi pa ponovo ubaciti disk (uz polling=0 u podesavanjima): journal mora imati 2 nova zapisa

PORT=9000   # httpport iz server.prefs
curl -s -d '{"id":1,"method":"slim.request","params":["",["audiocd","status"]]}' http://127.0.0.1:$PORT/jsonrpc.js
curl -s -d '{"id":1,"method":"slim.request","params":["",["audiocd","history"]]}' http://127.0.0.1:$PORT/jsonrpc.js
ls -l /run/audiocd                               # posle "Play": FLAC fajlovi kesa (ostaju i posle izbacivanja)

# pomocni proces za drajv (status, TOC, polling na 2 s): dete LMS-a, nizak prioritet
pgrep -a audiocd-drive                           # tacno jedan proces
ps -o pid,ni,cls,cmd -p "$(pgrep -n audiocd-drive)"   # NI 10, cls TS
ionice -p "$(pgrep -n audiocd-drive)"            # idle

# tokom ripa (pokrenuti sa web stranice plugina):
ps -eo pid,ni,cls,cmd | grep -E 'cyanrip|cd-paranoia|flac|cp -a' | grep -v grep   # NI 10, cls TS (nikad FF/RR)
ionice -p "$(pgrep -n cyanrip)"                  # idle

# Samba share CD-Rips
testparm -s 2>/dev/null | grep -A8 '\[CD-Rips\]'   # path = CD_RIPS_DIR, force user = squeezeboxserver
smbclient -N -L //127.0.0.1 | grep CD-Rips
ls -l "$(sed -n 's/^CD_RIPS_DIR=//p' /etc/audioos/audioos.conf)"   # upisiv za squeezeboxserver
```

Ocekivano: `status` vraca stanje `ready` (disk procitan) ili prazno stanje bez diska; posle rip-a se u `CD_RIPS_DIR`
pojavi `Izvodjac/Album/` sa `.flac`, `cover.jpg`, `.cue`, `.log`, vidljiv preko Samba share-a, a `history` ima zapis.
