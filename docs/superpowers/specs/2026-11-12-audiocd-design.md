# AudioCD – dizajn

Datum: 2026-11-12. Status: odobren dizajn, spec čeka pregled.

## 1. Cilj i obim

Lyrion (LMS 9.1.x) plugin **AudioCD** (`Plugins::AudioCD`) za CD drajv, po uzoru na Daphile:
ubačen disk se sam očita (metapodaci i omot sa interneta), prikaže na stranici plugina i nudi
**Play** na aktivnom plejeru i **Ripuj** u FLAC.

Ciljni sistem je Audio$OS (Debian 13 trixie, Perl 5.40, read-only root, CPU izolacija).
Razvoj i provera su na razvojnom serveru (Ubuntu 24.04, Perl 5.38, LMS 9.1.1, Material Skin).

Repo: `nas963/lyrion-cd-plugin` (javni). README na srpskom i engleskom.

### Odluke korisnika

| Pitanje | Odluka |
|---|---|
| Ime | AudioCD (ne „CDplayer", da se ne sudari sa starim pluginom) |
| Automatsko očitavanje | uključeno |
| Automatsko ripovanje | opcija, podrazumevano **isključeno** |
| Format | samo FLAC, nivo kompresije podesiv |
| Skeniranje | LMS skenira samo biblioteku (`Muzika`); `CD-Rips` nije u biblioteci |

### Van obima
- Drugi formati (WAV, ALAC, MP3).
- Više CD drajvova istovremeno (podržan je jedan; uređaj je podešavanje).
- Instaliranje sistemskih paketa iz plugina (na Audio$OS-u nije moguće; ide preko ISO-a).

## 2. Ograničenja

- Samo čist Perl i moduli koje LMS nosi (`Digest::SHA`, `JSON::XS::VersionOneAndTwo`,
  `Slim::Networking::SimpleAsyncHTTP`, `Proc::Background` itd.). Bez CPAN XS modula.
- Kod mora da radi na Perl-u 5.38 i 5.40.
- Svi spoljni procesi (`cyanrip`, `cd-paranoia`, `flac`, `cd-info`, `eject`) se pokreću sa
  `nice -n 10 ionice -c3`, nikad u `audio.slice`, nikad sa RT prioritetom.
- Putanje nisu zakucane. Folder za rip-ove: podešavanje → `CD_RIPS_DIR` iz
  `/etc/audioos/audioos.conf` → `CD_RIPS_DIR` iz `/usr/local/lib/audioos/defaults.conf` →
  `/var/lib/squeezeboxserver/CD-Rips`. Fajlovi su shell `KEY=value`, komentari posle `#`,
  vrednost može biti pod navodnicima.
- `squeezeboxserver` mora biti u grupi `cdrom` (sistemska izmena, van plugina).
- Drajv radi jednu operaciju u jednom trenutku (keširanje za Play **ili** rip).

## 3. Arhitektura

```
udev (media change) ─► systemd audiocd-notify@ ─► curl jsonrpc ["audiocd","load"]
                                                          │
Plugin.pm ── Drive.pm (ioctl: status, TOC, eject) ◄───────┤◄── polling 5 s (rezerva)
   │            │                                         │◄── dugme „Učitaj CD"
   │            ▼
   │        DiscId.pm (MusicBrainz disc ID, CDDB ID; čist Perl)
   │            ▼
   │        Metadata.pm (MusicBrainz → CAA → GnuDB → CD-Text → generički), keš po disc ID-u
   │
   ├── Cache.pm  (izvlačenje u tmpfs za Play)  ─► ProtocolHandler.pm (audiocd://)
   ├── Ripper.pm (red poslova, cyanrip, napredak) ─► Profiles.pm (argumenti po profilu)
   ├── Naming.pm (nazivi i putanje, bezbedni za Windows/Sambu)
   ├── Library.pm (Premesti u biblioteku + skeniranje foldera)
   ├── Config.pm (CD_RIPS_DIR, podrazumevane vrednosti)
   ├── Jobs.pm   (pokretanje procesa sa nice/ionice, neblokirajuće čitanje izlaza)
   ├── Web.pm    (stranica i JSON API za stranicu)
   ├── Menu.pm   (stavka „CD" u My Music, za aplikacije i Material)
   ├── MaterialBridge.pm (blok u Material custom.js)
   └── Settings.pm (stranica sa podešavanjima)
```

Čiste jedinice bez zavisnosti od LMS-a (testiraju se same): `DiscId`, `Metadata` parsiranje,
`Naming`, `Profiles`, `Config` (parsiranje fajlova), `MaterialBridge`.
Jedinice koje zavise od LMS-a su tanke i pozivaju čiste jedinice.

### Stanje
Jedan objekat stanja diska u memoriji:
`{ status: empty|reading|ready|error, toc, discid, cddbid, releases[], release_idx,
   metadata{artist, album, year, tracks[{n, title, artist, length}]}, cover_url,
   cover_path, drive_busy: none|cache|rip }`.
Keš metapodataka: `<LMS cache>/AudioCD/meta/<discid>.json` i omot
`<LMS cache>/AudioCD/meta/<discid>.jpg`. Istorija rip-ova: `<LMS cache>/AudioCD/history.json`
(poslednjih 200 unosa).

## 4. Detekcija diska

1. **udev + systemd** (glavni put; isporučuje se kao fajlovi, instalira se van plugina):
   - `99-audiocd.rules`: na `ACTION=="change"`, `SUBSYSTEM=="block"`, `KERNEL=="sr[0-9]*"`
     postavlja `TAG+="systemd"`, `ENV{SYSTEMD_WANTS}+="audiocd-notify@%k.service"`.
   - `audiocd-notify@.service`: `Type=oneshot`, `User=squeezeboxserver`, `Nice=10`,
     `IOSchedulingClass=idle`; poziva `/usr/local/lib/audioos/audiocd-notify` (ili putanju
     iz plugina) koji šalje JSON-RPC `["audiocd","load"]` ili `["audiocd","eject_event"]`
     na `localhost:9000` (port iz LMS prefs-a, podrazumevano 9000).
2. **Polling** (rezerva, uključen podrazumevano): svakih 5 s `ioctl(CDROM_DRIVE_STATUS)` na
   uređaj otvoren sa `O_RDONLY|O_NONBLOCK`. Na prelaz u `CDS_DISC_OK` → `load`, na prelaz iz
   njega → `eject_event`. Ne radi dok traje keširanje ili rip.
3. Dugme **„Učitaj CD"** uvek postoji.

Ako uređaj ne može da se otvori zbog prava, stranica prikazuje jasnu poruku
(„squeezeboxserver nije u grupi cdrom") umesto tihe greške.

## 5. Metapodaci

### TOC i ID-jevi (čist Perl)
- TOC preko `ioctl(CDROMREADTOCHDR)` i `ioctl(CDROMREADTOCENTRY)` za svaku pesmu i
  lead-out (0xAA), LBA format. Konstante i `pack` formati su u `Drive.pm`, sa testovima na
  pakovanim bajtovima.
- Kontrolni bit podataka: pesme sa data bitom (enhanced CD) se ne prikazuju kao audio.
- MusicBrainz disc ID: SHA-1 nad `sprintf("%02X%02X%08X", first, last, leadout+150)` i 99
  ofseta (`%08X`, nule za nepostojeće), base64 sa zamenama `+`→`.`, `/`→`_`, `=`→`-`.
  Za enhanced CD lead-out je početak data sesije minus 11400.
- CDDB ID: standardni algoritam (zbir cifara sekundi, trajanje, broj pesama).

### Izvori (redom, prvi uspešan pobeđuje; omot se traži posebno)
1. MusicBrainz `GET /ws/2/discid/<id>?toc=<toc>&inc=recordings+artist-credits+release-groups+media&fmt=json`.
   `toc=` daje i približna poklapanja kad tačan ID nije u bazi.
   Više izdanja → lista za izbor (država, godina, format, label, broj diskova).
   Za izdanje sa više diskova uzima se medij čiji disc ID ili broj pesama odgovara.
2. Cover Art Archive: `GET https://coverartarchive.org/release/<mbid>/front-500`, pa
   `release-group/<rgid>/front-500` kao rezerva.
3. GnuDB: `cddb query` pa `cddb read` preko HTTP-a (`gnudb.gnudb.org/~cddb/cddb.cgi`,
   `hello` = `audiocd lyrion-cd-plugin <verzija>`, protokol 6).
4. CD-Text: `cd-info --no-device-info --no-disc-mode` (iz `libcdio-utils`), parsira se
   `TITLE`/`PERFORMER`. Opciono: ako `cd-info` ne postoji, preskače se.
5. Generički: „Track N", izvođač „Unknown Artist", album „Audio CD", slika
   `html/images/cd-generic.png`.

Pravila:
- User-Agent: `AudioCD/<verzija> ( https://github.com/nas963/lyrion-cd-plugin )`. Bez ličnih podataka.
- Najviše 1 zahtev u sekundi prema MusicBrainz-u (red sa tajmerom).
- Svi zahtevi asinhroni (`SimpleAsyncHTTP`), timeout 15 s.
- Rezultat i omot se keširaju po disc ID-u. Ručne izmene metapodataka se čuvaju u istom
  kešu i imaju prednost pri sledećem ubacivanju.

## 6. Reprodukcija: keš u RAM-u

- **Play** na stranici ili u meniju bira aktivni plejer (onaj iz kog je stigao zahtev; na
  web stranici izbor plejera, podrazumevano trenutno izabran u LMS web-u/Material-u).
- `Cache.pm` izvlači pesme redom, počevši od izabrane:
  `nice -n 10 ionice -c3 cd-paranoia -Z -d <dev> <N> -` → `flac -0 --silent` sa tagovima
  (naslov, izvođač, album, broj pesme, MusicBrainz ID-jevi) → `<cache_dir>/<discid>/NN.flac`
  (prvo `.part`, pa preimenovanje kad je gotovo).
  `-Z` isključuje paranoiu (brzo). Opcija „sigurno keširanje" koristi podrazumevanu paranoiu.
- `cache_dir`: `/run/audiocd` ako postoji i upisiv je (Audio$OS ga pravi preko tmpfiles),
  inače `/dev/shm/audiocd`, inače `<LMS cache>/AudioCD/play`. Brisanje pri izbacivanju diska,
  pri gašenju plugina i kad keš drugog diska zauzme mesto (čuva se samo trenutni disk).
- Plejlista: `audiocd://<discid>/<N>` za sve pesme, start od izabrane, kad je ta pesma
  izvučena (do tada stranica prikazuje „Pripremam…").
- `ProtocolHandler.pm` (registruje se za `audiocd`):
  - `getMetadataFor` vraća naslov, izvođača, album, trajanje iz TOC-a i URL omota
    (`/plugins/AudioCD/cover/<discid>.jpg`);
  - za strimovanje se ponaša kao lokalni FLAC fajl (nasleđuje `Slim::Player::Protocols::File`,
    URL se preslikava na keširani fajl);
  - ako pesma još nije izvučena, prebacuje je na početak reda i odlaže početak (tajmer,
    najviše 120 s, pa greška „pesma nije spremna").
- Bit-perfect: FLAC level 0 je bez gubitaka, 44.1 kHz / 16 bit, bez obrade. LMS servira FLAC
  (squeezelite nativno; UPnPBridge po svojim pravilima, kao bilo koji FLAC).
- Gapless i premotavanje rade jer su to obični FLAC fajlovi sa poznatom dužinom.
- Kad je sve izvučeno, drajv se više ne čita i sam se zaustavlja.
- Dok traje rip, Play nije moguć (i obrnuto). Ako je disk ceo u kešu, Play radi i tokom ripa
  jer ne koristi drajv.

## 7. Ripovanje

### Alat: cyanrip (Debian trixie `cyanrip` 0.9.3.1)
- Metapodatke daje plugin (ne oslanja se na cyanrip-ov MusicBrainz lookup), preko
  `-a` (album tagovi) i `-t` (tagovi po pesmi), pa se poštuju izbor izdanja i ručne izmene.
  Ako cyanrip prihvata MusicBrainz release ID (`-R`), prosleđuje se i on.
- Omot: plugin snima `cover.jpg` u folder albuma i prosleđuje ga cyanrip-u za ugrađivanje
  ako ta verzija to podržava.
- Izlaz: cyanrip piše u privremeni folder `<CD-Rips>/.audiocd-tmp/<jobid>/`; plugin posle
  uspeha premešta i preimenuje fajlove po `Naming.pm` i briše privremeni folder.
  Tako je imenovanje u našoj kontroli i ne zavisi od cyanrip šablona.
- Tačne opcije cyanrip-a (paranoia, ponavljanja, brzina, ofset drajva, FLAC nivo) se utvrđuju
  na serveru iz `cyanrip -h` za verziju u trixie-ju i fiksiraju u `Profiles.pm` i testovima.
  Ofset drajva: cyanrip ga traži preko AccurateRip baze; ako ne nađe, koristi se podešavanje
  „Ofset drajva" (podrazumevano prazno → cyanrip podrazumevano).
- Rezerva ako se cyanrip pokaže neupotrebljivim na trixie-ju: `cd-paranoia` + `flac` +
  AccurateRip proračun u Perl-u. To nije deo prve verzije.

### Profili

| Profil | Paranoia | Brzina drajva | AccurateRip | Ponavljanja |
|---|---|---|---|---|
| Najbrže | isključena | maksimalna | izračuna se i prijavi | ne |
| Uravnoteženo (podrazumevano) | podrazumevana | maksimalna | provera; pesma koja se ne slaže ripuje se ponovo jednom | 1 |
| Najveća sigurnost | puna | ograničena (podešavanje, podrazumevano 8x) | provera obavezna; neslaganje = upozorenje u logu i na stranici | do 5 |

Dodatna podešavanja: FLAC nivo (0–8, podrazumevano 5), tiši drajv (ograničenje brzine u svim
profilima), izbacivanje diska posle ripa, automatski rip pri ubacivanju (profil se bira),
obaveštenje kad se rip završi (poruka na plejerima koji su uključeni, kratak `showBriefly`).

### Nazivi i putanje (`Naming.pm`)
- `<CD-Rips>/<Izvođač>/<Album>/NN - <Naslov>.flac`; više diskova:
  `<Izvođač>/<Album>/Disc N/NN - <Naslov>.flac`.
- Kompilacije (više izvođača): folder izvođača „Various Artists", naziv fajla
  `NN - <Izvođač> - <Naslov>.flac`.
- Sanitizacija: uklanja `: ? * " < > | \ /` i kontrolne znakove (zamena `-` za `:` i `/`,
  ostalo se briše), skida tačke i razmake na kraju, rezervisana Windows imena (`CON`, `NUL`…)
  dobijaju `_`, dužina komponente najviše 200 bajtova UTF-8 (sečenje na granici znaka).
  Prazno ime → „Unknown".
- Ako ciljni folder albuma već postoji: dodaje se ` (2)`, ` (3)`… Nikad se ne prepisuje.
- Prava: fajlovi 0644, folderi 0755 (umask 022 za proces ripa).
- Uz fajlove: `cover.jpg`, `<Album>.log` (cyanrip log sa AccurateRip rezultatom), `<Album>.cue`.
- Tagovi: TITLE, ARTIST, ALBUM, ALBUMARTIST, TRACKNUMBER, TRACKTOTAL, DISCNUMBER, DISCTOTAL,
  DATE, MUSICBRAINZ_ALBUMID, MUSICBRAINZ_RELEASEGROUPID, MUSICBRAINZ_ARTISTID,
  MUSICBRAINZ_ALBUMARTISTID, MUSICBRAINZ_TRACKID, MUSICBRAINZ_DISCID.

### Tok posla
- Red poslova (FIFO). Jedan posao je jedan disk; posao se ne može dodati za disk koji nije u drajvu.
- Pre početka: provera slobodnog prostora (`df` preko `statvfs` nije dostupan u čistom Perl-u,
  pa `df -Pk <folder>`): potrebno = zbir trajanja × 176400 B/s × 0,7 + 50 MB. Ako nema mesta:
  jasna greška na stranici, posao se ne pokreće.
- Napredak: čita se izlaz cyanrip-a neblokirajuće (`Jobs.pm`), parsira se procenat po pesmi;
  ukupno = (završene pesme + udeo tekuće) / broj pesama, ponderisano trajanjem.
- Otkazivanje: `SIGTERM` grupi procesa, pa `SIGKILL` posle 5 s; privremeni folder se briše.
- Istorija: vreme, disk, profil, rezultat (AccurateRip: pesme tačne/ukupno), putanja.

### Premesti u biblioteku (`Library.pm`)
- Podešavanje „Folder biblioteke za CD" (podrazumevano prvi LMS muzički folder; na
  razvojnom serveru korisnik bira npr. `/mnt/wd16tb/Muzika/CD`).
- Akcija za završen rip iz istorije: potvrda u dijalogu, odredište
  `<biblioteka>/<Izvođač>/<Album>`. Ako odredište postoji → greška, ništa se ne menja.
- Premeštanje: `rename` ako je isti fajl sistem, inače kopija (`File::Copy`) + provera veličina +
  brisanje izvora. HDD može da spava: prvi upis može da čeka do ~10 s, timeout je 60 s.
- Posle uspeha: LMS skeniranje samo tog foldera (`rescan` sa putanjom, isto što radi
  „Scan folder" u LMS-u).

## 8. Korisnički interfejs

- **Stranica** `/plugins/AudioCD/index.html` (statični HTML + JS, podaci preko JSON-RPC
  `["audiocd","status"]` i komandi `load`, `play`, `rip`, `cancel`, `eject`, `select_release`,
  `edit`, `move`, `history`). Osvežavanje svakih 2 s dok traje posao, inače 10 s.
  Prikazuje: omot, izvođač, album, godina, pesme sa trajanjem, izbor izdanja, izmenu
  metapodataka, dugmad Play / Ripuj / Eject / Učitaj CD, napredak, red, istoriju sa
  „Premesti u biblioteku". Svetla i tamna tema prate sistem.
- **Ripuj dijalog**: folder (podrazumevani se može promeniti), profil, FLAC nivo, izbacivanje posle ripa.
- **Material Skin**: `MaterialBridge.pm` upisuje blok u Material `custom.js` (kao Unified Music);
  skripta dodaje stavku „CD" koja otvara stranicu plugina u Material dijalogu/iframe-u.
- **Meni** „CD" u My Music (i Extras) preko `Slim::Menu`/Jive: stavke disk (izvođač – album),
  Play, Ripuj (podrazumevani profil), Eject. Radi iz aplikacija i iz Material-a.
- **Podešavanja**: uređaj (podrazumevano `/dev/cdrom`), folder za rip-ove, folder biblioteke,
  podrazumevani profil, FLAC nivo, tiši drajv i brzina, ofset drajva, automatsko očitavanje
  (uključeno), automatski rip (isključeno), izbacivanje posle ripa (isključeno),
  obaveštenja (uključeno), polling (uključeno), sigurno keširanje za Play (isključeno).
- Tekstovi u `strings.txt` (EN i SR).

## 9. Greške

| Situacija | Ponašanje |
|---|---|
| Nema prava na uređaj | poruka sa uputstvom (grupa `cdrom`) |
| Nema diska / data disk | „Nema audio diska" |
| Nema interneta / timeout | generički nazivi, dugme „Pokušaj ponovo" |
| Nema `cyanrip` / `cd-paranoia` / `flac` | dugme onemogućeno, poruka koji paket fali |
| Nema mesta | greška pre početka ripa, sa potrebnim i slobodnim prostorom |
| Disk izvađen tokom posla | posao se prekida, privremeni fajlovi brišu, poruka |
| AccurateRip neslaganje | rip se završava, upozorenje u istoriji i na stranici |
| Odredište postoji | ` (2)` za rip; greška bez izmena za „Premesti" |

## 10. Audio prioritet i USB

- Svi procesi: `nice -n 10 ionice -c3` (komanda se gradi u jednom mestu, `Jobs.pm`, i testira).
- Na Audio$OS-u LMS već radi van `audio.slice`; procesi nasleđuju njegov cgroup.
- Mera na razvojnom serveru: rip i keširanje dok lokalni squeezelite svira preko USB DAC-a
  (isti USB 2.0 kontroler kao drajv). Beleži se `xrun`/prekid u logu squeezelite-a i slušno.
  Rezultat ulazi u `INTEGRATION.md`. Ako ima prekida: podešavanje „Ne ripuj dok lokalni plejer
  svira" (podrazumevano uključeno na Audio$OS-u).

## 11. Testovi (Perl, `prove`, bez LMS-a)

- `DiscId`: poznati TOC-ovi → MusicBrainz disc ID i CDDB ID (primeri iz MusicBrainz
  dokumentacije i TOC pravog diska sa servera); enhanced CD.
- `Drive`: pakovanje/raspakivanje ioctl struktura.
- `Metadata`: fixture-i MusicBrainz odgovora (jedno izdanje, više izdanja, više diskova,
  Various Artists, prazan odgovor), GnuDB odgovor, CD-Text izlaz.
- `Naming`: sanitizacija, rezervisana imena, sečenje UTF-8, multi-disc, kompilacije, ` (2)`.
- `Profiles`: tačni argumenti cyanrip-a i `nice`/`ionice` prefiks za svaki profil i opcije.
- `Config`: parsiranje `KEY=value` sa komentarima i navodnicima, redosled izvora.
- `MaterialBridge`: dodavanje i uklanjanje bloka.

## 12. Isporuka

- `src/AudioCD/` (plugin), `tests/perl/`, `tools/` (build release, pokretanje testova),
  `packaging/` (`get.sh`, `install.sh`, `uninstall.sh`, README sr/en), po uzoru na Unified Music.
- `system/`: `99-audiocd.rules`, `audiocd-notify@.service`, `audiocd-notify` skripta,
  `tmpfiles.d/audiocd.conf` (`/run/audiocd`, vlasnik `squeezeboxserver`).
- `INTEGRATION.md` za Audio$OS: paketi (trixie: `cyanrip`, `cd-paranoia`, `flac`,
  `libcdio-utils`, `eject`, `curl`), udev, systemd, tmpfiles, grupa `cdrom`, putanja plugina
  (`/var/lib/squeezeboxserver/Plugins/AudioCD` ili ugrađen u ISO), podešavanja i
  podrazumevane vrednosti, šta radi sa `nice`/`ionice`, rezultat USB merenja, smoke test komande.
- Release na GitHub-u sa zip paketom i `get.sh`.

### Provera na razvojnom serveru (definicija „gotovo")
- Očitavanje pravog diska sa metapodacima i omotom.
- Disk bez podataka (simulacija: isključen internet ili lažni disc ID) → Track N i generički omot.
- Play na lokalnom squeezelite-u i na FiiO SR11 (UPnPBridge), gapless prelaz.
- Rip u sva tri profila sa AccurateRip rezultatom u logu.
- Fajlovi vidljivi u `/var/lib/squeezeboxserver/CD-Rips`.
