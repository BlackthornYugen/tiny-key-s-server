#!/usr/bin/env bash
# Test script: verifies EC key generation with seed bytes (integer and hex) inside an ephemeral docker container
set -euo pipefail

echo "=== Running test_seed_keys inside ephemeral docker container ==="

docker run --rm alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash >/dev/null 2>&1

echo "[1] Testing integer seed: 42"
INT_SEED="42"
# Generate binary seed from integer
printf "%08x" "$INT_SEED" | xxd -r -p > /tmp/seed_int.bin
# Pad/expand seed with SHA-256 for OpenSSL entropy buffer
openssl dgst -sha256 -binary /tmp/seed_int.bin > /tmp/seed_int_padded.bin

openssl ecparam -name prime256v1 -genkey -noout -rand /tmp/seed_int_padded.bin -out /tmp/key_ca_int.pem
openssl ecparam -name prime256v1 -genkey -noout -rand /tmp/seed_int_padded.bin -out /tmp/key_srv_int.pem
echo "Successfully generated EC keys with integer seed 42"
openssl ec -in /tmp/key_ca_int.pem -noout -text | head -n 4

echo "[2] Testing hex string seed: deadbeef0102030405060708"
HEX_SEED="deadbeef0102030405060708"
HEX_CLEAN=$(echo "$HEX_SEED" | sed "s/^0x//i")
if [ $(( ${#HEX_CLEAN} % 2 )) -ne 0 ]; then
    HEX_CLEAN="0${HEX_CLEAN}"
fi
echo "$HEX_CLEAN" | xxd -r -p > /tmp/seed_hex.bin
openssl dgst -sha256 -binary /tmp/seed_hex.bin > /tmp/seed_hex_padded.bin

openssl ecparam -name prime256v1 -genkey -noout -rand /tmp/seed_hex_padded.bin -out /tmp/key_ca_hex.pem
openssl ecparam -name prime256v1 -genkey -noout -rand /tmp/seed_hex_padded.bin -out /tmp/key_srv_hex.pem
echo "Successfully generated EC keys with hex seed $HEX_SEED"
openssl ec -in /tmp/key_ca_hex.pem -noout -text | head -n 4

echo "=== test_seed_keys PASSED ==="
'
