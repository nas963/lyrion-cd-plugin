# Provera na pravom disku (2026-11-12)

Server za razvoj (Lyrion 9.1.1, Ubuntu 24.04), plugin AudioCD 0.1.0, pravi disk: Bobby McFerrin, "The Story of Jazz"
(9 pesama, 43:11, MusicBrainz fuzzy poklapanje, nema CD-Texta). Drajv: USB ASUS SDRW-08U7M-U, cyanrip 0.9.0.
Igraci: Protodac HiFi (glavni), FiiO SR11 preko UPnPBridge-a (kratko). CastBridge igraci nisu koristeni.
Svi igraci su na kraju zaustavljeni. Nisu pisani fajlovi u biblioteku (`/mnt/wd16tb`).

Merenje USB DAC-a (Task 17 Step 5) nije moguce: na ovom serveru nema lokalnog squeezelite-a ni DAC-a.
Umesto toga izmereno je opterecenje i prioritet procesa (vidi "Opterecenje").

## 1. Ocitavanje (Step 1)

- `["audiocd","status"]`: status `ready`, izvor `musicbrainz`, album "The Story of Jazz", izvodjac Bobby McFerrin,
  9 pesama sa naslovima, `release_idx` 2 (EMI Plus, 2000), 4 kandidata, `fuzzy: 1`, `cover: 1`.
- Omot `/plugins/AudioCD/cover/<discid>.jpg`: HTTP 200, `image/jpeg`, 500x500, 68346 bajtova.
- Web stranica `/plugins/AudioCD/index.html`: HTTP 200, prikaz se gradi u pregledacu iz JSON-a (nije otvarana u pregledacu).
  Material: proverava kontrolor.

## 2. Disk bez podataka (Step 2)

- `["audiocd","load","offline:1"]` -> `ready`, izvor `generic`, album "Audio CD", izvodjac "Unknown Artist",
  pesme "Track 1" ... "Track 9".
- Zapazanje: `cover` ostaje 1 i `cover_url` pokazuje na vec kesiran omot iz MusicBrainz-a (omot je u kesu po ID-u
  diska, `offline` ga ne zaobilazi). Genericki omot se vidi samo za disk kome omot nikad nije kesiran. Taj slucaj nije
  mogao da se proveri (kes folder pripada servisnom nalogu Lyrion-a, bez sudo-a se ne brise).
- `load force:1` vratilo MusicBrainz podatke i naslove.

## 3. Play (Step 3)

Protodac HiFi, `["audiocd","play","track:1"]` (red ima svih 9 pesama):

| Merenje | Rezultat |
|---|---|
| Prva pesma spremna za sviranje (kes) | ~34 s od komande (pesma traje 292 s, ~8.6x brze od realnog vremena) |
| Ceo disk u kesu (RAM) | ~207 s (43:11, ~12.5x) |
| Premotavanje (`time 270`) | radi, brojac nastavlja od 275 s |
| Prelaz 1 -> 2 | bez pauze u brojacu: 290.4 s pa 1.3 s pesme 2 (indeks 0 -> 1), nema greske u `server.log` |
| Sviranje tokom ripa | 297 od 297 uzoraka (15 min, svake 3 s) `mode=play`, pesme 1 -> 5 prosle bez prekida |

Slusno (gapless) nije proveravano, nema ko da slusa. Brojac vremena i indeks pesme se ponasaju kako treba.

FiiO SR11 (UPnPBridge), `play track:1`, `time 280`: svirao je, premotavanje radi. Na kraju prve pesme (292.173 s)
brojac je stao i ostao na 292.173 s vise od 40 s, indeks je ostao 0: prelaz na pesmu 2 se NIJE desio sam.
`playlist index +1` (preskakanje) je odmah poterao pesmu 2 ("Turtle Shoes", brojac 8.5 s pa 15.6 s). Zaustavljen.
Ovo izgleda kao ogranicenje UPnPBridge-a (nema gapless / zavrsetak pesme), ne plugina, ali uzrok nije dokazan.
Treba ponoviti bez ripa u pozadini da se iskljuci opterecenje kao uzrok.

Pokusaj `play` dok traje rip i kes nije gotov: `drive_busy` (po pravilu "drajv radi jednu stvar").

