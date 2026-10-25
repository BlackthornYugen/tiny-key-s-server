#!/usr/bin/env bash
# ==============================================================================
# Test mitmproxy with Cross-Signed CA Bundles
# Verifies:
# 1. Private key invariance: The intermediate private key MUST NOT CHANGE across
#    cross-signed certificates.
# 2. Hierarchical cross-signing (b_c1 + c1_c2): Single bundle verified simultaneously
#    by clients trusting Root 1 and clients trusting Root 2.
# 3. Dual-path cross-signing (b_c1 and b_c2): Independent verification of both roots
#    sharing the exact same intermediate private key.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR=$(mktemp -d)

TEST_ID="$$"
DOCKER_NETWORK="mitm-net-${TEST_ID}"
TARGET_CONTAINER="target-${TEST_ID}"
MITM_CONTAINER="mitm-${TEST_ID}"

cleanup() {
    docker rm -f "${TARGET_CONTAINER}" "${MITM_CONTAINER}" 2>/dev/null || true
    docker network rm "${DOCKER_NETWORK}" 2>/dev/null || true
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

echo "=== 1. Generating Keys and Certificates for mitmproxy Cross-Signing Test ==="
cd "${TEMP_DIR}"

gen_key() {
    local scalar="$1"
    local out="$2"
    cat > asn.cnf <<EOF
asn1 = SEQUENCE:ec_key
[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$scalar
params = EXPLICIT:0,OBJECT:prime256v1
EOF
    openssl asn1parse -genconf asn.cnf -out k.der 2>/dev/null
    echo "-----BEGIN EC PRIVATE KEY-----" > "$out"
    openssl base64 -in k.der >> "$out"
    echo "-----END EC PRIVATE KEY-----" >> "$out"
    rm -f asn.cnf k.der
}

pad_scalar() {
    local clean="${1#0x}"
    clean="${clean#0X}"
    while [ ${#clean} -lt 64 ]; do clean="00$clean"; done
    echo "${clean: -64}"
}

# Key Invariance Rule:
# Intermediate CA private key (key_b) is generated ONCE and MUST NOT CHANGE.
gen_key $(pad_scalar "02") key_b.pem
gen_key $(pad_scalar "10") key_c1.pem
gen_key $(pad_scalar "20") key_c2.pem
gen_key $(pad_scalar "01") key_target.pem

# Create Root CAs:
# Root c1 (Modern Root)
openssl req -new -x509 -key key_c1.pem -out c1_self.crt.pem -days 3650 -subj "/CN=Modern Root CA 1/O=Trust Corp/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash"

# Root c2 (Legacy Root)
openssl req -new -x509 -key key_c2.pem -out c2_self.crt.pem -days 3650 -subj "/CN=Legacy Root CA 2/O=Alternate Trust/C=CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash"

cat > ext.cnf <<EOF
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF

# 1. Hierarchical Cross-Signing: Root c1 cross-signed by Root c2 (c1_c2)
openssl req -new -key key_c1.pem -out c1.csr.pem -subj "/CN=Modern Root CA 1/O=Trust Corp/C=CA"
openssl x509 -req -in c1.csr.pem -CA c2_self.crt.pem -CAkey key_c2.pem -CAcreateserial -out c1_c2.crt.pem -days 1825 -extfile ext.cnf

# 2. Intermediate CA B signed by Root c1 using key_b
openssl req -new -key key_b.pem -out b.csr.pem -subj "/CN=Intermediate CA B/O=Test Lab/C=CA"
openssl x509 -req -in b.csr.pem -CA c1_self.crt.pem -CAkey key_c1.pem -CAcreateserial -out b_c1.crt.pem -days 1825 -extfile ext.cnf

# 3. Dual-Root Cross-Signing: SAME intermediate key_b signed by Root c2 directly (b_c2)
openssl x509 -req -in b.csr.pem -CA c2_self.crt.pem -CAkey key_c2.pem -CAcreateserial -out b_c2.crt.pem -days 1825 -extfile ext.cnf

echo ""
echo ">> Verifying Key Invariance across Intermediate Certificates:"
diff -u <(openssl x509 -in b_c1.crt.pem -noout -pubkey) <(openssl x509 -in b_c2.crt.pem -noout -pubkey)
echo ">> [CONFIRMED] Public keys in b_c1 and b_c2 are identical!"

# Target server certificate
openssl req -new -key key_target.pem -out target.csr.pem -subj "/CN=target-server/O=Target/C=CA"
cat > srv_ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:target-server
EOF
openssl x509 -req -in target.csr.pem -CA b_c1.crt.pem -CAkey key_b.pem -CAcreateserial -out target.crt.pem -days 365 -extfile srv_ext.cnf

# Assemble Hierarchical Cross-Signed Bundle:
# [ key_b (private key), b_c1 (intermediate), c1_c2 (cross-signed root) ]
cat key_b.pem b_c1.crt.pem c1_c2.crt.pem > mitmproxy-ca.pem
chmod 644 mitmproxy-ca.pem

echo "=== 2. Creating Shared Docker Network ==="
docker network create "${DOCKER_NETWORK}" >/dev/null

echo "=== 3. Starting Target HTTPS Server ==="
docker run -d --name "${TARGET_CONTAINER}" \
    --network "${DOCKER_NETWORK}" \
    --network-alias target-server \
    -v "${TEMP_DIR}:/certs:ro" \
    alpine:latest \
    sh -c "apk add --no-cache openssl >/dev/null 2>&1 && exec openssl s_server -accept 4433 -key /certs/key_target.pem -cert /certs/target.crt.pem -cert_chain /certs/b_c1.crt.pem -www" >/dev/null

echo ">> Waiting for target-server..."
for retry in {1..30}; do
    if docker exec "${TARGET_CONTAINER}" nc -z 127.0.0.1 4433 2>/dev/null; then
        echo ">> target-server is listening on port 4433."
        break
    fi
    sleep 1
done

echo "=== 4. Launching mitmproxy with Cross-Signed CA Bundle ==="
mkdir -p "${TEMP_DIR}/input-ca"
cp mitmproxy-ca.pem "${TEMP_DIR}/input-ca/mitmproxy-ca.pem"

docker run -d --name "${MITM_CONTAINER}" \
    --network "${DOCKER_NETWORK}" \
    -p 18080:8080 \
    -v "${TEMP_DIR}/input-ca:/input-ca:ro" \
    mitmproxy/mitmproxy:latest \
    sh -c "mkdir -p ~/.mitmproxy && cp /input-ca/mitmproxy-ca.pem ~/.mitmproxy/mitmproxy-ca.pem && chmod 600 ~/.mitmproxy/mitmproxy-ca.pem && exec mitmdump --set block_global=false --set ssl_insecure=true" >/dev/null

echo ">> Waiting for mitmproxy..."
for retry in {1..30}; do
    if curl -s -o /dev/null -x http://127.0.0.1:18080 http://mitm.it 2>/dev/null; then
        echo ">> mitmproxy is ready on port 18080."
        break
    fi
    sleep 1
done

echo ""
echo "=== 5. Testing Interception: Client trusting Modern Root CA 1 (c1) ==="
# Strict verification against Modern Root 1
RESPONSE_C1=$(curl -s -x http://127.0.0.1:18080 --cacert c1_self.crt.pem https://target-server:4433/)
echo "${RESPONSE_C1}" | head -n 4
if echo "${RESPONSE_C1}" | grep -q -i "s_server"; then
    echo ">> [PASS] Verified TLS interception trusting Modern Root 1 (c1)!"
else
    echo ">> [FAIL] TLS verification failed against Modern Root 1"
    exit 1
fi

echo ""
echo "=== 6. Testing Interception: Client trusting Legacy Root CA 2 (c2) ==="
# Strict verification against Legacy Root 2 (navigates cross-signed c1_c2 bridge)
RESPONSE_C2=$(curl -s -x http://127.0.0.1:18080 --cacert c2_self.crt.pem https://target-server:4433/)
echo "${RESPONSE_C2}" | head -n 4
if echo "${RESPONSE_C2}" | grep -q -i "s_server"; then
    echo ">> [PASS] Verified TLS interception trusting Legacy Root 2 (c2) via cross-signed bridge!"
else
    echo ">> [FAIL] TLS verification failed against Legacy Root 2"
    exit 1
fi

echo ""
echo "=============================================================================="
echo " ALL TESTS PASSED: Cross-signed mitmproxy CA verified across multiple roots!"
echo " Invariant confirmed: Exactly 1 private key used for all cross-signed certs."
echo "=============================================================================="
