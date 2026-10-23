#!/usr/bin/env bash
# Test script: verifies multi-root auto-generation and companion multi-port listeners
set -euo pipefail

echo "=== Running test_multi_port_server in ephemeral docker container ==="

docker run --rm -v "$(pwd)/entrypoint.sh:/entrypoint.sh:ro" alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash curl >/dev/null 2>&1

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo "1. Testing Dual Roots (ROOTS=c1,c2)..."
SERVE_DIR="$WORKDIR/serve_dual"
export SERVE_DIR
export S_BYTES="0x01"
export CA_S_BYTES="0x02"
export ROOTS="c1,c2"
export ROOT_S_BYTES="0x10,0x20"
export PORT="18460"

bash /entrypoint.sh </dev/null >/tmp/server_dual.log 2>&1 &
PID1=$!
sleep 3

# Check primary port (18460)
echo "Testing Primary Port (18460)..."
curl -k -s https://127.0.0.1:18460/index.html | grep -q "OpenSSL s_server Testing Report"
echo "Primary port serving index.html correctly!"

# Check that HTML report lists the companion ports
curl -k -s https://127.0.0.1:18460/index.html | grep -q "Port 4434: Chain .c1."
curl -k -s https://127.0.0.1:18460/index.html | grep -q "Port 4435: Chain .c2."
curl -k -s https://127.0.0.1:18460/index.html | grep -q "Port 4436: Combined Chain .all."
echo "HTML report contains all companion port definitions!"

# Verify TLS connection to Port 4434 (c1) with Root c1
echo "Verifying Port 4434 (c1) TLS handshake..."
openssl s_client -connect 127.0.0.1:4434 -CAfile "$SERVE_DIR/roots/c1.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Port 4434 (c1) verified OK with Root c1!"

# Verify TLS connection to Port 4435 (c2) with Root c2
echo "Verifying Port 4435 (c2) TLS handshake..."
openssl s_client -connect 127.0.0.1:4435 -CAfile "$SERVE_DIR/roots/c2.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Port 4435 (c2) verified OK with Root c2!"

# Verify TLS connection to Port 4436 (all)
echo "Verifying Port 4436 (all) TLS handshake..."
openssl s_client -connect 127.0.0.1:4436 -CAfile "$SERVE_DIR/roots/c1.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Port 4436 (all) verified OK!"

kill $PID1 2>/dev/null || true
sleep 1

echo "2. Testing Single Root (ROOTS=c1)..."
SERVE_DIR="$WORKDIR/serve_single"
export SERVE_DIR
export ROOTS="c1"
export ROOT_S_BYTES="0x10"
export PORT="18470"

bash /entrypoint.sh </dev/null >/tmp/server_single.log 2>&1 &
PID2=$!
sleep 3

# Verify single companion port 4434 (c1)
echo "Verifying Single Root Port 4434 (c1)..."
openssl s_client -connect 127.0.0.1:4434 -CAfile "$SERVE_DIR/roots/c1.crt.pem" </dev/null 2>&1 | grep "Verification: OK"
echo "Single root c1 verified OK!"

# Verify port 4435 is NOT open (since no all/c2)
if nc -z 127.0.0.1 4435 2>/dev/null; then
    echo "ERROR: Port 4435 should not be open for single chain!"
    exit 1
fi
echo "Verified port 4435 is not open (as expected for single chain)!"

kill $PID2 2>/dev/null || true

echo "=== test_multi_port_server PASSED ==="
'
