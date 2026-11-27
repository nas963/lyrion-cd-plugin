# AudioCD za Lyrion

Plugin koji pretvara Lyrion server sa CD uređajem u pravi CD plejer i uređaj za snimanje albuma, slično Daphile-u.

## Šta radi
- **Automatsko čitanje diska.** Kad ubaciš CD, plugin pročita sadržaj i potraži podatke (MusicBrainz, zatim GnuDB, a ako disk ima i CD-Text). Dobiješ naslov albuma, izvođača, pesme i omot. Ako MusicBrainz nađe samo približno poklapanje, ponudi se izbor izdanja.
- **Slušanje.** Pesme se prvo čitaju u keš u RAM-u (`/run/audiocd`), pa se sviraju odatle: bit-perfect i bez prekida između pesama (gapless). Muzika kreće čim je učitano oko 15 s, a ostatak se učitava dok svira (premotavanje radi kad se pesma učita). Uz **Direktno puštanje** čitaju se samo tekuća i sledeća pesma, umesto celog diska. Stranica plugina ima displej kao na CD plejeru (klik menja prikaz vremena), a ispod njega talasni oblik pesme kao kod Roon-a (pojavi se kad je pesma učitana; klik premotava) i dugmad prethodna, **Play/Pauza**, **Stop** i sledeća. Kad se disk izvadi, plejer staje i pesme tog diska se uklanjaju iz liste. **Ripuj** nudi da se slušanje (i čitanje diska za slušanje) prvo zaustavi.
- **Snimanje.** Album se snima programom `cyanrip` u FLAC, u tri profila: brz (`fast`), uravnotežen (`balanced`) i siguran (`secure`, sa više ponovnih čitanja i manjom brzinom). Rezultat se proverava preko AccurateRip baze.
- **Premeštanje u biblioteku.** Biraš gde ide snimljeni album: glavni muzički folder (npr. CD, SACD, Hi-Res), pa folder izvođača (postojeći ili nov) i naziv foldera albuma. Lyrion zatim skenira samo taj folder (ako baš tada skenira biblioteku, skeniranje albuma čeka da to završi, najviše 30 minuta). Postojeći folder se nikad ne prepisuje.
- **Material Skin.** CD se pojavljuje na početnom ekranu Materiala, sa omotom, listom pesama i dugmadima za sviranje, snimanje i izbacivanje. U meniju **Audio CD** (Moja muzika) disk je jedna stavka: otvori je i dobićeš listu pesama sa dugmadima **Play** i **Add** u zaglavlju. Pored diska su stavke **Ripuj** i **Eject**. Stranica plugina otvorena iz Materiala prati njegovu temu (svetla/tamna), svira na plejeru izabranom u Materialu (bez posebnog izbora plejera), a **Podešavanja** se otvaraju u novom tabu.

Jezik ekrana prati jezik Lyriona (srpski ili engleski).

## Zahtevi
- Lyrion Music Server 9.x na Debianu ili Ubuntuu, instaliran kao paket (servis `lyrionmusicserver`).
- Optički čitač koji vidi sistem, obično `/dev/cdrom`.
- Paketi: `cyanrip`, `cd-paranoia`, `flac`, `libcdio-utils` (daje `cd-info`), `eject`, `curl`.

Instalacija ne dodaje pakete sama. Ako nešto nedostaje, ispiše tačnu naredbu:

```bash
sudo apt install cyanrip cd-paranoia flac libcdio-utils eject curl
```

## Instalacija i ažuriranje
Na serveru, preko SSH-a:

```bash
curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash
```

Ako javi da nedostaje `curl` ili `python3`: `sudo apt install curl python3`.

Naredba preuzme poslednje izdanje, proveri ga i pokrene instalaciju. Potrebna je samo jednom.

Instalacija stavlja plugin tamo gde Lyrion drži pluginove iz repozitorijuma (`/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/AudioCD`) i upisuje u Lyrion repozitorijum `https://nas963.github.io/lyrion-cd-plugin/repo.xml`. Dodaje udev pravilo i servis koji javlja Lyrionu da je disk ubačen, i dodaje korisnika `squeezeboxserver` u grupu `cdrom`. Lyrion se za to vreme zaustavi (reprodukcija se prekida). Posle toga osveži Material u pregledaču.

