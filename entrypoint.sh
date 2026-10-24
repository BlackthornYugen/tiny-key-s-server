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
PUBLIC_PORT="${PUBLIC_PORT:-443}"
if [ "$PUBLIC_PORT" = "443" ]; then
    PUBLIC_PORT_SUFFIX=""
else
    PUBLIC_PORT_SUFFIX=":${PUBLIC_PORT}"
fi
WWW_MODE="${WWW_MODE:-${SERVER_MODE:-WWW}}" # WWW, www, or HTTP

# Curves
DEFAULT_CURVE="${CURVE:-prime256v1}"
CA_CURVE="${CA_CURVE:-$DEFAULT_CURVE}"
SERVER_CURVE="${SERVER_CURVE:-$DEFAULT_CURVE}"

# Subjects
CA_SUBJECT="${CA_SUBJECT:-/CN=Test OpenSSL CA/O=Test Lab/C=CA}"
SERVER_SUBJECT="${SERVER_SUBJECT:-/CN=localhost/O=Test Lab/C=CA}"

# SANs (Domains and IPs)
DOMAINS="${DOMAINS:-${SAN_DOMAINS:-localhost}}"
IPS="${IPS:-${SAN_IPS:-127.0.0.1}}"

# Validity
CA_DAYS="${CA_DAYS:-3650}"
SERVER_DAYS="${SERVER_DAYS:-365}"

# Optional mounted volume directory
CERTS_DIR="${CERTS_DIR:-/certs}"

# Chains and Multi-Path / Cross-Signing Configuration
CHAIN_MODE="${CHAIN_MODE:-default}" # default, all, or specific path name (e.g. c1, c2)
CHAINS_DIR="${CHAINS_DIR:-$CERTS_DIR/chains}"
ROOTS_DIR="${ROOTS_DIR:-$CERTS_DIR/roots}"
EXTRA_CHAIN_PEM="${EXTRA_CHAIN_PEM:-}"
CHAIN_FILE="${CHAIN_FILE:-}"
ROOTS="${ROOTS:-${CHAINS:-}}"
ROOT_S_BYTES="${ROOT_S_BYTES:-}"
ROOTS_INPUT="$ROOTS"
ROOT_S_BYTES_INPUT="$ROOT_S_BYTES"

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

