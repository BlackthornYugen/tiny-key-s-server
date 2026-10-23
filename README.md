# tiny-key-s-server

A lightweight, automated containerized testing tool powered by Alpine Linux and OpenSSL `s_server` for testing with small integers as Elliptic Curve private keys.

It generates a two-tier Elliptic Curve (EC) certificate chain (CA + Server), signs the server certificate with custom SAN extensions (IPs and domain names), captures and echoes all executed OpenSSL commands, and serves a live HTML report explaining how the certificate and key were created while running in `-WWW` or `-www` mode.

---

## Features

- **Dynamic EC Key & Chain Generation**: Generates a CA key & certificate, a server key & CSR, signs the server certificate using the CA with Subject Alternative Names (SANs), and bundles them into `fullchain.pem`.
- **Cross-Signed & Multi-Path Chains**: Because EC keys $a$ (server) and $b$ (intermediate CA) are fully deterministic, intermediate key $b$ can be pre-signed or cross-signed by external roots ($b \rightarrow c_1$, $b \rightarrow c_2$). The server dynamically bundles certificates and serves either the default chain, a specific cross-signed path (`CHAIN_MODE=c1`), or all available paths combined (`CHAIN_MODE=all`).
- **Exact Scalar `s` Bytes Input**: Directly accepts an EC private key scalar $s$ as a hex string (e.g., `0xdeadbeef1337` or `deadbeef...`) or small integer (e.g., `42`), embedding the exact hex scalar into the generated EC private key so that `openssl ec -text` displays your exact bytes under `priv:`.
- **Configurable via Environment Variables**:
  - Scalars: `S_BYTES`, `SERVER_S_BYTES`, `CA_S_BYTES`.
  - Curves: `CA_CURVE`, `SERVER_CURVE`, or fallback `CURVE` (e.g., `prime256v1`, `secp384r1`, `secp521r1`).
  - Subjects: `CA_SUBJECT` and `SERVER_SUBJECT`.
  - SANs: `DOMAINS` and `IPS` (comma or space separated).
  - Modes: `WWW_MODE` (`WWW`, `www`, `HTTP`).
  - Ports: `PORT` (default `4433`).
- **Mounted Volume Support**: Automatically detects if pre-existing certificate chains (e.g., `fullchain.pem`, `tls.crt`) and private keys are mounted to `/certs`, serving those instead.
- **Interactive HTML Audit Page**: Echoes all commands executed with exit codes, parameters, and decoded certificate details (`openssl x509 -text -noout` and `openssl ec -text -noout`). In `-WWW` mode, visiting `https://<host>:<port>/index.html` renders this full report with one-click PEM file downloads.
- **Helm Chart & ArgoCD Integration**: Production-ready Helm chart (`chart/`) and ArgoCD Application (`argocd/`) matching Gitea CI/CD pipelines.

---

## Quick Start

### 1. Run with Custom Scalar `s` Bytes (Hex)

```bash
docker run -p 4433:4433 \
  -e S_BYTES="0xdeadbeef1337" \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```
When running `openssl ec -in server.key.pem -text -noout`, the private key scalar displays:
```text
priv:
    00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:
    00:00:00:00:00:00:00:00:00:00:00:de:ad:be:ef:
    13:37
```

### 2. Run with Integer Scalar `s`

```bash
docker run -p 4433:4433 \
  -e S_BYTES="42" \
  -e DOMAINS="localhost,test.internal" \
  -e IPS="127.0.0.1,192.168.1.100" \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```

### 3. Run with Independent CA and Server Scalars

```bash
docker run -p 4433:4433 \
  -e SERVER_S_BYTES="0xdeadbeef" \
  -e CA_S_BYTES="0x1337c0de" \
  -e CA_CURVE="prime256v1" \
  -e SERVER_CURVE="prime256v1" \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```

### 4. Run with Mounted Volume Override

