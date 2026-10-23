#!/usr/bin/env bash
# Test script: validates CHAIN_MODE (default, single path, all) and root auto-signing
set -euo pipefail

echo "=== Running test_chain_modes in ephemeral docker container ==="

docker run --rm -v "$(pwd)/entrypoint.sh:/entrypoint.sh:ro" alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash curl >/dev/null 2>&1

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "1. Testing Default CHAIN_MODE (a -> b)..."
SERVE_DIR="$WORKDIR/serve_default"
export SERVE_DIR
export S_BYTES="0x01"
export CA_S_BYTES="0x02"
export CHAIN_MODE="default"
export PORT="18451"

bash /entrypoint.sh </dev/null >/tmp/server_default.log 2>&1 &
PID1=$!
sleep 2

# Verify TLS connection with default CA
openssl s_client -connect 127.0.0.1:18451 -CAfile "$SERVE_DIR/ca.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
kill $PID1 2>/dev/null || true
echo "Default mode verified!"

echo "2. Testing Root Auto-Signing & Named Path (CHAIN_MODE=c1)..."
ROOTS_DIR="$WORKDIR/roots"
mkdir -p "$ROOTS_DIR"
openssl ecparam -name prime256v1 -genkey -noout -out "$ROOTS_DIR/c1.key"
openssl req -new -x509 -key "$ROOTS_DIR/c1.key" -out "$ROOTS_DIR/c1.crt" -days 3650 -subj "/CN=Root C1/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl ecparam -name prime256v1 -genkey -noout -out "$ROOTS_DIR/c2.key"
openssl req -new -x509 -key "$ROOTS_DIR/c2.key" -out "$ROOTS_DIR/c2.crt" -days 3650 -subj "/CN=Root C2/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

SERVE_DIR="$WORKDIR/serve_c1"
export SERVE_DIR
export ROOTS_DIR
export CHAIN_MODE="c1"
export PORT="18452"

bash /entrypoint.sh </dev/null >/tmp/server_c1.log 2>&1 &
PID2=$!
sleep 2

# Verify client trusting Root C1 succeeds
openssl s_client -connect 127.0.0.1:18452 -CAfile "$ROOTS_DIR/c1.crt" </dev/null 2>&1 | grep "Verification: OK"
kill $PID2 2>/dev/null || true
echo "Named path c1 verified!"

echo "3. Testing All Paths (CHAIN_MODE=all)..."
SERVE_DIR="$WORKDIR/serve_all"
export SERVE_DIR
export CHAIN_MODE="all"
export PORT="18453"

bash /entrypoint.sh </dev/null >/tmp/server_all.log 2>&1 &
PID3=$!
sleep 2

# Verify client can connect
openssl s_client -connect 127.0.0.1:18453 -CAfile "$ROOTS_DIR/c1.crt" </dev/null 2>&1 | grep "Verification: OK"
kill $PID3 2>/dev/null || true
echo "All paths mode verified!"

echo "=== test_chain_modes PASSED ==="
'
