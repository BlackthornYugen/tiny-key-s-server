#!/usr/bin/env bash
set -euo pipefail

# Cleans up orphaned tiny-key-s-server-main resources from namespace gitea
echo "=== Deleting legacy tiny-key-s-server-main resources from namespace 'gitea' ==="
kubectl delete deployment,svc,ingress -n gitea -l app=tiny-key-s-server-main --ignore-not-found

echo "=== Verifying removal from 'gitea' ==="
kubectl get deployment,svc,ingress -n gitea -l app=tiny-key-s-server-main || true
echo "Cleanup complete!"
