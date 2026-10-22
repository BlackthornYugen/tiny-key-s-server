# OpenSSL `s_server` Testing Tool

A lightweight, automated containerized testing tool powered by Alpine Linux and OpenSSL `s_server`.

It generates a two-tier Elliptic Curve (EC) certificate chain (CA + Server), signs the server certificate with custom SAN extensions (IPs and domain names), captures and echoes all executed OpenSSL commands, and serves a live HTML report explaining how the certificate and key were created while running in `-WWW` or `-www` mode.

---

## Features

- **Dynamic EC Key & Chain Generation**: Generates a CA key & certificate, a server key & CSR, signs the server certificate using the CA with Subject Alternative Names (SANs), and bundles them into `fullchain.pem`.
- **Flexible Entropy/Seed Input**: Accepts a small integer (e.g. `42`) or a hex string (e.g. `0xdeadbeef` or `deadbeef...`) as seed bytes for reproducible testing.
- **Configurable via Environment Variables**:
  - Curves: `CA_CURVE`, `SERVER_CURVE`, or fallback `CURVE` (e.g., `prime256v1`, `secp384r1`, `secp521r1`).
  - Subjects: `CA_SUBJECT` and `SERVER_SUBJECT`.
  - SANs: `DOMAINS` and `IPS` (comma or space separated).
  - Modes: `WWW_MODE` (`WWW`, `www`, `HTTP`).
  - Ports: `PORT` (default `4433`).
- **Mounted Volume Support**: Automatically detects if pre-existing certificate chains (e.g., `fullchain.pem`, `tls.crt`) and private keys are mounted to `/certs`, serving those instead.
- **Interactive HTML Audit Page**: Echoes all commands executed with exit codes, parameters, and decoded certificate details (`openssl x509 -text -noout`). In `-WWW` mode, visiting `https://<host>:<port>/index.html` renders this full report with one-click PEM file downloads.
- **Helm Chart & ArgoCD Integration**: Production-ready Helm chart (`chart/`) and ArgoCD Application (`argocd/`) matching Gitea CI/CD pipelines.

---

## Quick Start

### 1. Run with Default Settings (Random Entropy)

```bash
docker run -p 4433:4433 git.tower.jskw.dev/webapps/s-server-tester:latest
```

### 2. Run with Integer Seed

```bash
docker run -p 4433:4433 \
  -e SEED="42" \
  -e DOMAINS="localhost,test.internal" \
  -e IPS="127.0.0.1,192.168.1.100" \
  s-server-tester:latest
```

### 3. Run with Hex Seed and Custom Curves

```bash
docker run -p 4433:4433 \
  -e SEED_BYTES="0xdeadbeef01020304" \
  -e CA_CURVE="secp384r1" \
  -e SERVER_CURVE="prime256v1" \
  -e SERVER_SUBJECT="/CN=my-service.local/O=Testing/C=US" \
  s-server-tester:latest
```

### 4. Run with Mounted Volume Override

If you have pre-generated certificates (such as Let's Encrypt or Vault certs):

```bash
docker run -p 4433:4433 \
  -v /path/to/my/certs:/certs:ro \
  s-server-tester:latest
```
When `fullchain.pem` (or `tls.crt`) and `privkey.pem` (or `tls.key` / `server.key`) are present in `/certs`, the container inspects and serves them directly without generating new certificates.

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
| `SEED` / `SEED_BYTES` | *empty* | Small int (e.g. `42`) or hex string (`deadbeef...`) to seed key generation. |
| `WWW_MODE` | `WWW` | Mode for `openssl s_server` (`WWW` serves files, `www` serves built-in status page, `HTTP` includes headers). |
| `PORT` | `4433` | TCP port `s_server` listens on. |
| `CA_CURVE` | `prime256v1` | Elliptic curve for CA key. |
| `SERVER_CURVE` | `prime256v1` | Elliptic curve for Server key. |
| `CURVE` | `prime256v1` | Fallback curve for both CA and Server if not individually set. |
| `CA_SUBJECT` | `/CN=Test OpenSSL CA/O=Test Lab/C=US` | X.509 subject for CA. |
| `SERVER_SUBJECT` | `/CN=localhost/O=Test Lab/C=US` | X.509 subject for Server cert. |
| `DOMAINS` | `localhost` | Comma- or space-separated list of DNS SANs. |
| `IPS` | `127.0.0.1` | Comma- or space-separated list of IP SANs. |
| `CA_DAYS` | `3650` | Validity period (in days) for CA certificate. |
| `SERVER_DAYS` | `365` | Validity period (in days) for Server certificate. |
| `CERTS_DIR` | `/certs` | Directory checked for mounted certificates and keys. |
| `EXTRA_S_SERVER_ARGS` | *empty* | Additional CLI flags passed directly to `openssl s_server`. |

---

## Test Suites

All tests are designed to execute cleanly inside ephemeral Docker containers without modifying the host system:

- [`tests/test_seed_keys.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_seed_keys.sh): Tests seed processing (both integer and hex string) and EC key generation.
- [`tests/test_chain_generation.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_chain_generation.sh): Tests CA creation, server CSR signing, SAN injection, and `openssl verify`.
- [`tests/test_s_server_behavior.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_s_server_behavior.sh): Tests `-WWW` and `-www` response semantics with `curl`.
- [`tests/test_volume_override.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_volume_override.sh): Tests mounting an external volume containing pre-existing certificates.
- [`tests/test_full_docker_app.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/test_full_docker_app.sh): Full end-to-end integration test of the built image.
- [`tests/run_all_tests.sh`](file:///Users/jsteel/Documents/antigravity/optimistic-bohr/tests/run_all_tests.sh): Orchestrates all test scripts.

To run all tests:
```bash
./tests/run_all_tests.sh
```

---

## Kubernetes & Helm Chart

A Helm chart is located in `chart/`:

```bash
helm upgrade --install s-server ./chart \
  --set env.DOMAINS="s-server.jskw.dev,localhost" \
  --set ingress.enabled=true \
  --set ingress.hosts[0]=s-server.jskw.dev
```

Continuous deployment is handled by ArgoCD manifests in `argocd/`:
- `argocd/main-application.yaml`: Production release application tracking the `main` branch / version tags.
- `argocd/pr-applicationset.yaml`: Pull request preview environments dynamically provisioned for Gitea PRs.
