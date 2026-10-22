#!/usr/bin/env bash
# End-to-end test script: builds the Docker image and tests it in ephemeral containers
set -euo pipefail

echo "=== Building ephemeral Docker image s-server-tester:test ==="
docker build -t s-server-tester:test .

echo "=== Test 1: Run with integer seed 42 in -WWW mode ==="
CONTAINER_ID=$(docker run -d \
    -p 4433:4433 \
    -e SEED="42" \
    -e DOMAINS="test1.local,s-server.internal" \
    -e IPS="127.0.0.1,10.1.2.3" \
    s-server-tester:test)

cleanup_container() {
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

sleep 2
echo "Checking container logs:"
docker logs "$CONTAINER_ID" | head -n 25

echo "Testing curl /index.html..."
RESP=$(curl -k -s https://127.0.0.1:4433/index.html)

if echo "$RESP" | grep -q "OpenSSL s_server Testing Report"; then
    echo "SUCCESS: Found OpenSSL s_server Testing Report in index.html"
else
    echo "ERROR: Missing expected report title in response"
    exit 1
fi

if echo "$RESP" | grep -q "openssl ecparam"; then
    echo "SUCCESS: Found executed openssl ecparam commands in HTML"
else
    echo "ERROR: Missing openssl ecparam command in HTML"
    exit 1
fi

if echo "$RESP" | grep -q "test1.local"; then
    echo "SUCCESS: Found SAN domain test1.local in HTML report"
else
    echo "ERROR: Missing SAN domain in HTML"
    exit 1
fi

echo "Testing curl /fullchain.pem download..."
CHAIN_RESP=$(curl -k -s https://127.0.0.1:4433/fullchain.pem)
if echo "$CHAIN_RESP" | grep -q "BEGIN CERTIFICATE"; then
    echo "SUCCESS: Downloaded valid fullchain.pem over s_server"
else
    echo "ERROR: Failed to download fullchain.pem"
    exit 1
fi

cleanup_container
trap - EXIT

echo "=== Test 2: Run with hex string seed and custom curves in -WWW mode ==="
CONTAINER_ID=$(docker run -d \
    -p 4434:4433 \
    -e SEED_BYTES="0xabcdef0123456789" \
    -e CA_CURVE="secp384r1" \
    -e SERVER_CURVE="prime256v1" \
    -e WWW_MODE="WWW" \
    s-server-tester:test)

trap cleanup_container EXIT
sleep 2

RESP=$(curl -k -s https://127.0.0.1:4434/index.html)
if echo "$RESP" | grep -q "secp384r1"; then
    echo "SUCCESS: Found custom curve secp384r1 in HTML report"
else
    echo "ERROR: Missing custom curve in HTML report"
    exit 1
fi

cleanup_container
trap - EXIT

echo "=== Test 3: Run with mounted volume containing custom fullchain ==="
MNT_DIR=$(mktemp -d)
openssl ecparam -name prime256v1 -genkey -noout -out "$MNT_DIR/server.key"
openssl req -new -x509 -key "$MNT_DIR/server.key" -out "$MNT_DIR/fullchain.pem" -days 30 -subj "/CN=volume-test.domain"

CONTAINER_ID=$(docker run -d \
    -p 4435:4433 \
    -v "$MNT_DIR:/certs:ro" \
    s-server-tester:test)

trap 'cleanup_container; rm -rf "$MNT_DIR"' EXIT
sleep 2

docker logs "$CONTAINER_ID" | grep -E "Found mounted certificate|fullchain.pem"
RESP=$(curl -k -s https://127.0.0.1:4435/index.html)
if echo "$RESP" | grep -q "volume-test.domain"; then
    echo "SUCCESS: Mounted certificate volume-test.domain served correctly!"
else
    echo "ERROR: Missing mounted subject in HTML report"
    exit 1
fi

cleanup_container
rm -rf "$MNT_DIR"
trap - EXIT

echo "=== ALL DOCKER INTEGRATION TESTS PASSED SUCCESSFULLY! ==="
