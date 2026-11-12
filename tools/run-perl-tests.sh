#!/usr/bin/env bash
# Kopira plugin i testove u ~/audiocd-test na serveru i pokrece ih.
# Zivi plugin i Lyrion se ne diraju.
# LMS -I putanje se ne daju proveru-u: CPAN/Test::More iz LMS-a je star i zasenio bi sistemski.
# Testovi koji trebaju Slim::* sami dodaju -I putanje (vidi 50-plugin-syntax.t).
# Upotreba: tools/run-perl-tests.sh [t/NN-ime.t]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=audiocd-test


ssh -o BatchMode=yes lyrion "rm -rf ~/$REMOTE && mkdir -p ~/$REMOTE/lib/Plugins ~/$REMOTE/t"
scp -q -r "$ROOT/src/AudioCD" "lyrion:$REMOTE/lib/Plugins/"
scp -q "$ROOT"/tests/perl/*.t "lyrion:$REMOTE/t/"
if [ -d "$ROOT/tests/fixtures" ]; then
    scp -q -r "$ROOT/tests/fixtures" "lyrion:$REMOTE/t/"
fi
ssh -o BatchMode=yes lyrion "cd ~/$REMOTE && prove -r -I lib ${1:-t}"
