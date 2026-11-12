#!/usr/bin/env bash
# Kopira plugin i testove u jedinstven folder (~/audiocd-test.XXXXXX) na serveru i pokrece ih;
# folder se na kraju brise, pa paralelni pokretanja ne gaze jedno drugo.
# Zivi plugin i Lyrion se ne diraju.
# LMS -I putanje se ne daju proveru-u: CPAN/Test::More iz LMS-a je star i zasenio bi sistemski.
# Testovi koji trebaju Slim::* koriste t/lib/LMSBoot.pm (zaseban perl proces sa LMS putanjama).
# Upotreba: tools/run-perl-tests.sh [t/NN-ime.t]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REMOTE="$(ssh -o BatchMode=yes lyrion 'mktemp -d ~/audiocd-test.XXXXXX')"
cleanup() { ssh -o BatchMode=yes lyrion "rm -rf '$REMOTE'" || true; }
trap cleanup EXIT

ssh -o BatchMode=yes lyrion "mkdir -p '$REMOTE/lib/Plugins' '$REMOTE/t'"
scp -q -r "$ROOT/src/AudioCD" "lyrion:$REMOTE/lib/Plugins/"
scp -q "$ROOT"/tests/perl/*.t "lyrion:$REMOTE/t/"
if [ -d "$ROOT/tests/perl/lib" ]; then
    scp -q -r "$ROOT/tests/perl/lib" "lyrion:$REMOTE/t/"
fi
if [ -d "$ROOT/tests/fixtures" ]; then
    scp -q -r "$ROOT/tests/fixtures" "lyrion:$REMOTE/t/"
fi
if [ -d "$ROOT/system" ]; then
    scp -q -r "$ROOT/system" "lyrion:$REMOTE/"
fi
ssh -o BatchMode=yes lyrion "cd '$REMOTE' && prove -r -I lib ${1:-t}"
