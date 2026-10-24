#!/usr/bin/env bash
set -euo pipefail

# Quick inspection of tiny-key-s-server deployments, pods, and ingresses
TARGET="${1:-1}"
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  APP_NAME="tiny-key-s-server-pr-${TARGET}"
  NS="tiny-key-s-server-pr-${TARGET}"
elif [[ "$TARGET" =~ ^pr-[0-9]+$ ]]; then
  APP_NAME="tiny-key-s-server-${TARGET}"
  NS="tiny-key-s-server-${TARGET}"
else
  APP_NAME="tiny-key-s-server-main"
  NS="tiny-key-s-server"
fi

echo "=== ArgoCD Application ($APP_NAME) ==="
kubectl get application "$APP_NAME" -n argocd -o wide 2>/dev/null || echo "No application found for $APP_NAME"

echo -e "\n=== Pods in Namespace $NS ==="
kubectl get pods -n "$NS" -o wide 2>/dev/null || echo "No pods in $NS"

echo -e "\n=== Ingresses in Namespace $NS ==="
kubectl get ingress -n "$NS" -o wide 2>/dev/null || echo "No ingresses in $NS"

echo -e "\n=== Services and Endpoints in Namespace $NS ==="
kubectl get svc,endpoints -n "$NS" 2>/dev/null || echo "No services/endpoints in $NS"
