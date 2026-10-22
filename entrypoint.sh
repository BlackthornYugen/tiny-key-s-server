#!/usr/bin/env bash
# ==============================================================================
# OpenSSL s_server Testing Tool Entrypoint
# ==============================================================================
set -euo pipefail

# Directory where certs, keys, and web files will be stored and served from
SERVE_DIR="${SERVE_DIR:-/srv/www}"
mkdir -p "$SERVE_DIR"
cd "$SERVE_DIR"

# ------------------------------------------------------------------------------
# Configuration & Defaults
# ------------------------------------------------------------------------------
PORT="${PORT:-${S_SERVER_PORT:-4433}}"
WWW_MODE="${WWW_MODE:-${SERVER_MODE:-WWW}}" # WWW, www, or HTTP

# Curves
DEFAULT_CURVE="${CURVE:-prime256v1}"
CA_CURVE="${CA_CURVE:-$DEFAULT_CURVE}"
SERVER_CURVE="${SERVER_CURVE:-$DEFAULT_CURVE}"

# Subjects
CA_SUBJECT="${CA_SUBJECT:-/CN=Test OpenSSL CA/O=Test Lab/C=US}"
SERVER_SUBJECT="${SERVER_SUBJECT:-/CN=localhost/O=Test Lab/C=US}"

# SANs (Domains and IPs)
DOMAINS="${DOMAINS:-${SAN_DOMAINS:-localhost}}"
IPS="${IPS:-${SAN_IPS:-127.0.0.1}}"

# Validity
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-365}"

# Optional mounted volume directory
CERTS_DIR="${CERTS_DIR:-/certs}"

# Extra s_server arguments
EXTRA_S_SERVER_ARGS="${EXTRA_S_SERVER_ARGS:-}"

# Scalar "s" bytes or seed input from CLI argument $1 or env vars
S_BYTES_INPUT="${1:-${S_BYTES:-${SERVER_S_BYTES:-${SEED_BYTES:-${SEED:-}}}}}"
CA_S_BYTES_INPUT="${CA_S_BYTES:-}"

# ------------------------------------------------------------------------------
# Helper Functions for EC Scalars ("s" bytes)
# ------------------------------------------------------------------------------
get_curve_bytes() {
    local curve="$1"
    case "$curve" in
        prime256v1|secp256r1|P-256) echo 32 ;;
        secp384r1|P-384) echo 48 ;;
        secp521r1|P-521) echo 66 ;;
        *) echo 32 ;;
    esac
}

