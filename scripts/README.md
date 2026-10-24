# Utility Scripts

This directory contains utility scripts for managing builds, monitoring CI/CD, inspecting Kubernetes preview deployments, and verifying TLS endpoints for `tiny-key-s-server`.

---

## Available Scripts

### 1. `giteactl.py` (Unified Gitea PR & CI Control)
Unified Python CLI utility using `typer`, `python-dotenv`, and `requests` with inline PEP 723 dependency metadata for `uv`. Consolidates creating PRs, checking/posting comments and code reviews, and monitoring CI runs into a single CLI tool.

**Usage:**
```bash
# View CLI help and available commands
uv run ./scripts/giteactl.py --help

# 1. Post a comment to a PR
uv run ./scripts/giteactl.py comment 3 --body "Looks great!"
uv run ./scripts/giteactl.py comment 3 --file comment.md
cat comment.md | uv run ./scripts/giteactl.py comment 3

# 2. Inspect comments and reviews on a PR
uv run ./scripts/giteactl.py comments 3
uv run ./scripts/giteactl.py comments --all

# 3. Monitor Gitea Actions CI workflow runs
uv run ./scripts/giteactl.py ci
uv run ./scripts/giteactl.py ci 153

# 4. Create a Pull Request
uv run ./scripts/giteactl.py create-pr --title "feat: my change" --body "PR details..."
```
*(Note: Because `./scripts/giteactl.py` has a `#!/usr/bin/env -S uv run` shebang, you can also execute it directly as `./scripts/giteactl.py <command>`.)*

---

### 2. `push_branch.sh`
Pushes the active branch (or a specified branch) to Gitea (`origin`) using credentials in `.env`. By default, it pushes only to Gitea. Pass `--github` or `--all` if you also need to mirror to GitHub (`gh`).

**Usage:**
```bash
# Push current branch to Gitea only
./scripts/push_branch.sh

# Push specific branch to Gitea only
./scripts/push_branch.sh feat/my-branch

# Push branch to both Gitea and GitHub
./scripts/push_branch.sh feat/my-branch --github
```

---

### 3. `sync_mirror.sh`
Fetches the latest `main` (or specified branch) from Gitea (`origin`) and pushes it directly to GitHub (`gh`), ensuring the GitHub mirror and any shadow PRs update immediately.

**Usage:**
```bash
# Sync main branch from Gitea to GitHub
./scripts/sync_mirror.sh

# Sync specific branch
./scripts/sync_mirror.sh my-branch
```

---

### 4. `toggle_pr_sync.sh`
Enables, disables, or checks ArgoCD automated synchronization for a PR preview application. Automatically configures the `ApplicationSet` to ignore `syncPolicy` changes so manual Helm upgrades aren't reverted.

**Usage:**
```bash
# Check current sync status
./scripts/toggle_pr_sync.sh 2 status

# Disable auto-sync so you can test manual 'helm upgrade' commands
./scripts/toggle_pr_sync.sh 2 disable

# Re-enable auto-sync
./scripts/toggle_pr_sync.sh 2 enable
```

---

### 5. `check_cluster.sh`
Performs a quick, non-destructive check of Kubernetes resources associated with a PR or deployment (ArgoCD application, pods, ingresses, and endpoints).

**Usage:**
```bash
# Inspect PR-1 resources
./scripts/check_cluster.sh 1

# Inspect main release
./scripts/check_cluster.sh main
```

---

### 6. `test_endpoints.sh`
Executes automated health checks against the preview domains:
1. `curl` against the default Ingress UI (verified with Let's Encrypt cluster wildcard certificate).
2. `openssl s_client` against the SSL-Passthrough ingresses (`c1`, `c2`, and `all`), verifying that the raw, custom-generated certificate chains are served correctly.

**Usage:**
```bash
# Test all endpoints for PR-1
./scripts/test_endpoints.sh 1

# Test all endpoints for PR-2
./scripts/test_endpoints.sh 2
```

---

### 7. `clean_legacy_gitea.sh`
Removes orphaned legacy main resources (`Deployment`, `Service`, `Ingress`) from namespace `gitea` after migrating to namespace `tiny-key-s-server`.

**Usage:**
```bash
./scripts/clean_legacy_gitea.sh
```

---

## Requirements

- **`.env`**: Required by `push_branch.sh` and `giteactl.py` for `GITEA_USER` and `GITEA_TOKEN`.
- **`uv`**: Required to run `giteactl.py` (`uv run ./scripts/giteactl.py` or `./scripts/giteactl.py`).
- **`kubectl`**: Required by `check_cluster.sh` and `toggle_pr_sync.sh`.
- **`curl` & `openssl`**: Required by `test_endpoints.sh`.