unpad_hex() {
    local hex="$1"
    hex="${hex#0x}"
    hex="${hex#0X}"
    local unpadded
    unpadded=$(echo "$hex" | sed 's/^0*//')
    if [ -z "$unpadded" ]; then
        unpadded="00"
    elif [ $(( ${#unpadded} % 2 )) -ne 0 ]; then
        unpadded="0$unpadded"
    fi
    echo "0x$unpadded"
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
SERVER_SCALAR_DISPLAY="Random"
CA_SCALAR_DISPLAY="Random"

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
    SERVER_SCALAR_DISPLAY="External"
    CA_SCALAR_DISPLAY="External"
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
        
        SERVER_SCALAR_DISPLAY=$(unpad_hex "$SERVER_SCALAR")
        CA_SCALAR_DISPLAY=$(unpad_hex "$CA_SCALAR")
        SEED_TYPE="Exact Scalar 's' Bytes"
        SEED_DISPLAY="Server: $SERVER_SCALAR_DISPLAY<br>CA:     $CA_SCALAR_DISPLAY"
        echo ">> Configured EC scalar 's' bytes:"
        echo "   Server Key scalar: 0x$SERVER_SCALAR ($SERVER_SCALAR_DISPLAY)"
        echo "   CA Key scalar:     0x$CA_SCALAR ($CA_SCALAR_DISPLAY)"
        
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

    # Generate Intermediate CA CSR (for cross-signing or chaining up to external roots)
    run_recorded "Generate CA Certificate Signing Request (CSR) for key b" \
        "openssl req -new -key '$SERVE_DIR/ca.key.pem' -out '$SERVE_DIR/ca.csr.pem' -subj '$CA_SUBJECT'"

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

    # --------------------------------------------------------------------------
    # Cross-Signing & Certificate Chain Assembly
    # --------------------------------------------------------------------------
    mkdir -p "$SERVE_DIR/chains" "$SERVE_DIR/roots"

    # 0. Check for ROOTS or ROOT_S_BYTES env vars and auto-generate Root CAs if provided
    ROOTS_INPUT="${ROOTS:-${CHAINS:-}}"
    ROOT_S_BYTES_INPUT="${ROOT_S_BYTES:-}"

    if [ -n "$ROOTS_INPUT" ] || [ -n "$ROOT_S_BYTES_INPUT" ]; then
        declare -a ROOT_NAMES=()
        declare -a ROOT_SCALARS=()

        if [ -n "$ROOTS_INPUT" ]; then
            IFS=',' read -ra R_NAME_ARR <<< "$ROOTS_INPUT"
            for rn in "${R_NAME_ARR[@]}"; do
                r_trimmed=$(echo "$rn" | tr -d ' ')
                [ -n "$r_trimmed" ] && ROOT_NAMES+=("$r_trimmed")
            done
        fi

        if [ -n "$ROOT_S_BYTES_INPUT" ]; then
            IFS=',' read -ra R_SCALAR_ARR <<< "$ROOT_S_BYTES_INPUT"
            for rs in "${R_SCALAR_ARR[@]}"; do
                rs_trimmed=$(echo "$rs" | tr -d ' ')
                [ -n "$rs_trimmed" ] && ROOT_SCALARS+=("$rs_trimmed")
            done
        fi

        # If names were given but not scalars, generate deterministic scalars
        if [ ${#ROOT_NAMES[@]} -gt 0 ] && [ ${#ROOT_SCALARS[@]} -eq 0 ]; then
            idx=1
            for rn in "${ROOT_NAMES[@]}"; do
                hex_val=$(printf "%02x" $((16 * idx)))
                ROOT_SCALARS+=("$hex_val")
                idx=$((idx + 1))
            done
        fi

        # If scalars were given but not names, generate names c1, c2, ...
        if [ ${#ROOT_SCALARS[@]} -gt 0 ] && [ ${#ROOT_NAMES[@]} -eq 0 ]; then
            idx=1
            for rs in "${ROOT_SCALARS[@]}"; do
                ROOT_NAMES+=("c$idx")
                idx=$((idx + 1))
            done
        fi

        # Generate each Root CA and sign Intermediate B
        for i in "${!ROOT_NAMES[@]}"; do
            r_name="${ROOT_NAMES[$i]}"
            r_scalar="${ROOT_SCALARS[$i]}"
            r_scalar_formatted=$(format_scalar "$r_scalar" "$(get_curve_bytes "$CA_CURVE")")

            r_key="$SERVE_DIR/roots/${r_name}.key.pem"
            r_crt="$SERVE_DIR/roots/${r_name}.crt.pem"

            # ASN.1 key configuration
            r_asn="$SERVE_DIR/roots/asn_${r_name}.cnf"
            cat > "$r_asn" <<EOF
asn1 = SEQUENCE:ec_key
[ec_key]
version = INTEGER:1
privkey = FORMAT:HEX,OCTETSTRING:$r_scalar_formatted
params = EXPLICIT:0,OBJECT:$CA_CURVE
EOF
            run_recorded "Encode Root CA '$r_name' DER from scalar $r_scalar" \
                "openssl asn1parse -genconf '$r_asn' -out '$SERVE_DIR/roots/${r_name}.der'"
            run_recorded "Package Root CA '$r_name' EC Private Key to PEM" \
                "echo '-----BEGIN EC PRIVATE KEY-----' > '$r_key' && openssl base64 -in '$SERVE_DIR/roots/${r_name}.der' >> '$r_key' && echo '-----END EC PRIVATE KEY-----' >> '$r_key'"
            rm -f "$SERVE_DIR/roots/${r_name}.der" "$r_asn"

            # Generate Self-Signed Root Certificate
            run_recorded "Generate Self-Signed Root Certificate for '$r_name'" \
                "openssl req -new -x509 -key '$r_key' -out '$r_crt' -days '$CA_DAYS' -subj '/CN=Root CA ${r_name}/O=Test Lab/C=CA' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -addext 'subjectKeyIdentifier=hash'"

            # Intermediate extension file
            inter_cnf="$SERVE_DIR/chains/inter_ext_${r_name}.cnf"
            cat > "$inter_cnf" <<EOF
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
            run_recorded "Sign Intermediate B with Root CA '$r_name'" \
                "openssl x509 -req -in '$SERVE_DIR/ca.csr.pem' -CA '$r_crt' -CAkey '$r_key' -CAcreateserial -out '$SERVE_DIR/chains/${r_name}.pem' -days '$CA_DAYS' -extfile '$inter_cnf'"

            # Append root certificate so the chain is complete
            cat "$r_crt" >> "$SERVE_DIR/chains/${r_name}.pem"
        done

        # If there are 2 or more roots, build all.pem
        if [ ${#ROOT_NAMES[@]} -gt 1 ]; then
            cat "$SERVE_DIR"/chains/c*.pem > "$SERVE_DIR/chains/all.pem"
        fi
    fi

    # 1. Check for external/mounted root CAs in $ROOTS_DIR and auto-sign CA key b
    if [ -d "$ROOTS_DIR" ]; then
        for root_key in "$ROOTS_DIR"/*.key "$ROOTS_DIR"/*.key.pem; do
            [ -f "$root_key" ] || continue
            root_base=$(basename "$root_key")
            root_name="${root_base%.key.pem}"
            root_name="${root_name%.key}"

            root_crt=""
            for crt_cand in "$ROOTS_DIR/$root_name.crt" "$ROOTS_DIR/$root_name.crt.pem" "$ROOTS_DIR/$root_name.pem"; do
                if [ -f "$crt_cand" ]; then
                    root_crt="$crt_cand"
                    break
                fi
            done

            if [ -n "$root_crt" ]; then
                echo ">> Found Root CA '$root_name' ($root_crt). Signing Intermediate B..."
                INTER_EXT_FILE="$SERVE_DIR/chains/inter_ext_${root_name}.cnf"
                cat > "$INTER_EXT_FILE" <<EOF
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
                run_recorded "Sign Intermediate B with Root CA '$root_name'" \
                    "openssl x509 -req -in '$SERVE_DIR/ca.csr.pem' -CA '$root_crt' -CAkey '$root_key' -CAcreateserial -out '$SERVE_DIR/chains/${root_name}.pem' -days '$CA_DAYS' -extfile '$INTER_EXT_FILE'"
                # Append root cert to this chain path
                cat "$root_crt" >> "$SERVE_DIR/chains/${root_name}.pem"
            fi
        done
    fi

    # 2. Check for pre-existing chain files in $CHAINS_DIR
    if [ -d "$CHAINS_DIR" ]; then
        for cfile in "$CHAINS_DIR"/*.pem "$CHAINS_DIR"/*.crt; do
            [ -f "$cfile" ] || continue
            cbase=$(basename "$cfile")
            cname="${cbase%.crt}"
            cname="${cname%.pem}"
            cname="${cname%.chain}"
            cp "$cfile" "$SERVE_DIR/chains/${cname}.pem"
            echo ">> Loaded chain file from volume: $cfile as $cname"
        done
    fi

    # 3. Check for EXTRA_CHAIN_PEM env var
    if [ -n "$EXTRA_CHAIN_PEM" ]; then
        echo "$EXTRA_CHAIN_PEM" > "$SERVE_DIR/chains/extra.pem"
        echo ">> Loaded inline EXTRA_CHAIN_PEM into $SERVE_DIR/chains/extra.pem"
    fi

    # 4. Check for CHAIN_FILE env var
    if [ -n "$CHAIN_FILE" ] && [ -f "$CHAIN_FILE" ]; then
        cp "$CHAIN_FILE" "$SERVE_DIR/chains/custom.pem"
        echo ">> Loaded CHAIN_FILE $CHAIN_FILE into $SERVE_DIR/chains/custom.pem"
    fi

    # 5. Assemble chain according to CHAIN_MODE (default, all, or named path)
    echo ">> Active CHAIN_MODE: $CHAIN_MODE"
    case "$CHAIN_MODE" in
        all)
            # Concatenate all available chains in $SERVE_DIR/chains/*.pem
            CHAIN_CANDIDATES=("$SERVE_DIR"/chains/*.pem)
            if [ -e "${CHAIN_CANDIDATES[0]}" ]; then
                run_recorded "Assemble Multi-Path Intermediate Chain (all paths)" \
                    "cat '$SERVE_DIR'/chains/*.pem > '$SERVE_DIR/chain.pem'"
            else
                run_recorded "Assemble Default Chain (ca.crt.pem)" \
                    "cp '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/chain.pem'"
            fi
            ;;
        default|"")
            run_recorded "Assemble Default Intermediate Chain (ca.crt.pem)" \
                "cp '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/chain.pem'"
            ;;
        *)
            # Specific path name: e.g. c1, c2, extra, custom
            SPECIFIC_CHAIN=""
            for cand in "$SERVE_DIR/chains/$CHAIN_MODE.pem" "$SERVE_DIR/chains/$CHAIN_MODE.crt" "$SERVE_DIR/chains/$CHAIN_MODE.chain.pem" "$SERVE_DIR/chains/$CHAIN_MODE"; do
                if [ -f "$cand" ]; then
                    SPECIFIC_CHAIN="$cand"
                    break
                fi
            done
            if [ -n "$SPECIFIC_CHAIN" ]; then
                run_recorded "Select Specific Chain Path '$CHAIN_MODE'" \
                    "cp '$SPECIFIC_CHAIN' '$SERVE_DIR/chain.pem'"
            else
                echo "Warning: CHAIN_MODE='$CHAIN_MODE' specified but no matching chain file found in $SERVE_DIR/chains/. Falling back to ca.crt.pem"
                run_recorded "Assemble Default Chain (ca.crt.pem fallback)" \
                    "cp '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/chain.pem'"
            fi
            ;;
    esac

    # Assemble Full Certificate Chain (server.crt.pem + chain.pem)
    run_recorded "Assemble Full Certificate Chain (server.crt.pem + chain.pem)" \
        "cat '$SERVE_DIR/server.crt.pem' '$SERVE_DIR/chain.pem' > '$SERVE_DIR/fullchain.pem'"

    # Verify Certificate Chain Structure
    if [ "$CHAIN_MODE" = "default" ] || [ ! -d "$SERVE_DIR/chains" ] || [ -z "$(ls -A "$SERVE_DIR/chains" 2>/dev/null)" ]; then
        run_recorded "Verify Server Certificate with CA Certificate" \
            "openssl verify -CAfile '$SERVE_DIR/ca.crt.pem' '$SERVE_DIR/server.crt.pem'"
        run_recorded "Verify Full Chain with CA Certificate" \
            "openssl verify -CAfile '$SERVE_DIR/ca.crt.pem' -untrusted '$SERVE_DIR/chain.pem' '$SERVE_DIR/server.crt.pem'"
    else
        # If external roots exist, verify against root
        if [ -d "$ROOTS_DIR" ]; then
            for r_crt in "$ROOTS_DIR"/*.crt "$ROOTS_DIR"/*.pem; do
                [ -f "$r_crt" ] || continue
                run_recorded "Verify Chain against Root CA $(basename "$r_crt")" \
                    "openssl verify -CAfile '$r_crt' -untrusted '$SERVE_DIR/chain.pem' '$SERVE_DIR/server.crt.pem' || true"
            done
        fi
        run_recorded "Verify Full Chain with CA Certificate" \
            "openssl verify -CAfile '$SERVE_DIR/ca.crt.pem' -untrusted '$SERVE_DIR/chain.pem' '$SERVE_DIR/server.crt.pem' || true"
    fi

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
    .runtime-bar {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0.75rem;
      padding: 0.85rem 1.25rem;
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      margin-bottom: 1.25rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.85rem;
    }
    .runtime-items {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 1.5rem;
    }
    .runtime-item {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }
    .runtime-label {
      color: var(--text-muted);
      text-transform: uppercase;
      font-size: 0.72rem;
      letter-spacing: 0.05em;
    }
    .runtime-val {
      color: #fff;
      font-weight: 600;
    }
    .runtime-badge {
      background: rgba(56, 189, 248, 0.15);
      color: #38bdf8;
      border: 1px solid rgba(56, 189, 248, 0.3);
      padding: 0.15rem 0.5rem;
      border-radius: 0.375rem;
      font-weight: 600;
    }
    .two-col {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 1.25rem;
      margin-bottom: 2rem;
    }
    .entity-card {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0.75rem;
      padding: 1.25rem;
      display: flex;
      flex-direction: column;
      gap: 0.85rem;
    }
    .entity-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid var(--border);
      padding-bottom: 0.75rem;
    }
    .entity-title-group {
      display: flex;
      align-items: center;
      gap: 0.6rem;
    }
    .entity-badge-leaf {
      background: rgba(52, 211, 153, 0.2);
      color: #34d399;
      border: 1px solid rgba(52, 211, 153, 0.3);
      font-size: 0.75rem;
      font-weight: 700;
      padding: 0.2rem 0.5rem;
      border-radius: 0.375rem;
      letter-spacing: 0.05em;
    }
    .entity-badge-ca {
      background: rgba(129, 140, 248, 0.2);
      color: #818cf8;
      border: 1px solid rgba(129, 140, 248, 0.3);
      font-size: 0.75rem;
      font-weight: 700;
      padding: 0.2rem 0.5rem;
      border-radius: 0.375rem;
      letter-spacing: 0.05em;
    }
    .entity-name {
      font-weight: 600;
      font-size: 0.95rem;
      color: #fff;
    }
    .entity-curve {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.75rem;
      color: var(--text-muted);
    }
    .entity-curve strong {
      color: #fff;
    }
    .entity-meta-row {
      display: grid;
      grid-template-columns: 1fr 2fr;
      gap: 0.75rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.8rem;
    }
    .meta-box {
      background: rgba(15, 23, 42, 0.6);
      border: 1px solid rgba(51, 65, 85, 0.6);
      border-radius: 0.5rem;
      padding: 0.65rem;
    }
    .meta-label {
      color: var(--text-muted);
      text-transform: uppercase;
      font-size: 0.65rem;
      letter-spacing: 0.05em;
      margin-bottom: 0.25rem;
    }
    .meta-val {
      word-break: break-all;
    }
    .meta-val-leaf {
      color: #34d399;
      font-weight: 700;
      font-size: 1.05rem;
    }
    .meta-val-ca {
      color: #818cf8;
      font-weight: 700;
      font-size: 1.05rem;
    }
    .subject-box {
      background: rgba(15, 23, 42, 0.4);
      border: 1px solid rgba(51, 65, 85, 0.4);
      border-radius: 0.5rem;
      padding: 0.65rem;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 0.8rem;
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
      <p class="lead">Testing standard EC curves with small integers as private key scalars.</p>
    </header>

    <!-- Runtime Summary Bar -->
    <div class="runtime-bar">
      <div class="runtime-items">
        <div class="runtime-item">
          <span class="runtime-label">Port:</span>
          <span class="runtime-val">__PORT__ (TCP)</span>
        </div>
        <div class="runtime-item">
          <span class="runtime-label">Mode:</span>
          <span class="runtime-val">-__WWW_MODE__</span>
        </div>
        <div class="runtime-item">
          <span class="runtime-label">Active Chain:</span>
          <span class="runtime-badge">__CHAIN_MODE__</span>
        </div>
      </div>
      <div class="runtime-item">
        <span class="runtime-label">Cross-Signed Roots:</span>
        <span class="runtime-val">__ROOTS_SUMMARY__</span>
      </div>
    </div>

    <!-- 2 Column Entity Layout (Leaf vs CA) -->
    <div class="two-col">
      <!-- Leaf Server Entity -->
      <div class="entity-card">
        <div class="entity-header">
          <div class="entity-title-group">
            <span class="entity-badge-leaf">LEAF</span>
            <span class="entity-name">Server Key &amp; Certificate</span>
          </div>
          <div class="entity-curve">Curve: <strong>__SERVER_CURVE__</strong></div>
        </div>

        <div class="entity-meta-row">
          <div class="meta-box">
            <div class="meta-label">Scalar 's'</div>
            <div class="meta-val meta-val-leaf">__SERVER_SCALAR_DISPLAY__</div>
          </div>
          <div class="meta-box">
            <div class="meta-label">SAN Domains &amp; IPs</div>
            <div class="meta-val" style="color: #e2e8f0;">__DOMAINS__, __IPS__</div>
          </div>
        </div>

        <div class="subject-box">
          <div class="meta-label">Subject DN</div>
          <div class="meta-val" style="color: #cbd5e1;">__SERVER_SUBJECT__</div>
        </div>
      </div>

      <!-- CA Issuer Entity -->
      <div class="entity-card">
        <div class="entity-header">
          <div class="entity-title-group">
            <span class="entity-badge-ca">CA</span>
            <span class="entity-name">Intermediate B Certificate</span>
          </div>
          <div class="entity-curve">Curve: <strong>__CA_CURVE__</strong></div>
        </div>

        <div class="entity-meta-row">
          <div class="meta-box">
            <div class="meta-label">Scalar 's'</div>
            <div class="meta-val meta-val-ca">__CA_SCALAR_DISPLAY__</div>
          </div>
          <div class="meta-box">
            <div class="meta-label">Signers / Roots</div>
            <div class="meta-val" style="color: #e2e8f0;">__ROOTS_DETAIL__</div>
          </div>
        </div>

        <div class="subject-box">
          <div class="meta-label">Subject DN</div>
          <div class="meta-val" style="color: #cbd5e1;">__CA_SUBJECT__</div>
        </div>
      </div>
    </div>

    <div class="section-title">Serving Files & PEM Artifacts</div>
    <div class="files-list">
      <a class="file-link" href="fullchain.pem" download>&#128196; fullchain.pem</a>
      <a class="file-link" href="chain.pem" download>&#128196; chain.pem</a>
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
sed -i "s|__CA_SUBJECT__|$CA_SUBJECT|g" "$HTML_OUTPUT_FILE"
sed -i "s|__SERVER_SUBJECT__|$SERVER_SUBJECT|g" "$HTML_OUTPUT_FILE"
sed -i "s|__DOMAINS__|$DOMAINS|g" "$HTML_OUTPUT_FILE"
sed -i "s|__IPS__|$IPS|g" "$HTML_OUTPUT_FILE"
sed -i "s|__CHAIN_MODE__|$CHAIN_MODE|g" "$HTML_OUTPUT_FILE"
if [ -n "$ROOTS_INPUT" ]; then
    ROOTS_SUMMARY="$ROOTS_INPUT"
    if [ -n "$ROOT_S_BYTES_INPUT" ]; then
        ROOTS_DETAIL=""
        IFS=',' read -ra R_NAMES <<< "$ROOTS_INPUT"
        IFS=',' read -ra R_SCALARS <<< "$ROOT_S_BYTES_INPUT"
        for idx in "${!R_NAMES[@]}"; do
            rn=$(echo "${R_NAMES[$idx]}" | tr -d ' ')
            rs=$(echo "${R_SCALARS[$idx]:-}" | tr -d ' ')
            [ -n "$rs" ] && rs=$(unpad_hex "$rs")
            if [ -n "$ROOTS_DETAIL" ]; then
                ROOTS_DETAIL="$ROOTS_DETAIL, "
            fi
            ROOTS_DETAIL="${ROOTS_DETAIL}${rn} (${rs})"
        done
        ROOTS_SUMMARY="$ROOTS_DETAIL"
    else
        ROOTS_DETAIL="$ROOTS_INPUT"
        ROOTS_SUMMARY="$ROOTS_INPUT"
    fi
else
    ROOTS_SUMMARY="None"
    ROOTS_DETAIL="Self-Signed Root"
fi

sed -i "s|__ROOTS_SUMMARY__|$ROOTS_SUMMARY|g" "$HTML_OUTPUT_FILE"
sed -i "s|__ROOTS_DETAIL__|$ROOTS_DETAIL|g" "$HTML_OUTPUT_FILE"
sed -i "s|__SERVER_SCALAR_DISPLAY__|$SERVER_SCALAR_DISPLAY|g" "$HTML_OUTPUT_FILE"
sed -i "s|__CA_SCALAR_DISPLAY__|$CA_SCALAR_DISPLAY|g" "$HTML_OUTPUT_FILE"

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

format_chain_domain() {
    local chain="$1"
    local host="$2"
    if [[ "$host" =~ ^(p(r)?-?[0-9]+-)(.*) ]]; then
        local pr_pfx="${BASH_REMATCH[1]}"
        local rest="${BASH_REMATCH[3]}"
        echo "${pr_pfx}${chain}-${rest}"
    else
        echo "${chain}-${host}"
    fi
}

PRIMARY_HOST=$(echo "$DOMAINS" | cut -d',' -f1)

# Append Multi-Chain Endpoints Info to HTML
cat >> "$HTML_OUTPUT_FILE" <<EOF
    <div class="section-title">Multi-Chain Endpoints & Ingress Routes</div>
    <div class="step-box">
      <div class="step-header"><span>Dedicated Chain Endpoints</span></div>
      <div class="step-body">
        <pre><span class="cmd-line"># Primary Endpoint (Default Browser / Web UI)</span>
Host: ${PRIMARY_HOST}${PUBLIC_PORT_SUFFIX}
Chain Mode: $CHAIN_MODE
EOF

if [ -d "$SERVE_DIR/chains" ]; then
    for cf in "$SERVE_DIR/chains"/c*.pem; do
        [ -f "$cf" ] || continue
        cb=$(basename "$cf" .pem)
        ch_host=$(format_chain_domain "$cb" "$PRIMARY_HOST")
        cat >> "$HTML_OUTPUT_FILE" <<EOF

<span class="cmd-line"># Endpoint: Chain '$cb' (Dedicated Pod & Ingress)</span>
Domain: ${ch_host}
openssl s_client -connect ${ch_host}:${PUBLIC_PORT} -showcerts
EOF
    done
    if [ -f "$SERVE_DIR/chains/all.pem" ]; then
        all_host=$(format_chain_domain "all" "$PRIMARY_HOST")
        cat >> "$HTML_OUTPUT_FILE" <<EOF

<span class="cmd-line"># Endpoint: Combined Chain 'all' (Dedicated Pod & Ingress)</span>
Domain: ${all_host}
openssl s_client -connect ${all_host}:${PUBLIC_PORT} -showcerts
EOF
    fi
fi

cat >> "$HTML_OUTPUT_FILE" <<EOF
</pre>
      </div>
    </div>
EOF

cat >> "$HTML_OUTPUT_FILE" <<EOF
    <div class="section-title">Testing with Clients</div>
    <div class="step-box">
      <div class="step-header"><span>TLS Client Commands</span></div>
      <div class="step-body">
        <pre><span class="cmd-line"># Public Ingress Endpoint</span>
curl -k https://${PRIMARY_HOST}${PUBLIC_PORT_SUFFIX}/index.html
openssl s_client -connect ${PRIMARY_HOST}:${PUBLIC_PORT} -servername ${PRIMARY_HOST} -showcerts

<span class="cmd-line"># Local / In-Cluster Verification</span>
openssl s_client -connect localhost:$PORT -showcerts -CAfile ca.crt.pem
curl --cacert ca.crt.pem https://localhost:$PORT/index.html
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
echo " Active Chain Mode: $CHAIN_MODE"
echo "==================================================================="

CERT_FILE="$SERVE_DIR/server.crt.pem"
[ -f "$CERT_FILE" ] || CERT_FILE="$SERVE_DIR/fullchain.pem"

CHAIN_FILE_ARG="$SERVE_DIR/chain.pem"
[ -f "$CHAIN_FILE_ARG" ] || CHAIN_FILE_ARG="$SERVE_DIR/fullchain.pem"

S_SERVER_CMD=(
    openssl s_server
    -accept "$PORT"
    -key "$SERVE_DIR/server.key.pem"
    -cert "$CERT_FILE"
    -cert_chain "$CHAIN_FILE_ARG"
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
