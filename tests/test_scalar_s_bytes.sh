#!/usr/bin/env bash
# Test script: verifies generating two EC keys with exact scalar "s" bytes,
# ensuring openssl ec -text shows the exact hex as the private key and chain verifies.
set -euo pipefail

echo "=== Running test_scalar_s_bytes in ephemeral docker container ==="

docker run --rm alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash >/dev/null 2>&1

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Helper function to get curve byte length
get_curve_bytes() {
    local curve="$1"
    case "$curve" in
        prime256v1|secp256r1|P-256) echo 32 ;;
        secp384r1|P-384) echo 48 ;;
        secp521r1|P-521) echo 66 ;;
        *) echo 32 ;;
    esac
}

# Helper to normalize int or hex string into zero-padded hex scalar
format_scalar() {
    local input="$1"
    local target_bytes="$2"
    local target_chars=$((target_bytes * 2))
    
    # Strip leading 0x or 0X
    local clean="${input#0x}"
    clean="${clean#0X}"
    
    # Check if purely decimal integer
    if [[ "$input" =~ ^[0-9]+$ ]] && [ ${#input} -lt 16 ]; then
        clean=$(printf "%x" "$input")
    fi
    
    # Pad with leading zeros to target_chars
    while [ ${#clean} -lt $target_chars ]; do
        clean="00$clean"
    done
    if [ ${#clean} -gt $target_chars ]; then
        clean="${clean: -$target_chars}"
    fi
    echo "$clean"
}

# Function to generate EC key from scalar
generate_ec_key_from_scalar() {
    local curve="$1"
    local hex_scalar="$2"
    local out_pem="$3"
    
    cat > gen_asn1.cnf <<EOF
asn1 = SEQUENCE:ec_key

[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$hex_scalar
params = EXPLICIT:0,OBJECT:$curve
EOF

    openssl asn1parse -genconf gen_asn1.cnf -out key_raw.der 2>/dev/null
    echo "-----BEGIN EC PRIVATE KEY-----" > "$out_pem"
    openssl base64 -in key_raw.der >> "$out_pem"
    echo "-----END EC PRIVATE KEY-----" >> "$out_pem"
    rm -f gen_asn1.cnf key_raw.der
}

USER_INPUT="deadbeef"
CURVE="prime256v1"
BYTE_LEN=$(get_curve_bytes "$CURVE")
SRV_SCALAR=$(format_scalar "$USER_INPUT" "$BYTE_LEN")
CA_SCALAR=$(format_scalar "deadbeee" "$BYTE_LEN")

echo "Generating Server EC key with scalar $SRV_SCALAR..."
generate_ec_key_from_scalar "$CURVE" "$SRV_SCALAR" server.key.pem

echo "Generating CA EC key with scalar $CA_SCALAR..."
generate_ec_key_from_scalar "$CURVE" "$CA_SCALAR" ca.key.pem

echo "--- Checking openssl ec -in server.key.pem -text -noout ---"
openssl ec -in server.key.pem -text -noout > server_ec.txt
cat server_ec.txt

if tr -d " \n:" < server_ec.txt | grep -qi "deadbeef"; then
    echo "SUCCESS: openssl ec -text shows exact user hex deadbeef as private key!"
else
    echo "ERROR: deadbeef not found in openssl ec -text!"
    exit 1
fi

echo "--- Building and verifying certificate chain ---"
openssl req -new -x509 -key ca.key.pem -out ca.crt.pem -days 365 -subj "/CN=Test CA" -addext "basicConstraints=critical,CA:TRUE"
openssl req -new -key server.key.pem -out server.csr.pem -subj "/CN=localhost"
openssl x509 -req -in server.csr.pem -CA ca.crt.pem -CAkey ca.key.pem -CAcreateserial -out server.crt.pem -days 365
cat server.crt.pem ca.crt.pem > fullchain.pem

openssl verify -CAfile ca.crt.pem server.crt.pem
openssl verify -CAfile ca.crt.pem fullchain.pem

echo "=== test_scalar_s_bytes PASSED ==="
'
