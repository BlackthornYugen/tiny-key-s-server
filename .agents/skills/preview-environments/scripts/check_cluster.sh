#!/usr/bin/env bash
set -euo pipefail

# Quick inspection of preview deployments, pods, and ingresses
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

TARGET="${1:-1}"

# Auto-detect base application name: env var -> chart/Chart.yaml -> repository folder name
if [ -n "${APP_BASE_NAME:-}" ]; then
  BASE_NAME="$APP_BASE_NAME"
elif [ -f "${ROOT_DIR}/chart/Chart.yaml" ] && grep -q "^name:" "${ROOT_DIR}/chart/Chart.yaml"; then
  BASE_NAME="$(grep "^name:" "${ROOT_DIR}/chart/Chart.yaml" | head -n1 | awk '{print $2}' | tr -d '"'\''')"
else
  BASE_NAME="$(basename "$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null || pwd)")"
fi

ARGOCD_NS="${ARGOCD_NAMESPACE:-argocd}"

if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  APP_NAME="${BASE_NAME}-pr-${TARGET}"
  NS="${BASE_NAME}-pr-${TARGET}"
elif [[ "$TARGET" =~ ^pr-[0-9]+$ ]]; then
  APP_NAME="${BASE_NAME}-${TARGET}"
  NS="${BASE_NAME}-${TARGET}"
else
  APP_NAME="${BASE_NAME}-main"
  NS="${BASE_NAME}"
fi

echo "=== ArgoCD Application ($APP_NAME) ==="
kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o wide 2>/dev/null || echo "No application found for $APP_NAME in namespace $ARGOCD_NS"

echo -e "\n=== Pods in Namespace $NS ==="
kubectl get pods -n "$NS" -o wide 2>/dev/null || echo "No pods in $NS"

echo -e "\n=== Ingresses in Namespace $NS ==="
kubectl get ingress -n "$NS" -o wide 2>/dev/null || echo "No ingresses in $NS"

echo -e "\n=== Services and Endpoints in Namespace $NS ==="
kubectl get svc,endpoints -n "$NS" 2>/dev/null || echo "No services/endpoints in $NS"
