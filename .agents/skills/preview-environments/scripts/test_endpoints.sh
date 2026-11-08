#!/usr/bin/env bash
set -euo pipefail

# Test endpoints for preview deployment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

PR_NUM="${1:-1}"
PORT="${2:-8443}"

# Auto-detect base application name: env var -> chart/Chart.yaml -> repository folder name
if [ -n "${APP_BASE_NAME:-}" ]; then
  BASE_NAME="$APP_BASE_NAME"
elif [ -f "${ROOT_DIR}/chart/Chart.yaml" ] && grep -q "^name:" "${ROOT_DIR}/chart/Chart.yaml"; then
  BASE_NAME="$(grep "^name:" "${ROOT_DIR}/chart/Chart.yaml" | head -n1 | awk '{print $2}' | tr -d '"'\''')"
else
  BASE_NAME="$(basename "$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)")"
fi

# Detect domain: DOMAIN_SUFFIX env var -> parsed from chart/values.yaml -> default jskw.dev
if [ -n "${DOMAIN_SUFFIX:-}" ]; then
  BASE_DOMAIN="$DOMAIN_SUFFIX"
elif [ -f "${ROOT_DIR}/chart/values.yaml" ] && grep -E "hosts:" -A 2 "${ROOT_DIR}/chart/values.yaml" | grep -q "\- "; then
  FIRST_HOST="$(grep -E "hosts:" -A 2 "${ROOT_DIR}/chart/values.yaml" | grep "\- " | head -n1 | awk '{print $2}' | tr -d '"'\''')"
  BASE_DOMAIN="${FIRST_HOST#*.}"
else
  BASE_DOMAIN="jskw.dev"
fi

if [ "$PORT" = "443" ]; then
  CURL_PORT_SUFFIX=""
else
  CURL_PORT_SUFFIX=":${PORT}"
fi

BASE_HOST="pr-${PR_NUM}-${BASE_NAME}.${BASE_DOMAIN}"

echo "=== 1. Testing Default Ingress UI (curl) ==="
echo "URL: https://${BASE_HOST}${CURL_PORT_SUFFIX}/index.html"
curl -s -k --max-time 5 "https://${BASE_HOST}${CURL_PORT_SUFFIX}/index.html" | head -n 12 || echo "Failed to connect to default UI"

for chain in "c1" "c2" "all"; do
  CHAIN_HOST="pr-${PR_NUM}-${chain}-${BASE_NAME}.${BASE_DOMAIN}"
  echo -e "\n=== 2. Testing Chain '${chain}' (s_client) ==="
  echo "Host: ${CHAIN_HOST}:${PORT}"
  echo "Q" | openssl s_client -connect "${CHAIN_HOST}:${PORT}" -servername "${CHAIN_HOST}" -showcerts 2>&1 | grep -E "depth=|s:|i:" || echo "Failed to connect to ${CHAIN_HOST}"
done
