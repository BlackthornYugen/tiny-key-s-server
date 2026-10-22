#!/usr/bin/env bash
# Test script: verifies openssl s_server running in -WWW and -www mode inside an ephemeral docker container
set -euo pipefail

echo "=== Running test_s_server_behavior inside ephemeral docker container ==="

docker run --rm alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl curl bash >/dev/null 2>&1

WORKDIR="/tmp/s_server_test"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# 1. Generate keys and certs
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -new -x509 -key ca.key -out ca.crt -days 1 -subj "/CN=Test CA" -addext "basicConstraints=critical,CA:TRUE"
openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 1
cat server.crt ca.crt > fullchain.pem

# 2. Create custom index.html
echo "<html><body><h1>OpenSSL s_server custom page</h1></body></html>" > index.html

echo "--- Test 1: Testing s_server with -WWW ---"
openssl s_server -accept 8443 -key server.key -cert server.crt -CAfile ca.crt -WWW >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

# Test curl requesting /index.html
INDEX_RESP=$(curl -k -s https://127.0.0.1:8443/index.html || true)
echo "Fetched /index.html with length: ${#INDEX_RESP}"
if echo "$INDEX_RESP" | grep -q "OpenSSL s_server custom page"; then
    echo "SUCCESS: -WWW served custom index.html correctly!"
else
    echo "ERROR: Unexpected response: $INDEX_RESP"
    exit 1
fi

# Test curl requesting /
ROOT_RESP=$(curl -k -s https://127.0.0.1:8443/ || true)
echo "Fetched / with length: ${#ROOT_RESP}"

kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true
sleep 1

echo "--- Test 2: Testing s_server with -www ---"
openssl s_server -accept 8443 -key server.key -cert server.crt -CAfile ca.crt -www >/dev/null 2>&1 &
SERVER_PID=$!
sleep 1

WWW_RESP=$(curl -k -s https://127.0.0.1:8443/ || true)
echo "Fetched / with length: ${#WWW_RESP}"
if echo "$WWW_RESP" | grep -qi "cipher"; then
    echo "SUCCESS: -www served built-in status page!"
else
    echo "ERROR: -www did not return expected status page"
    exit 1
fi

kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo "=== test_s_server_behavior PASSED ==="
'
