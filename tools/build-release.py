#!/usr/bin/env python3
"""Pravi paket za instalaciju: python build-release.py <verzija>

Rezultat je folder dist/ sa audiocd.zip (prva instalacija preko get.sh: plugin + sistemski deo), njegovim
otiskom, skriptom get.sh i AudioCD-<verzija>.zip (samo plugin, za Lyrion-ov repozitorijum), i repo.xml u
korenu repoa (GitHub Pages: https://nas963.github.io/lyrion-cd-plugin/repo.xml). Preko repo.xml Lyrion
sam azurira plugin; commit-uje se repo.xml bas onog zip-a koji se objavljuje (svaki build menja SHA-1).
"""
import hashlib
import pathlib
import re
import sys
import time
import zipfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Vreme pravljenja, ne fiksni datum: LMS osvezava kes stringova samo kad strings.txt postane noviji.
BUILD_TIME = time.localtime()[:6]
PLUGIN = ROOT / 'src' / 'AudioCD'
NAME = 'AudioCD'
GITHUB = 'https://github.com/nas963/lyrion-cd-plugin'
SYSTEM = ROOT / 'system'
# Fajlovi u system/ nemaju sufiks (audiocd-notify) ili imaju .rules/.service/.conf.
TEXT_SUFFIXES = {'', '.pm', '.txt', '.html', '.js', '.xml', '.sh', '.md', '.svg', '.css',
                 '.rules', '.service', '.conf', '.json'}


def lf_bytes(path):
    data = path.read_bytes()
    if path.suffix in TEXT_SUFFIXES and b'\r' in data:
        raise SystemExit(f'CRLF u fajlu: {path}')
    return data


def add(out, name, data, executable=False):
    info = zipfile.ZipInfo(name, date_time=BUILD_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (0o755 if executable else 0o644) << 16
    out.writestr(info, data)


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'\d+\.\d+\.\d+', sys.argv[1]):
        raise SystemExit(__doc__)
    version = sys.argv[1]

    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    top = f'audiocd-{version}'
    # Stalan naziv omogucava adresu /releases/latest/download/audiocd.zip.
    target = dist / 'audiocd.zip'
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as out:
        for name in ('install.sh', 'uninstall.sh', 'lms-repo.py'):
            add(out, f'{top}/{name}', lf_bytes(ROOT / 'packaging' / name), executable=True)
        for name in ('README.md', 'README.en.md'):
            add(out, f'{top}/{name}', lf_bytes(ROOT / 'packaging' / name))
        add(out, f'{top}/LICENSE', lf_bytes(ROOT / 'LICENSE'))
        for path in sorted(SYSTEM.rglob('*')):
            if path.is_dir():
                continue
            add(out, f'{top}/system/{path.relative_to(SYSTEM).as_posix()}', lf_bytes(path),
                executable=(path.name == 'audiocd-notify'))
        # Verzija ide i u install.xml i u Plugin.pm ($VERSION: User-Agent, status); test 50 trazi da budu iste.
        found_xml = found_pm = False
        plugin_files = []
        for path in sorted(PLUGIN.rglob('*')):
            if path.is_dir():
                continue
            data = lf_bytes(path)
            if path.name == 'install.xml' and path.parent == PLUGIN:
                data, count = re.subn(rb'<version>[^<]*</version>',
                                      b'<version>' + version.encode() + b'</version>', data)
                if count != 1:
                    raise SystemExit('install.xml: ocekivan tacno jedan <version>')
                found_xml = True
            if path.name == 'Plugin.pm' and path.parent == PLUGIN:
                data, count = re.subn(rb"our \$VERSION = '[^']*';",
                                      b"our $VERSION = '" + version.encode() + b"';", data)
                if count != 1:
                    raise SystemExit('Plugin.pm: ocekivan tacno jedan our $VERSION')
                found_pm = True
            add(out, f'{top}/AudioCD/{path.relative_to(PLUGIN).as_posix()}', data)
            plugin_files.append((path.relative_to(PLUGIN).as_posix(), data))
        if not found_xml:
            raise SystemExit('Nema src/AudioCD/install.xml')
        if not found_pm:
            raise SystemExit('Nema src/AudioCD/Plugin.pm')
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (dist / 'audiocd.zip.sha256').write_text(f'{digest}  audiocd.zip\n', encoding='ascii', newline='\n')
    (dist / 'get.sh').write_bytes(lf_bytes(ROOT / 'packaging' / 'get.sh'))
    print(target)

    # Zip za Lyrion-ov repozitorijum: folder AudioCD/ (isti fajlovi kao u paketu), i repo.xml
    lms_zip = dist / f'{NAME}-{version}.zip'
    with zipfile.ZipFile(lms_zip, 'w', zipfile.ZIP_DEFLATED) as out:
        for rel, data in plugin_files:
            add(out, f'{NAME}/{rel}', data)
        add(out, f'{NAME}/LICENSE', lf_bytes(ROOT / 'LICENSE'))
    sha1 = hashlib.sha1(lms_zip.read_bytes()).hexdigest()
    title, desc = strings('PLUGIN_AUDIOCD'), strings('PLUGIN_AUDIOCD_DESC')
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<extensions>',
        '  <details>',
        f'    <title lang="EN">{escape(title.get("EN", NAME))}</title>',
        '  </details>',
        '  <plugins>',
        f'    <plugin name="{NAME}" version="{version}" minTarget="8.0" maxTarget="*">',
    ]
    lines += [f'      <title lang="{l}">{escape(t)}</title>' for l, t in title.items()]
    lines += [f'      <desc lang="{l}">{escape(t)}</desc>' for l, t in desc.items()]
    lines += [
        '      <creator>nas963</creator>',
        '      <category>tools</category>',
        f'      <link>{GITHUB}</link>',
        f'      <url>{GITHUB}/releases/download/v{version}/{lms_zip.name}</url>',
        f'      <sha>{sha1}</sha>',
        '    </plugin>',
        '  </plugins>',
        '</extensions>',
        '',
    ]
    (ROOT / 'repo.xml').write_bytes('\n'.join(lines).encode('utf-8'))
    print(f'{lms_zip}  sha1 {sha1}')


def strings(key):
    """EN i SR tekst jednog kljuca iz strings.txt."""
    out, cur = {}, None
    for line in (PLUGIN / 'strings.txt').read_text(encoding='utf-8').splitlines():
        if line and not line[0].isspace():
            cur = line.strip()
        elif cur == key and line.strip():
            parts = line.strip().split(None, 1)
            if len(parts) == 2:
                out[parts[0]] = parts[1].strip()
    return out


if __name__ == '__main__':
    main()
