#!/usr/bin/env python3
"""Pravi paket za instalaciju: python build-release.py <verzija>

Rezultat je folder dist/ sa audiocd.zip, njegovim otiskom i skriptom get.sh.
"""
import hashlib
import pathlib
import re
import sys
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Vreme pravljenja, ne fiksni datum: LMS osvezava kes stringova samo kad strings.txt postane noviji.
BUILD_TIME = time.localtime()[:6]
PLUGIN = ROOT / 'src' / 'AudioCD'
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
        for name in ('install.sh', 'uninstall.sh'):
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
        if not found_xml:
            raise SystemExit('Nema src/AudioCD/install.xml')
        if not found_pm:
            raise SystemExit('Nema src/AudioCD/Plugin.pm')
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (dist / 'audiocd.zip.sha256').write_text(f'{digest}  audiocd.zip\n', encoding='ascii', newline='\n')
    (dist / 'get.sh').write_bytes(lf_bytes(ROOT / 'packaging' / 'get.sh'))
    print(target)


if __name__ == '__main__':
    main()