If you have pre-generated certificates (such as Let's Encrypt or Vault certs):

```bash
docker run -p 4433:4433 \
  -v /path/to/my/certs:/certs:ro \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```
When `fullchain.pem` (or `tls.crt`) and `privkey.pem` (or `tls.key` / `server.key`) are present in `/certs`, the container inspects and serves them directly without generating new certificates.

### 5. Multi-Path and Cross-Signed Chains ($a \rightarrow b \rightarrow c_1 / c_2$)

Because keys $a$ (server, scalar $s$) and $b$ (CA, scalar $s+1$ or `CA_S_BYTES`) are deterministic, intermediate key $b$ can be pre-signed by external root CAs ($c_1, c_2, \dots$) ahead of time, or roots can be mounted to be signed automatically on startup.

#### Providing Chains via Volume Mount
Place cross-signed chain PEMs in `/certs/chains/`:
- `/certs/chains/c1.pem` (contains $b$ signed by $c_1$, and optionally $c_1$)
- `/certs/chains/c2.pem` (contains $b$ signed by $c_2$, and optionally $c_2$)

```bash
# Serve specific cross-signed path (a -> b_c1 -> c1)
docker run -p 4433:4433 \
  -e S_BYTES="0x01" \
  -e CA_S_BYTES="0x02" \
  -e CHAIN_MODE="c1" \
  -v /path/to/chains:/certs/chains:ro \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest

# Serve all paths concatenated in fullchain.pem (a -> b_c1 + b_c2)
docker run -p 4433:4433 \
  -e S_BYTES="0x01" \
  -e CA_S_BYTES="0x02" \
  -e CHAIN_MODE="all" \
  -v /path/to/chains:/certs/chains:ro \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```

#### Providing Chains via Environment Variables
For CI/CD or lightweight execution without volume mounts:
```bash
docker run -p 4433:4433 \
  -e S_BYTES="0x01" \
  -e CHAIN_MODE="all" \
  -e EXTRA_CHAIN_PEM="$(cat extra_chain.pem)" \
  ghcr.io/blackthornyugen/tiny-key-s-server:latest
```

#### Automatic Root Signing
Mount external root CA certificates and private keys to `/certs/roots/`:
- `/certs/roots/c1.crt` and `/certs/roots/c1.key`

On boot, the container automatically generates an intermediate certificate for key $b$ signed by root $c_1$, and makes it available under `CHAIN_MODE="c1"` or `CHAIN_MODE="all"`.

---

## Connecting & Testing

### Web Browser / cURL
In `-WWW` mode, fetch the HTML report:
```bash
# Insecure (skip CA verification)
curl -k https://localhost:4433/index.html

# Download the generated CA certificate
curl -k -O https://localhost:4433/ca.crt.pem

# Secure request using the downloaded CA
curl --cacert ca.crt.pem https://localhost:4433/index.html
```

### OpenSSL `s_client`
Connect and inspect the certificate chain in the terminal:
```bash
openssl s_client -connect localhost:4433 -showcerts
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `S_BYTES` / `SERVER_S_BYTES` | *`0x01` in chart* | Exact integer (e.g. `1`, `42`) or hex scalar (`0xdeadbeef...`) for the server EC private key. |
| `CA_S_BYTES` | *derived ($s+1$)* | Exact integer or hex scalar for the CA EC private key. |
| `ROOTS` / `CHAINS` | `c1,c2` *(in chart)* | Comma-separated list of root CA / chain names. Auto-derives 2..10 ingresses and companion ports (single chain omits `all`). |
| `ROOT_S_BYTES` | `0x10,0x20` *(in chart)* | Comma-separated exact scalars for root CAs. |
| `CHAIN_MODE` | `default` | Primary chain assembly mode: `default` ($a \rightarrow b$), `<name>`, or `all`. |
| `CHAINS_DIR` | `/certs/chains` | Directory containing pre-signed intermediate or cross-chain PEM files. |
| `ROOTS_DIR` | `/certs/roots` | Directory containing root CA `.crt` and `.key` pairs for automatic intermediate signing. |
| `EXTRA_CHAIN_PEM` | *empty* | Raw PEM certificate string to include in intermediate chain assembly. |
| `CHAIN_FILE` | *empty* | Path to a specific intermediate chain PEM file to include. |
| `WWW_MODE` | `WWW` | Mode for `openssl s_server` (`WWW` serves files, `www` serves built-in status page, `HTTP` includes headers). |
| `PORT` | `4433` | TCP port `s_server` listens on. |
| `CA_CURVE` | `prime256v1` | Elliptic curve for CA key. |
| `SERVER_CURVE` | `prime256v1` | Elliptic curve for Server key. |
| `CURVE` | `prime256v1` | Fallback curve for both CA and Server if not individually set. |
| `CA_SUBJECT` | `/CN=Test OpenSSL CA/O=Test Lab/C=CA` | X.509 subject for CA. |
| `SERVER_SUBJECT` | `/CN=localhost/O=Test Lab/C=CA` | X.509 subject for Server cert. |
| `DOMAINS` | `tiny-key-s-server.jskw.dev,localhost` | Comma- or space-separated list of DNS SANs. |
| `IPS` | `127.0.0.1` | Comma- or space-separated list of IP SANs. |
| `CA_DAYS` | `3650` | Validity period (in days) for CA certificate. |
| `SERVER_DAYS` | `365` | Validity period (in days) for Server certificate. |
| `CERTS_DIR` | `/certs` | Directory checked for mounted certificates and keys. |
| `EXTRA_S_SERVER_ARGS` | *empty* | Additional CLI flags passed directly to `openssl s_server`. |

---

## Test Suites

All tests are designed to execute cleanly inside ephemeral Docker containers without modifying the host system:

- [`tests/test_scalar_s_bytes.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_scalar_s_bytes.sh): Tests scalar generation and verifies that `openssl ec -text` displays the exact user hex.
- [`tests/test_chain_generation.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_chain_generation.sh): Tests CA creation, server CSR signing, SAN injection, and `openssl verify`.
- [`tests/test_s_server_behavior.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_s_server_behavior.sh): Tests `-WWW` and `-www` response semantics with `curl`.
- [`tests/test_volume_override.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_volume_override.sh): Tests mounting an external volume containing pre-existing certificates.
- [`tests/test_full_docker_app.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_full_docker_app.sh): Full end-to-end integration test of the built image.
- [`tests/test_cross_signed_chains.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_cross_signed_chains.sh): Tests intermediate cross-signing ($a \rightarrow b \rightarrow c_1 / c_2$) and multi-trust-anchor client verification.
- [`tests/test_chain_modes.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_chain_modes.sh): Tests runtime `CHAIN_MODE` path resolution (`default`, named path `c1`, and `all`).
- [`tests/test_multi_port_server.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_multi_port_server.sh): Tests dynamic multi-root derivation (`ROOTS=c1,c2`), companion `s_server` listeners, and single vs multi-chain port allocation.
- [`tests/run_all_tests.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/run_all_tests.sh): Orchestrates all test scripts.

To run all tests:
```bash
./tests/run_all_tests.sh
```

---

## Kubernetes & Helm Chart

A Helm chart is located in `chart/`:

```bash
helm upgrade --install tiny-key-s-server ./chart \
  --set env.DOMAINS="tiny-key-s-server.jskw.dev,localhost" \
  --set ingress.enabled=true \
  --set ingress.hosts[0]=tiny-key-s-server.jskw.dev
```

Continuous deployment is handled by ArgoCD manifests in `argocd/`:
- `argocd/main-application.yaml`: Production release application tracking the `main` branch / version tags.
- `argocd/pr-applicationset.yaml`: Pull request preview environments dynamically provisioned for Gitea PRs.
