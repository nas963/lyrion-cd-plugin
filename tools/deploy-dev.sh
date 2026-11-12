#!/usr/bin/env bash
# Kopira src/AudioCD u zivi Plugins folder Lyrion-a (bez sudo-a).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=/var/lib/squeezeboxserver/Plugins/AudioCD

ssh -o BatchMode=yes lyrion "rm -rf '$DEST'/* && mkdir -p '$DEST'"
scp -q -r "$ROOT"/src/AudioCD/. "lyrion:$DEST/"
echo "deploy ok: $DEST"
