#!/usr/bin/env bash
# Test script: verifies CA and Server cert generation, SANs, chain creation, and chain verification
set -euo pipefail

echo "=== Running test_chain_generation inside ephemeral docker container ==="

docker run --rm alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash >/dev/null 2>&1

WORKDIR="/tmp/test_pki"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# Settings
CA_CURVE="prime256v1"
SERVER_CURVE="prime256v1"
CA_SUBJECT="/CN=Test Root CA/O=My Test Org/C=US"
SERVER_SUBJECT="/CN=test.example.com/O=My Test Org/C=US"
DOMAINS="test.example.com,localhost,s-server.local"
IPS="127.0.0.1,10.0.0.1"
SEED="1337"

echo "1. Generating seed..."
printf "%08x" "$SEED" | xxd -r -p > seed.bin
openssl dgst -sha256 -binary seed.bin > seed_padded.bin

echo "2. Generating CA key and cert..."
openssl ecparam -name "$CA_CURVE" -genkey -noout -rand seed_padded.bin -out ca.key.pem
openssl req -new -x509 -key ca.key.pem -out ca.crt.pem -days 365 \
    -subj "$CA_SUBJECT" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

echo "3. Generating Server key and CSR..."
openssl ecparam -name "$SERVER_CURVE" -genkey -noout -rand seed_padded.bin -out server.key.pem
openssl req -new -key server.key.pem -out server.csr.pem -subj "$SERVER_SUBJECT"

echo "4. Building SAN extension file..."
cat > ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = test.example.com
DNS.2 = localhost
DNS.3 = s-server.local
IP.1 = 127.0.0.1
IP.2 = 10.0.0.1
EOF

echo "5. Signing Server certificate with CA..."
openssl x509 -req -in server.csr.pem -CA ca.crt.pem -CAkey ca.key.pem -CAcreateserial \
    -out server.crt.pem -days 365 -extfile ext.cnf

echo "6. Creating full chain..."
cat server.crt.pem ca.crt.pem > fullchain.pem

echo "7. Verifying certificate chain..."
openssl verify -CAfile ca.crt.pem server.crt.pem
openssl verify -CAfile ca.crt.pem fullchain.pem

echo "8. Checking SAN entries in server cert..."
openssl x509 -in server.crt.pem -noout -text | grep -A 2 "Subject Alternative Name"

echo "=== test_chain_generation PASSED ==="
'
