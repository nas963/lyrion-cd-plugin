#!/usr/bin/env bash
# Restartuje Lyrion preko JSON-RPC-a i ceka da ponovo odgovori (najvise 120 s).
set -euo pipefail

rpc() {
    ssh -o BatchMode=yes lyrion "curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{\"id\":1,\"method\":\"slim.request\",\"params\":[\"\",$1]}' http://localhost:9000/jsonrpc.js"
}

rpc '["restartserver"]' || true
sleep 5
for i in $(seq 1 115); do
    if rpc '["serverstatus",0,1]' 2>/dev/null | grep -q '"version"'; then
        echo "Lyrion radi (posle ~$((i + 5)) s)"
        exit 0
    fi
    sleep 1
done
echo "Lyrion nije odgovorio u 120 s" >&2
exit 1
