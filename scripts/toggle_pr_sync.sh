#!/usr/bin/env bash
# ==============================================================================
# Utility to enable or disable ArgoCD auto-sync for a PR preview application
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <PR_NUMBER> [disable|enable|status]"
  echo "Example:"
  echo "  $0 2 disable   # Disable auto-sync on PR #2 and initialize Helm release for clean --reuse-values upgrades"
  echo "  $0 2 enable    # Re-enable auto-sync on PR #2"
  echo "  $0 2 status    # Check current sync status on PR #2"
  exit 1
fi

PR_NUM="$1"
ACTION="${2:-toggle}"
APP_NAME="tiny-key-s-server-pr-${PR_NUM}"
APP_SET="tiny-key-s-server-prs"
NAMESPACE="argocd"

# Verify kubectl connection and application existence
if ! kubectl get application "${APP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Error: Application '${APP_NAME}' not found in namespace '${NAMESPACE}'."
  exit 1
fi

# Ensure ApplicationSet ignores syncPolicy differences so it doesn't overwrite manual toggles
ensure_appset_ignore_differences() {
  local current_ignore
  current_ignore=$(kubectl get applicationset "${APP_SET}" -n "${NAMESPACE}" -o jsonpath='{.spec.ignoreApplicationDifferences}' 2>/dev/null || echo "")
  if [[ "$current_ignore" != *"/spec/syncPolicy"* ]]; then
    echo ">> Configuring ApplicationSet '${APP_SET}' to ignore syncPolicy changes..."
    kubectl patch applicationset "${APP_SET}" -n "${NAMESPACE}" --type=merge -p '{
      "spec": {
        "ignoreApplicationDifferences": [
          {
            "jsonPointers": ["/spec/syncPolicy"]
          }
        ]
      }
    }' >/dev/null
    echo ">> ApplicationSet updated successfully."
  fi
}

get_target_namespace() {
  kubectl get application "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || echo "tiny-key-s-server-pr-${PR_NUM}"
}

init_helm_release_record() {
  local target_ns
  target_ns=$(get_target_namespace)
  
  echo ">> Extracting existing deployment parameters from ArgoCD Application '${APP_NAME}'..."
  local helm_set_args
  helm_set_args=$(python3 -c '
import sys, json, subprocess

app = sys.argv[1]
ns = sys.argv[2]
try:
    raw = subprocess.check_output(["kubectl", "get", "application", app, "-n", ns, "-o", "jsonpath={.spec.source.helm.parameters}"]).decode().strip()
    if raw:
        params = json.loads(raw)
        args = []
        for param in params:
            name = param.get("name")
            val = param.get("value")
            if name and val is not None:
                args.append(f"--set \"{name}={val}\"")
        print(" ".join(args))
except Exception:
    pass
' "${APP_NAME}" "${NAMESPACE}")

  echo ">> Adopting existing resources into Helm release tracking (enabling --reuse-values)..."
  local chart_dir="${ROOT_DIR}/chart"
  eval "helm upgrade --install \"${APP_NAME}\" \"${chart_dir}\" -n \"${target_ns}\" --take-ownership ${helm_set_args}" >/dev/null
  echo ">> Helm release record initialized in namespace '${target_ns}'."
}

get_current_sync() {
  kubectl get application "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || echo ""
}

current_automated=$(get_current_sync)

if [ "$ACTION" = "status" ]; then
  if [ -n "$current_automated" ]; then
    echo "Sync Status for ${APP_NAME}: ENABLED (automated: ${current_automated})"
  else
    echo "Sync Status for ${APP_NAME}: DISABLED (manual / paused)"
  fi
  exit 0
fi

if [ "$ACTION" = "toggle" ]; then
  if [ -n "$current_automated" ]; then
    ACTION="disable"
  else
    ACTION="enable"
  fi
fi

case "$ACTION" in
  disable)
    ensure_appset_ignore_differences
    echo ">> Disabling automated sync for '${APP_NAME}'..."
    kubectl patch application "${APP_NAME}" -n "${NAMESPACE}" --type=merge -p '{"spec":{"syncPolicy":null}}'
    init_helm_release_record
    target_ns=$(get_target_namespace)
    echo ""
    echo "=========================================================================================="
    echo " Auto-sync DISABLED for '${APP_NAME}'"
    echo " Existing parameters adopted into Helm. You can now run clean upgrade commands:"
    echo ""
    echo "   helm upgrade ${APP_NAME} ./chart -n ${target_ns} --reuse-values --set mitmproxy.enabled=true"
    echo "   helm upgrade ${APP_NAME} ./chart -n ${target_ns} --reuse-values --set mitmproxy.serverCa.chainMode=c1"
    echo "=========================================================================================="
    ;;
  enable)
    echo ">> Enabling automated sync for '${APP_NAME}'..."
    kubectl patch application "${APP_NAME}" -n "${NAMESPACE}" --type=merge -p '{
      "spec": {
        "syncPolicy": {
          "automated": {
            "prune": true,
            "selfHeal": true
          },
          "syncOptions": ["CreateNamespace=true"]
        }
      }
    }'
    echo "Successfully ENABLED automated sync for '${APP_NAME}'."
    ;;
  *)
    echo "Unknown action '$ACTION'. Use 'disable', 'enable', or 'status'."
    exit 1
    ;;
esac