## 4. Rip u sva tri profila (Step 4)

Folder `/var/lib/squeezeboxserver/CD-Rips/Bobby McFerrin/`. Isti disk tri puta zaredom:

| Profil | Folder | Trajanje | Argumenti cyanrip-a (bitno) | Velicina |
|---|---|---|---|---|
| fast | `The Story of Jazz` | 1016 s (16.9 min), uz sviranje iz kesa | `-P 0` | 233.727.146 B |
| balanced | `The Story of Jazz (2)` | 1400 s (23.3 min) | `-r 1`, paranoia max | 233.727.188 B |
| secure | `The Story of Jazz (3)` | 1447 s (24.1 min) | `-P 3 -r 5`, bez `-S` (vidi nize) | 233.726.779 B |

- Drugi i treci rip su sleteli u "(2)" i "(3)", prvi folder netaknut.
- Svaki folder: 9 x `.flac`, `cover.jpg`, `The Story of Jazz.cue`, `The Story of Jazz.log` (12 fajlova), fajlovi 0644, folder 0755.
- Tagovi (`metaflac --export-tags-to=-`): title, TRACKNUMBER, album, ALBUMARTIST, artist, date, DISCNUMBER, tracktotal, disctotal,
  discid, cddb, musicbrainz_discid / albumid / releasegroupid / albumartistid / trackid / artistid, ReplayGain (pesma i album),
  R128, ugradjen omot (500x500 JPEG, tip Front).
- MD5 audio dela svih 9 fajlova (`metaflac --show-md5sum`) je IDENTICAN u sva tri rip-a (3dcc8b57...). Citanje je dakle isto
  u fast, balanced i secure profilu.
- AccurateRip, tacno kako pise `.log`: `AccurateRip: found`, za svaku pesmu
  `Accurip: disc found in database (max confidence: 15)` (pesma 4: 14), pa
  `Accurip v1: <crc> (not found, either a new pressing, or bad rip)`, isto za `v2` i `450`.
  Disk JE u AccurateRip bazi, ali nijedan checksum se ne poklapa (9 od 9 `mismatch`, istorija `accurip_mismatch`).