format_scalar() {
    local input="$1"
    local target_bytes="$2"
    local target_chars=$((target_bytes * 2))
    
    local clean="${input#0x}"
    clean="${clean#0X}"
    
    if [[ "$input" =~ ^[0-9]+$ ]] && [ ${#input} -lt 16 ]; then
        clean=$(printf "%x" "$input")
    fi
    
    while [ ${#clean} -lt $target_chars ]; do
        clean="00$clean"
    done
    if [ ${#clean} -gt $target_chars ]; then
        clean="${clean: -$target_chars}"
    fi
    echo "$clean"
}

derive_partner_scalar() {
    local hex="$1"
    local prefix="${hex:0:${#hex}-2}"
    local last_byte="${hex: -2}"
    local last_int=$(( 16#$last_byte ))
    local next_int=$(( (last_int + 1) % 256 ))
    if [ $next_int -eq 0 ]; then
        next_int=1
    fi
    printf "%s%02x" "$prefix" "$next_int"
}

# ------------------------------------------------------------------------------
# Logging & Command Tracking
# ------------------------------------------------------------------------------
COMMAND_LOG_FILE="$SERVE_DIR/commands.log"
HTML_OUTPUT_FILE="$SERVE_DIR/index.html"
rm -f "$COMMAND_LOG_FILE"

declare -a RECORDED_COMMANDS=()
declare -a RECORDED_OUTPUTS=()
declare -a RECORDED_DESCS=()

run_recorded() {
    local desc="$1"
    shift
    local cmd="$*"
    
    echo ">> [STEP] $desc"
    echo "+ $cmd"
    echo "$cmd" >> "$COMMAND_LOG_FILE"
    
    local output
    output=$(eval "$cmd" 2>&1)
    local ret=$?
    
    RECORDED_DESCS+=("$desc")
    RECORDED_COMMANDS+=("$cmd")
    RECORDED_OUTPUTS+=("$output")
    
    if [ $ret -ne 0 ]; then
        echo "Command failed with return code $ret:"
        echo "$output"
        exit $ret
    fi
}

echo "==================================================================="
echo " Starting OpenSSL s_server Testing Tool"
echo "==================================================================="
echo "Port:             $PORT"
echo "Mode:             -$WWW_MODE"
echo "Serve Directory:  $SERVE_DIR"
echo "Volume Dir:       $CERTS_DIR"
echo "==================================================================="

# Default metadata
SEED_TYPE="Random (OS entropy)"
SEED_DISPLAY="Auto-generated random"

# ------------------------------------------------------------------------------
# Check for Mounted Volume Certificates
# ------------------------------------------------------------------------------
MOUNTED_CHAIN=""
MOUNTED_KEY=""

if [ -d "$CERTS_DIR" ]; then
    for candidate in "fullchain.pem" "tls.crt" "chain.pem" "cert.pem"; do
        if [ -f "$CERTS_DIR/$candidate" ]; then
            MOUNTED_CHAIN="$CERTS_DIR/$candidate"
            break
        fi
    done
    for candidate in "privkey.pem" "tls.key" "server.key" "key.pem"; do
        if [ -f "$CERTS_DIR/$candidate" ]; then
            MOUNTED_KEY="$CERTS_DIR/$candidate"
            break
        fi
    done
fi

USED_MOUNTED=false
if [ -n "$MOUNTED_CHAIN" ] && [ -n "$MOUNTED_KEY" ]; then
    USED_MOUNTED=true
    SEED_TYPE="Mounted Volume"
    SEED_DISPLAY="External volume ($MOUNTED_CHAIN)"
    echo ">> Found mounted certificate chain and key:"
    echo "   Chain: $MOUNTED_CHAIN"
    echo "   Key:   $MOUNTED_KEY"
    
    run_recorded "Copy mounted fullchain to serve directory" "cp '$MOUNTED_CHAIN' '$SERVE_DIR/fullchain.pem'"
    run_recorded "Copy mounted private key to serve directory" "cp '$MOUNTED_KEY' '$SERVE_DIR/server.key.pem'"
    run_recorded "Inspect mounted fullchain details" "openssl x509 -in '$SERVE_DIR/fullchain.pem' -noout -text"
    run_recorded "Verify certificate format" "openssl x509 -in '$SERVE_DIR/fullchain.pem' -noout -subject -issuer -dates"
else
    # --------------------------------------------------------------------------
    # Deterministic / Exact "s" Bytes EC Key Generation
    # --------------------------------------------------------------------------
    if [ -n "$S_BYTES_INPUT" ]; then
        SERVER_BYTES_LEN=$(get_curve_bytes "$SERVER_CURVE")
        CA_BYTES_LEN=$(get_curve_bytes "$CA_CURVE")
        
        SERVER_SCALAR=$(format_scalar "$S_BYTES_INPUT" "$SERVER_BYTES_LEN")
        if [ -n "$CA_S_BYTES_INPUT" ]; then
            CA_SCALAR=$(format_scalar "$CA_S_BYTES_INPUT" "$CA_BYTES_LEN")
        else
            CA_SCALAR=$(derive_partner_scalar "$SERVER_SCALAR")
        fi
        
        SEED_TYPE="Exact Scalar 's' Bytes"
        SEED_DISPLAY="Server s: 0x$SERVER_SCALAR (CA s: 0x$CA_SCALAR)"
        echo ">> Configured EC scalar 's' bytes:"
        echo "   Server Key scalar: 0x$SERVER_SCALAR"
        echo "   CA Key scalar:     0x$CA_SCALAR"
        
        # 1. Generate CA Private Key from scalar ASN.1
        CA_ASN1_CNF="$SERVE_DIR/asn1_ca.cnf"
        cat > "$CA_ASN1_CNF" <<EOF
asn1 = SEQUENCE:ec_key

[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$CA_SCALAR
params = EXPLICIT:0,OBJECT:$CA_CURVE
EOF
        run_recorded "Create CA EC Private Key ASN.1 Configuration" "cat '$CA_ASN1_CNF'"
        run_recorded "Encode CA EC Private Key DER from scalar ASN.1" "openssl asn1parse -genconf '$CA_ASN1_CNF' -out '$SERVE_DIR/ca_raw.der'"
        run_recorded "Package CA EC Private Key to PEM" "echo '-----BEGIN EC PRIVATE KEY-----' > '$SERVE_DIR/ca.key.pem' && openssl base64 -in '$SERVE_DIR/ca_raw.der' >> '$SERVE_DIR/ca.key.pem' && echo '-----END EC PRIVATE KEY-----' >> '$SERVE_DIR/ca.key.pem'"
        rm -f "$SERVE_DIR/ca_raw.der"
        run_recorded "Inspect CA EC Private Key (shows exact scalar hex in priv:)" "openssl ec -in '$SERVE_DIR/ca.key.pem' -text -noout"
        
        # 2. Generate Server Private Key from scalar ASN.1
        SERVER_ASN1_CNF="$SERVE_DIR/asn1_server.cnf"
        cat > "$SERVER_ASN1_CNF" <<EOF
asn1 = SEQUENCE:ec_key

[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$SERVER_SCALAR
params = EXPLICIT:0,OBJECT:$SERVER_CURVE
EOF
        run_recorded "Create Server EC Private Key ASN.1 Configuration" "cat '$SERVER_ASN1_CNF'"
        run_recorded "Encode Server EC Private Key DER from scalar ASN.1" "openssl asn1parse -genconf '$SERVER_ASN1_CNF' -out '$SERVE_DIR/server_raw.der'"
        run_recorded "Package Server EC Private Key to PEM" "echo '-----BEGIN EC PRIVATE KEY-----' > '$SERVE_DIR/server.key.pem' && openssl base64 -in '$SERVE_DIR/server_raw.der' >> '$SERVE_DIR/server.key.pem' && echo '-----END EC PRIVATE KEY-----' >> '$SERVE_DIR/server.key.pem'"
        rm -f "$SERVE_DIR/server_raw.der"
        run_recorded "Inspect Server EC Private Key (shows exact scalar hex in priv:)" "openssl ec -in '$SERVE_DIR/server.key.pem' -text -noout"
    else
        # Fallback: Generate keys using OpenSSL PRNG
        echo ">> Generating EC keys using OpenSSL PRNG"
        run_recorded "Generate CA EC Private Key (curve: $CA_CURVE)" \
            "openssl ecparam -name '$CA_CURVE' -genkey -noout -out '$SERVE_DIR/ca.key.pem'"
        run_recorded "Inspect CA EC Private Key" \
            "openssl ec -in '$SERVE_DIR/ca.key.pem' -text -noout"
            
        run_recorded "Generate Server EC Private Key (curve: $SERVER_CURVE)" \
            "openssl ecparam -name '$SERVER_CURVE' -genkey -noout -out '$SERVE_DIR/server.key.pem'"
        run_recorded "Inspect Server EC Private Key" \
            "openssl ec -in '$SERVE_DIR/server.key.pem' -text -noout"
    fi

    # Generate CA Self-Signed Root Certificate
    run_recorded "Generate CA Self-Signed Root Certificate" \
        "openssl req -new -x509 -key '$SERVE_DIR/ca.key.pem' -out '$SERVE_DIR/ca.crt.pem' -days '$CA_DAYS' -subj '$CA_SUBJECT' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'"

    # Generate Server CSR (Certificate Signing Request)
    run_recorded "Generate Server Certificate Signing Request (CSR)" \
        "openssl req -new -key '$SERVE_DIR/server.key.pem' -out '$SERVE_DIR/server.csr.pem' -subj '$SERVER_SUBJECT'"

    # Build SAN Configuration File
    EXT_FILE="$SERVE_DIR/san.cnf"
    cat > "$EXT_FILE" <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
EOF

    dns_idx=1
    IFS=',' read -ra DOMAIN_ARR <<< "$(echo "$DOMAINS" | tr ' ' ',')"
    for d in "${DOMAIN_ARR[@]}"; do
        d_trimmed=$(echo "$d" | xxd -p | tr -d '\n' | sed 's/20//g' | xxd -r -p 2>/dev/null || echo "$d" | tr -d ' ')
        if [ -n "$d_trimmed" ]; then
            echo "DNS.$dns_idx = $d_trimmed" >> "$EXT_FILE"
            dns_idx=$((dns_idx + 1))
        fi
    done

    ip_idx=1
    IFS=',' read -ra IP_ARR <<< "$(echo "$IPS" | tr ' ' ',')"
    for ip in "${IP_ARR[@]}"; do
        ip_trimmed=$(echo "$ip" | tr -d ' ')
        if [ -n "$ip_trimmed" ]; then
            echo "IP.$ip_idx = $ip_trimmed" >> "$EXT_FILE"
            ip_idx=$((ip_idx + 1))
        fi
    done

    run_recorded "Create SAN Extensions Configuration" "cat '$EXT_FILE'"

    # Sign Server Certificate with CA
    run_recorded "Sign Server Certificate with CA" \
        "openssl x509 -req -in '$SERVE_DIR/server.csr.pem' -CA '$SERVE_DIR/ca.crt.pem' -CAkey '$SERVE_DIR/ca.key.pem' -CAcreateserial -out '$SERVE_DIR/server.crt.pem' -days '$SERVER_DAYS' -extfile '$EXT_FILE'"

    # Assemble Full Certificate Chain
    run_recorded "Assemble Certificate Chain (server.crt + ca.crt)" \
        "cat '$SERVE_DIR/server.crt.pem' '$SERVE_DIR/ca.crt.pem' > '$SERVE_DIR/fullchain.pem'"

    # Verify Certificate Chain
    run_recorded "Verify Server Certificate with CA Certificate" \
        "openssl verify -CAfile '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/server.crt.pem'"
    run_recorded "Verify Full Chain with CA Certificate" \
        "openssl verify -CAfile '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/fullchain.pem'"

    # Decode Certificate Details
    run_recorded "Decode Server Certificate Details" \
        "openssl x509 -in '$SERVE_DIR/server.crt.pem' -noout -text"
    run_recorded "Decode CA Certificate Details" \
        "openssl x509 -in '$SERVE_DIR/ca.crt.pem' -noout -text"
fi

# ------------------------------------------------------------------------------
# Generate HTML Documentation Page
# ------------------------------------------------------------------------------
echo ">> Generating HTML report for s_server: $HTML_OUTPUT_FILE"

NOW_TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

cat > "$HTML_OUTPUT_FILE" <<'HTML_HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenSSL s_server Testing Report</title>
  <style>
    :root {
      --bg: #0f172a;
      --card-bg: #1e293b;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --accent-hover: #0ea5e9;
      --success: #22c55e;
      --border: #334155;
      --code-bg: #0b1120;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.6;
      padding: 2rem 1rem;
    }
    .container {
      max-width: 1100px;
      margin: 0 auto;
    }
    header {
      margin-bottom: 2rem;
      border-bottom: 1px solid var(--border);
      padding-bottom: 1.5rem;
    }
    h1 {
      font-size: 2.25rem;
      font-weight: 700;
      color: #fff;
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }
    h1 .badge {
      font-size: 0.875rem;
      background: var(--accent);
      color: var(--bg);
      padding: 0.2rem 0.6rem;
      border-radius: 9999px;
      font-weight: 600;
    }
    p.lead {
      color: var(--text-muted);
      margin-top: 0.5rem;
      font-size: 1.1rem;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0.75rem;
      padding: 1.25rem;
    }
    .card-title {
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-muted);
      margin-bottom: 0.25rem;
    }
    .card-value {
      font-size: 1.15rem;
      font-weight: 600;
      color: #fff;
      word-break: break-all;
    }
    .section-title {
      font-size: 1.5rem;
      font-weight: 600;
      margin: 2rem 0 1rem;
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .step-box {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0.75rem;
      margin-bottom: 1.25rem;
      overflow: hidden;
    }
    .step-header {
      background: #192237;
      padding: 0.75rem 1.25rem;
      font-weight: 600;
      font-size: 0.95rem;
      color: var(--accent);
      border-bottom: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .step-body {
      padding: 1rem 1.25rem;
    }
    pre {
      background: var(--code-bg);
      border: 1px solid #1e293b;
      border-radius: 0.5rem;
      padding: 0.75rem 1rem;
      overflow-x: auto;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.875rem;
      color: #38bdf8;
      margin-bottom: 0.5rem;
    }
    .cmd-line {
      color: #f1f5f9;
      font-weight: bold;
    }
    .cmd-output {
      color: #94a3b8;
      max-height: 250px;
      overflow-y: auto;
    }
    .files-list {
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
      margin-top: 1rem;
    }
    .file-link {
      background: #1e293b;
      color: var(--accent);
      padding: 0.4rem 0.8rem;
      border-radius: 0.375rem;
      text-decoration: none;
      font-family: monospace;
      font-size: 0.875rem;
      border: 1px solid var(--border);
      transition: all 0.2s;
    }
    .file-link:hover {
      background: var(--accent);
      color: var(--bg);
    }
    footer {
      margin-top: 3rem;
      padding-top: 1.5rem;
      border-top: 1px solid var(--border);
      text-align: center;
      color: var(--text-muted);
      font-size: 0.875rem;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>OpenSSL s_server Testing Tool <span class="badge">mode: -__WWW_MODE__</span></h1>
      <p class="lead">Generated certificate chain, keys, and reproducible OpenSSL commands.</p>
    </header>

    <div class="grid">
      <div class="card">
        <div class="card-title">s_server Mode</div>
        <div class="card-value">-__WWW_MODE__ (Port __PORT__)</div>
      </div>
      <div class="card">
        <div class="card-title">Entropy / Scalar "s"</div>
        <div class="card-value">__SEED_DISPLAY__</div>
      </div>
      <div class="card">
        <div class="card-title">EC Curves</div>
        <div class="card-value">CA: __CA_CURVE__<br>Server: __SERVER_CURVE__</div>
      </div>
      <div class="card">
        <div class="card-title">Server Subject</div>
        <div class="card-value">__SERVER_SUBJECT__</div>
      </div>
      <div class="card">
        <div class="card-title">Domains (SAN)</div>
        <div class="card-value">__DOMAINS__</div>
      </div>
      <div class="card">
        <div class="card-title">IPs (SAN)</div>
        <div class="card-value">__IPS__</div>
      </div>
    </div>

    <div class="section-title">Serving Files & PEM Artifacts</div>
    <div class="files-list">
      <a class="file-link" href="fullchain.pem" download>&#128196; fullchain.pem</a>
      <a class="file-link" href="server.crt.pem" download>&#128196; server.crt.pem</a>
      <a class="file-link" href="server.key.pem" download>&#128196; server.key.pem</a>
      <a class="file-link" href="ca.crt.pem" download>&#128196; ca.crt.pem</a>
      <a class="file-link" href="server.csr.pem" download>&#128196; server.csr.pem</a>
      <a class="file-link" href="san.cnf" download>&#128196; san.cnf</a>
      <a class="file-link" href="commands.log" download>&#128196; commands.log</a>
    </div>

    <div class="section-title">OpenSSL Commands Executed</div>
HTML_HEADER

# Replace placeholders in HTML_OUTPUT_FILE
sed -i "s|__WWW_MODE__|$WWW_MODE|g" "$HTML_OUTPUT_FILE"
sed -i "s|__PORT__|$PORT|g" "$HTML_OUTPUT_FILE"
sed -i "s|__SEED_DISPLAY__|$SEED_DISPLAY|g" "$HTML_OUTPUT_FILE"
sed -i "s|__CA_CURVE__|$CA_CURVE|g" "$HTML_OUTPUT_FILE"
sed -i "s|__SERVER_CURVE__|$SERVER_CURVE|g" "$HTML_OUTPUT_FILE"
sed -i "s|__SERVER_SUBJECT__|$SERVER_SUBJECT|g" "$HTML_OUTPUT_FILE"
sed -i "s|__DOMAINS__|$DOMAINS|g" "$HTML_OUTPUT_FILE"
sed -i "s|__IPS__|$IPS|g" "$HTML_OUTPUT_FILE"

# Append recorded commands
step_num=1
for i in "${!RECORDED_COMMANDS[@]}"; do
    desc="${RECORDED_DESCS[$i]}"
    cmd="${RECORDED_COMMANDS[$i]}"
    out="${RECORDED_OUTPUTS[$i]}"
    
    cmd_escaped=$(echo "$cmd" | escape_html)
    out_escaped=$(echo "$out" | escape_html)
    
    cat >> "$HTML_OUTPUT_FILE" <<EOF
    <div class="step-box">
      <div class="step-header">
        <span>Step $step_num: $desc</span>
      </div>
      <div class="step-body">
        <pre><span class="cmd-line">$cmd_escaped</span></pre>
EOF
    if [ -n "$out" ]; then
        cat >> "$HTML_OUTPUT_FILE" <<EOF
        <pre class="cmd-output">$out_escaped</pre>
EOF
    fi
    cat >> "$HTML_OUTPUT_FILE" <<EOF
      </div>
    </div>
EOF
    step_num=$((step_num + 1))
done

cat >> "$HTML_OUTPUT_FILE" <<EOF
    <div class="section-title">Testing with Clients</div>
    <div class="step-box">
      <div class="step-header"><span>TLS Client Commands</span></div>
      <div class="step-body">
        <pre><span class="cmd-line"># Connect and verify with OpenSSL s_client</span>
openssl s_client -connect localhost:$PORT -showcerts -CAfile ca.crt.pem

# Fetch page using curl trusting generated CA
curl --cacert ca.crt.pem https://localhost:$PORT/index.html

# Fetch page with insecure flag
curl -k https://localhost:$PORT/index.html</pre>
      </div>
    </div>

    <footer>
      Generated at $NOW_TIMESTAMP &bull; Powered by OpenSSL s_server
    </footer>
  </div>
</body>
</html>
EOF

# Also create commands.txt and openssl.html for alternate file requests
cp "$HTML_OUTPUT_FILE" "$SERVE_DIR/openssl.html"
cp "$COMMAND_LOG_FILE" "$SERVE_DIR/commands.txt" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Launch openssl s_server
# ------------------------------------------------------------------------------
echo "==================================================================="
echo " Launching openssl s_server on port $PORT with -$WWW_MODE"
echo "==================================================================="

S_SERVER_CMD=(
    openssl s_server
    -accept "$PORT"
    -key "$SERVE_DIR/server.key.pem"
    -cert "$SERVE_DIR/fullchain.pem"
    "-$WWW_MODE"
)

if [ -f "$SERVE_DIR/ca.crt.pem" ]; then
    S_SERVER_CMD+=(-CAfile "$SERVE_DIR/ca.crt.pem")
fi

if [ -n "$EXTRA_S_SERVER_ARGS" ]; then
    # shellcheck disable=SC2206
    S_SERVER_CMD+=($EXTRA_S_SERVER_ARGS)
fi

echo "Executing: ${S_SERVER_CMD[*]}"
exec "${S_SERVER_CMD[@]}"