**Ažuriranje:** nove verzije Lyrion preuzima sam, kao za bilo koji drugi plugin (Podešavanja → Plugins). Ako je tamo uključeno automatsko ažuriranje, nova verzija se instalira pri sledećem restartu Lyriona. Stara ručna instalacija u `/var/lib/squeezeboxserver/Plugins/AudioCD` (do verzije 1.6.0) se pri instalaciji uklanja.

## Podešavanja
Lyrion: Podešavanja, Dodaci, **AudioCD**.

| Podešavanje | Podrazumevano | Šta znači |
|---|---|---|
| Uređaj | `/dev/cdrom` | CD uređaj |
| Folder za snimke | (prazno) | vidi ispod |
| Folder biblioteke | (prazno) | gde se album premešta bez izbora (stari način, za komandnu liniju); na stranici se odredište bira u dijalogu |
| Profil | uravnotežen | profil snimanja |
| Tihi drajv | isključeno | smanji brzinu čitanja |
| Brzina tihog drajva | 8 | brzina (x) kad je tihi drajv uključen |
| Offset drajva | (prazno) | korekcija čitanja za AccurateRip; nađi ga sa `cyanrip -f` (treba disk koji je u AccurateRip bazi) |
| Automatski učitaj disk | uključeno | čitaj podatke čim se disk ubaci |
| Kad se ubaci CD | ništa | ništa / pusti na izabranom plejeru / ripuj |
| Plejer za automatsko puštanje | - | plejer koji već svira se ne prekida |
| Profil automatskog snimanja | uravnotežen | |
| Izbaci posle snimanja | isključeno | |
| Obaveštenja | uključeno | udev javlja kad se disk ubaci ili izvadi |
| Provera u pozadini | uključeno | dopuna kad udev nije dostupan |
| Sigurno čitanje u keš | isključeno | pesme se u keš čitaju sporije i pažljivije |
| Direktno puštanje | isključeno | bez učitavanja celog diska; važi za sve plejere i mostove |
| Počni puštanje odmah | uključeno | ne važi za UPnP, Chromecast i AirPlay mostove, ni za brzinu čitanja ispod 4 |

FLAC nivo kompresije nema: `cyanrip` uvek koristi najjaču.

## Gde idu snimci
Folder za snimke se traži ovim redom:
1. podešavanje **Folder za snimke**, ako je upisano;
2. `CD_RIPS_DIR` iz `/etc/audioos/audioos.conf`;
3. `CD_RIPS_DIR` iz `/usr/local/lib/audioos/defaults.conf`;
4. `/var/lib/squeezeboxserver/CD-Rips`.

Svaki album dobija svoj folder; postojeći folder albuma se nikad ne prepisuje. Fajlovi su 0644, folderi 0755.

## Poznata ograničenja
- Podržan je jedan optički uređaj. Drajv radi jednu stvar u trenutku: čitanje u keš ili snimanje.
- Verzije `cyanrip` se razlikuju (Ubuntu 0.9.2, Debian trixie 0.9.3): izlaz i oznake mogu malo da se razlikuju.
- AccurateRip javlja "nije nađeno" za diskove kojih nema u bazi; to ne znači grešku u snimku. Ako je disk nađen, a nijedna pesma se ne slaže, ofset drajva nije podešen ili je pogrešan (vidi Offset drajva).
- Merenje uticaja na USB DAC na istom kontroleru još nije urađeno.

## Uklanjanje
```bash
curl -fsSL https://github.com/nas963/lyrion-cd-plugin/releases/latest/download/get.sh | sudo bash -s uninstall
```

Uklanja plugin, sistemske fajlove i AudioCD blok iz `custom.js` (ostatak fajla se ne dira) i restartuje Lyrion. Snimljeni albumi (CD-Rips) ostaju, a korisnik `squeezeboxserver` ostaje u grupi `cdrom`.

## Licenca
GPL-2.0, vidi `LICENSE`.