- Uzrok (provereno 2026-11-13): najverovatnije ofset citanja drajva, ne drugo izdanje. Rip-ovi su radjeni bez podesenog
  ofseta (pref `driveOffset` prazan -> cyanrip `-s 0`). U drajvu je tada vec bio DRUGI disk (Enigma "The Cross of
  Changes", MB disc ID N704SvqX04youSS9n7TsOOUp308-, 9 pesama, CDDB 710a5e09; korisnik ga je ubacio 2026-11-12), pa je
  provera ofseta radjena na njemu. `cyanrip -f` na ovom drajvu (ASUS SDRW-08U7M-U, A112) je dao
  `Drive offset of +6 found (confidence: 9)` (potvrdjeno na svih 9 pesama), isto kao AccurateRip lista drajvova (+6).
  Rip pesama 1 i 2 tog diska sa `-s 6` (argumenti iz `Profiles::rip_argv`, profil fast, test folder van CD-Rips):
  `Accurip: disc found in database (max confidence: 200)`, `Accurip v1: ... (accurately ripped, confidence 197)`,
  `Accurip v2: ... (accurately ripped, confidence 200)` za obe pesme, `Tracks ripped accurately: 2/9` (cyanrip deli sa
  brojem pesama diska). Te linije su sada fixture `tests/fixtures/cyanrip-output-ar-match.txt` (parse_progress daje
  `match`, summary 2/9). Ofset se NE upisuje automatski: korisnik ga unosi u Settings (Ofset drajva = 6). Rip koji
  zavrsi sa svim pesmama `mismatch` dok je disk u bazi dobija u istoriji `note: check_offset` i stranica pokazuje savet.
  "The Story of Jazz" sa ofsetom +6 nije ponovo ripovan (disk nije u drajvu): 9/9 mismatch uz disk u bazi je tipican
  znak ofseta 0 umesto +6, ali za taj disk to ostaje nepotvrdjeno. Tri postojeca rip-a u CD-Rips nisu dirana.
  Napomena: cyanrip linija `DiscID:` u izlazu pokazuje vrednost iz `-a discid=...` (nasa oznaka), ne izracunat ID.
- `.audiocd-tmp` ostaje prazan (samo sam folder), nema `.part` ostataka.
- Defekt (popravljen): `.cue` u prva dva rip-a ima `FILE "var/lib/.../.audiocd-tmp/rip-.../1.flac"`; popravka je
  u commit-u "Fix: cue FILE linije ...". Treci rip ima ispravno `FILE "01 - Don't Worry Be Happy.flac"`.
  Prva dva `.cue` fajla ostaju neispravna (folder pripada drugom korisniku).
- Defekt (popravljen): `secure` profil je pri prvom pokusaju pao posle 4 s: `Device does not support changing speeds!`
  (`-S 8`, ovaj USB drajv ne menja brzinu). Sada Ripper pri toj poruci ponavlja rip bez `-S`
  (commit "Fix: secure profil na drajvu koji ne menja brzinu ...").

## 5. Opterecenje i prioritet (umesto USB merenja)

- Svi procesi (cyanrip, cd-paranoia, flac): `NI 10` i `ionice` klasa `idle`, obican `TS` raspored (nema RT).
- Kesiranje (cd-paranoia + flac -0): po ~1% CPU svaki, `wa` oko 23% u jednom uzorku (drajv je usko grlo), load ~1.2.
- cyanrip: fast ~58% CPU, balanced ~73%, secure ~55% jednog jezgra (4 jezgra), stanje `D` (ceka drajv), load ~1.8.
- Sviranje iz kesa (RAM) tokom celog fast rip-a nije prekinuto (vidi Play). Preporuka za `noRipWhileLocalPlays`:
  ostaje 0 (podrazumevano): na ovom serveru nije bilo smetnji; sa USB DAC-om na istom kontroleru treba posebno proveriti.

## 6. Review Focus (Step 6)

- Restart LMS-a usred ripa (secure, ~2 min posle starta): posle restarta nema `cyanrip` / `cd-paranoia` / `flac` procesa,
  `.audiocd-tmp` je prazan, stanje `ready`.
- Nedostatak: prekinuti rip se NE pojavljuje u istoriji (ni kao `cancelled` ni kao `error`); `shutdown` ubija procese i brise
  tmp, ali ne upisuje zapis. Nije popravljeno (nije malo): `kill_all` ne poziva povratne pozive, pa bi zapis morao da se
  upise direktno u `State::shutdown`.
- `Play all` / pesma u meniju (`browselibrary items mode:audiocd`): 12 stavki (9 pesama, Play all, Rip, Eject).
  Pesma i Play all zovu `audiocd play track:N`; `track:1` ubacuje svih 9 pesama u red (provereno: `playlist_tracks` 9).
- Premestanje (Ruling 19): `CD-Rips` nije upisiv za nalog koji pokrece testove, pa je kopija albuma
  napravljena u privremenom folderu na istom disku, odatle `move_async` u `/dev/shm/audiocd-move-test/` (drugi
  fajl sistem, EXDEV). Rezultat: `cp -a` u skriveni `.part`, provera velicina (233.727.146 B isto), rename, izvor obrisan,
  prazan roditelj (`_movetest`) uklonjen, bajt-isto (`cmp`) kao original, `on_done ok=1` za 0.4 s.
  Prvi pokusaj je dao `verify_failed`: stvarni defekt (popravljen), `_verify_tree` je dvaput kodirao imena sa ne-ASCII
  znacima ("Don't", "Manana") i test nije imao takva imena (commit "Fix: provera kopije ...").
  CLI `move` sa `dest` van muzickih foldera: `outside_library` (i za `/tmp` i `/dev/shm/x`); nepoznat id: `not_found`.
- Offline `load` i vracanje: vidi 2.

## 7. Ostaje za korisnika

- Vadjenje diska usred kesiranja i usred ripa; udev automatsko prepoznavanje po instalaciji sistemskih fajlova.
- Material klik-staza; pregled web stranice u pregledacu.
- Merenje sa lokalnim DAC-om (USB) kad takav postoji.
- FiiO SR11 prelaz pesama ponoviti bez ripa u pozadini.
