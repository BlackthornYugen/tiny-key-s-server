#!/usr/bin/env bash
# Test script: verifies cross-signed and multi-path certificate chains (a -> b -> c1, c2)
set -euo pipefail

echo "=== Running test_cross_signed_chains in ephemeral docker container ==="

docker run --rm alpine:latest sh -c '
set -euo pipefail
apk add --no-cache openssl xxd bash >/dev/null 2>&1

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Helper for scalar generation
get_curve_bytes() { echo 32; }
format_scalar() {
    local clean="${1#0x}"
    clean="${clean#0X}"
    while [ ${#clean} -lt 64 ]; do clean="00$clean"; done
    echo "${clean: -64}"
}
gen_key() {
    local scalar="$1"
    local out="$2"
    cat > /tmp/asn.cnf <<EOF
asn1 = SEQUENCE:ec_key
[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$scalar
params = EXPLICIT:0,OBJECT:prime256v1
EOF
    openssl asn1parse -genconf /tmp/asn.cnf -out /tmp/k.der 2>/dev/null
    echo "-----BEGIN EC PRIVATE KEY-----" > "$out"
    openssl base64 -in /tmp/k.der >> "$out"
    echo "-----END EC PRIVATE KEY-----" >> "$out"
    rm -f /tmp/asn.cnf /tmp/k.der
}

echo "1. Generating Keys: a (server: 0x01), b (intermediate: 0x02), c1 (root1: 0x10), c2 (root2: 0x20)..."
gen_key $(format_scalar "01") key_a.pem
gen_key $(format_scalar "02") key_b.pem
gen_key $(format_scalar "10") key_c1.pem
gen_key $(format_scalar "20") key_c2.pem

echo "2. Creating Root CAs: c1 and c2..."
openssl req -new -x509 -key key_c1.pem -out c1.crt.pem -days 3650 -subj "/CN=Root CA 1/O=Trust Corp/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -x509 -key key_c2.pem -out c2.crt.pem -days 3650 -subj "/CN=Root CA 2/O=Alternate Trust/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

echo "3. Creating Intermediate b signed by c1 (b_c1) and signed by c2 (b_c2)..."
openssl req -new -key key_b.pem -out b.csr.pem -subj "/CN=Intermediate B/O=Test Lab/C=CA"

cat > ca_ext.cnf <<EOF
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

openssl x509 -req -in b.csr.pem -CA c1.crt.pem -CAkey key_c1.pem -CAcreateserial -out b_c1.crt.pem -days 1825 -extfile ca_ext.cnf
openssl x509 -req -in b.csr.pem -CA c2.crt.pem -CAkey key_c2.pem -CAcreateserial -out b_c2.crt.pem -days 1825 -extfile ca_ext.cnf

# Also self-signed b (for default standard path)
openssl req -new -x509 -key key_b.pem -out b_self.crt.pem -days 1825 -subj "/CN=Intermediate B/O=Test Lab/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

echo "4. Creating Server a signed by Intermediate b..."
openssl req -new -key key_a.pem -out a.csr.pem -subj "/CN=localhost/O=Test Lab/C=CA"
cat > srv_ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
EOF
openssl x509 -req -in a.csr.pem -CA b_c1.crt.pem -CAkey key_b.pem -CAcreateserial -out a.crt.pem -days 365 -extfile srv_ext.cnf

echo "5. Testing Path 1: a -> b_c1 -> c1..."
cat a.crt.pem b_c1.crt.pem > chain_path1.pem
openssl verify -CAfile c1.crt.pem -untrusted chain_path1.pem a.crt.pem
echo "Path 1 verified successfully!"

openssl s_server -cert a.crt.pem -cert_chain chain_path1.pem -key key_a.pem -accept 18441 -www >/dev/null 2>&1 &
PID1=$!
sleep 1
openssl s_client -connect 127.0.0.1:18441 -CAfile c1.crt.pem -servername localhost </dev/null 2>&1 | grep "Verification: OK"
kill $PID1 2>/dev/null || true
echo "Path 1 s_server TLS handshake verified!"

echo "6. Testing Path 2: a -> b_c2 -> c2..."
cat a.crt.pem b_c2.crt.pem > chain_path2.pem
openssl verify -CAfile c2.crt.pem -untrusted chain_path2.pem a.crt.pem
echo "Path 2 verified successfully!"

openssl s_server -cert a.crt.pem -cert_chain chain_path2.pem -key key_a.pem -accept 18442 -www >/dev/null 2>&1 &
PID2=$!
sleep 1
openssl s_client -connect 127.0.0.1:18442 -CAfile c2.crt.pem -servername localhost </dev/null 2>&1 | grep "Verification: OK"
kill $PID2 2>/dev/null || true
echo "Path 2 s_server TLS handshake verified!"

echo "7. Testing All Paths Combined: a -> b_c1 + b_c2..."
cat a.crt.pem b_c1.crt.pem b_c2.crt.pem > chain_all.pem
openssl s_server -cert a.crt.pem -cert_chain chain_all.pem -key key_a.pem -accept 18443 -www >/dev/null 2>&1 &
PID3=$!
sleep 1
openssl s_client -connect 127.0.0.1:18443 -CAfile c1.crt.pem -servername localhost </dev/null 2>&1 | grep "Verification: OK"
kill $PID3 2>/dev/null || true
echo "Combined multi-path chain served successfully!"

echo "=== test_cross_signed_chains PASSED ==="
'
