---
name: preview-environments
description: >-
  Inspect, test, and manage Kubernetes preview environments deployed via ArgoCD and Helm.
  Use when the user asks to check preview deployments, pods, ingresses, services, toggle
  ArgoCD automated sync for testing manual Helm upgrades, or verify TLS endpoints and certificate chains.
---

# Kubernetes Preview Environments Management

This skill provides step-by-step workflows for managing dynamic Pull Request (PR) preview environments deployed on Kubernetes using ArgoCD and Helm.

## Architecture Overview

For each open PR:
- **ArgoCD Application**: Named `<app>-pr-<pr_number>` under namespace `argocd` (managed by an `ApplicationSet`).
- **Namespace**: Deployed in `<app>-pr-<pr_number>`.
- **Endpoints**:
  - Main UI: `https://pr-<pr_number>-<app>.<domain>:<port>/index.html` (Cluster wildcard certificate).
  - SSL-Passthrough Ingresses: `pr-<pr_number>-<chain>-<app>.<domain>:<port>` for custom TLS certificate verification (`c1`, `c2`, `all` chains).

---

## Workflows and Procedures

### 1. Inspect Cluster Resources for a PR
Check the ArgoCD application status, pods, ingresses, and services for a given PR preview:

```bash
# Inspect resources for PR #1
./scripts/check_cluster.sh 1

# Inspect resources for PR #2
./scripts/check_cluster.sh 2

# Inspect main production release
./scripts/check_cluster.sh main
```

**Script reference**: [check_cluster.sh](./scripts/check_cluster.sh)

---

### 2. Test Manual Helm Upgrades on a Preview Environment
By default, ArgoCD auto-syncs from git, overwriting any manual `helm upgrade` or `kubectl` changes.

To test Helm parameter tweaks directly on a preview deployment without committing to Git:

#### Step A: Disable Auto-Sync & Adopt Parameters into Helm
Run the toggle script with `disable`. This patches the `ApplicationSet` to ignore `syncPolicy` changes, pauses auto-sync on the PR application, and initializes Helm release ownership:

```bash
./scripts/toggle_pr_sync.sh <PR_NUM> disable
```

#### Step B: Run Manual Helm Upgrades
You can now run `helm upgrade` with `--reuse-values` directly:

```bash
helm upgrade <app>-pr-<PR_NUM> ./chart -n <app>-pr-<PR_NUM> --reuse-values --set mitmproxy.enabled=true
```

#### Step C: Re-Enable Auto-Sync
Once testing is complete, restore ArgoCD automated synchronization:

```bash
./scripts/toggle_pr_sync.sh <PR_NUM> enable
```

#### Check Current Status
```bash
./scripts/toggle_pr_sync.sh <PR_NUM> status
```

**Script reference**: [toggle_pr_sync.sh](./scripts/toggle_pr_sync.sh)

---

### 3. Verify Endpoints and TLS Certificate Chains
Automate health checks against the preview domain:
1. `curl` checks against the default UI endpoint.
2. `openssl s_client` checks against the SSL-Passthrough ingress domains (`c1`, `c2`, `all`) to verify certificate chains, issuers, and subjects.

```bash
# Verify PR #1 endpoints (default port 8443)
./scripts/test_endpoints.sh 1

# Verify PR #2 endpoints on custom port
./scripts/test_endpoints.sh 2 8443
```

**Script reference**: [test_endpoints.sh](./scripts/test_endpoints.sh)

---

## Configuration & Environment Variables

The helper scripts auto-detect the base application name and domain, but can be overridden:
- `APP_BASE_NAME`: Base application name (defaults to `chart/Chart.yaml` `name:`, or repo directory name).
- `DOMAIN_SUFFIX`: Base domain (defaults to domain found in `chart/values.yaml` `hosts:` or `jskw.dev`).
- `ARGOCD_NAMESPACE`: ArgoCD namespace (defaults to `argocd`).

