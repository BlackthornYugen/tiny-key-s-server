#!/usr/bin/env bash
set -euo pipefail

# Test endpoints for tiny-key-s-server deployment
PR_NUM="${1:-1}"
PORT="${2:-8443}"

if [ "$PORT" = "443" ]; then
  CURL_PORT_SUFFIX=""
else
  CURL_PORT_SUFFIX=":${PORT}"
fi

BASE_HOST="pr-${PR_NUM}-tiny-key-s-server.jskw.dev"

echo "=== 1. Testing Default Ingress UI (curl) ==="
echo "URL: https://${BASE_HOST}${CURL_PORT_SUFFIX}/index.html"
curl -s -k --max-time 5 "https://${BASE_HOST}${CURL_PORT_SUFFIX}/index.html" | head -n 12 || echo "Failed to connect to default UI"

for chain in "c1" "c2" "all"; do
  CHAIN_HOST="pr-${PR_NUM}-${chain}-tiny-key-s-server.jskw.dev"
  echo -e "\n=== 2. Testing Chain '${chain}' (s_client) ==="
  echo "Host: ${CHAIN_HOST}:${PORT}"
  echo "Q" | openssl s_client -connect "${CHAIN_HOST}:${PORT}" -servername "${CHAIN_HOST}" -showcerts 2>&1 | grep -E "depth=|s:|i:" || echo "Failed to connect to ${CHAIN_HOST}"
done
