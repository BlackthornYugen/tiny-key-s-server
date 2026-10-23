#!/usr/bin/env bash
# Test script: verifies single-process container isolation per chain mode
set -euo pipefail

echo "=== Running test_multi_port_server (isolated single-process per container) in ephemeral docker ==="

docker run --rm -v "$(pwd)/entrypoint.sh:/entrypoint.sh:ro" alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash curl >/dev/null 2>&1

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "1. Testing Container dedicated to Chain c1..."
SERVE_DIR="$WORKDIR/serve_c1"
export SERVE_DIR
export S_BYTES="0x01"
export CA_S_BYTES="0x02"
export ROOTS="c1,c2"
export ROOT_S_BYTES="0x10,0x20"
export CHAIN_MODE="c1"
export PORT="18481"

bash /entrypoint.sh </dev/null >/tmp/server_c1.log 2>&1 &
PID1=$!
sleep 2

# Verify TLS handshake with Root c1
openssl s_client -connect 127.0.0.1:18481 -CAfile "$SERVE_DIR/roots/c1.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Chain c1 container verified OK!"

# Verify exactly ONE openssl process is running for this container
PROC_COUNT=$(pgrep openssl | wc -l)
if [ "$PROC_COUNT" -ne 1 ]; then
    echo "ERROR: Expected exactly 1 openssl process, found $PROC_COUNT"
    exit 1
fi
echo "Verified exactly 1 process running in container (no background companion processes)!"

kill $PID1 2>/dev/null || true
sleep 1

echo "2. Testing Container dedicated to Chain c2..."
SERVE_DIR="$WORKDIR/serve_c2"
export SERVE_DIR
export CHAIN_MODE="c2"
export PORT="18482"

bash /entrypoint.sh </dev/null >/tmp/server_c2.log 2>&1 &
PID2=$!
sleep 2

openssl s_client -connect 127.0.0.1:18482 -CAfile "$SERVE_DIR/roots/c2.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Chain c2 container verified OK!"
kill $PID2 2>/dev/null || true
sleep 1

echo "3. Testing Container dedicated to Chain all..."
SERVE_DIR="$WORKDIR/serve_all"
export SERVE_DIR
export CHAIN_MODE="all"
export PORT="18483"

bash /entrypoint.sh </dev/null >/tmp/server_all.log 2>&1 &
PID3=$!
sleep 2

openssl s_client -connect 127.0.0.1:18483 -CAfile "$SERVE_DIR/roots/c1.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Chain all container verified OK!"
kill $PID3 2>/dev/null || true

echo "=== test_multi_port_server PASSED ==="
'
