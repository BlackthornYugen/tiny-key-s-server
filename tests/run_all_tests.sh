#!/usr/bin/env bash
# Runs all test suites for the OpenSSL s_server testing tool
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo " Running All OpenSSL s_server Tester Test Suites"
echo "=========================================================="

echo ""
echo "--> 1. Running test_scalar_s_bytes.sh..."
"$SCRIPT_DIR/test_scalar_s_bytes.sh"

echo ""
echo "--> 2. Running test_chain_generation.sh..."
"$SCRIPT_DIR/test_chain_generation.sh"

echo ""
echo "--> 3. Running test_s_server_behavior.sh..."
"$SCRIPT_DIR/test_s_server_behavior.sh"

echo ""
echo "--> 4. Running test_volume_override.sh..."
"$SCRIPT_DIR/test_volume_override.sh"

echo ""
echo "--> 5. Running test_full_docker_app.sh..."
"$SCRIPT_DIR/test_full_docker_app.sh"

echo ""
echo "=========================================================="
echo " ALL TEST SUITES PASSED SUCCESSFULLY!"
echo "=========================================================="
