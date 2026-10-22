#!/usr/bin/env bash
# Test script: verifies volume mounting to override certificate generation with an existing fullchain PEM
set -euo pipefail

echo "=== Running test_volume_override inside ephemeral docker container ==="

# Create a temporary host directory to act as a mounted volume
MNT_DIR=$(mktemp -d)
trap 'rm -rf "$MNT_DIR"' EXIT

# Generate a pre-existing custom cert & key in the host temp dir
openssl ecparam -name secp384r1 -genkey -noout -out "$MNT_DIR/custom.key"
openssl req -new -x509 -key "$MNT_DIR/custom.key" -out "$MNT_DIR/fullchain.pem" -days 30 -subj "/CN=mounted.custom.host"

docker run --rm \
    -v "$MNT_DIR:/certs:ro" \
    alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl bash >/dev/null 2>&1

echo "Checking /certs in container..."
if [ -f "/certs/fullchain.pem" ]; then
    echo "Found /certs/fullchain.pem!"
    SUBJ=$(openssl x509 -in /certs/fullchain.pem -noout -subject)
    echo "Subject: $SUBJ"
    if echo "$SUBJ" | grep -q "mounted.custom.host"; then
        echo "SUCCESS: Mounted certificate recognized successfully!"
    else
        echo "ERROR: Unexpected subject $SUBJ"
        exit 1
    fi
else
    echo "ERROR: /certs/fullchain.pem not found!"
    exit 1
fi
'

echo "=== test_volume_override PASSED ==="
