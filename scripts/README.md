# Utility Scripts

This directory contains utility scripts for managing builds, monitoring CI/CD, inspecting Kubernetes preview deployments, and verifying TLS endpoints for `tiny-key-s-server`.

---

## Available Scripts

### 1. `push_branch.sh`
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

### 2. `sync_mirror.sh`
Fetches the latest `main` (or specified branch) from Gitea (`origin`) and pushes it directly to GitHub (`gh`), ensuring the GitHub mirror and any shadow PRs update immediately.

**Usage:**
```bash
# Sync main branch from Gitea to GitHub
./scripts/sync_mirror.sh

# Sync specific branch
./scripts/sync_mirror.sh my-branch
```

---

### 2. `create_pr.py`
Creates a Pull Request on Gitea via the API for the current (or specified) branch, reading credentials from `.env`.

**Usage:**
```bash
# Create PR for current branch into main using latest commit message
./scripts/create_pr.py

# Create PR with custom title and description
./scripts/create_pr.py -t "feat(chart): add mitmproxy sidecar" -b "PR description..."

# Create PR specifying head and base branch
./scripts/create_pr.py --head feat/my-branch --base main -t "My PR"
```

---

### 3. `comment_pr.py`
Posts a markdown comment to a Gitea Pull Request (or issue) by PR number, reading credentials from `.env`.

**Usage:**
```bash
# Post comment using inline text
./scripts/comment_pr.py 1 -b "PR Review Notes..."

# Post comment from a markdown file
./scripts/comment_pr.py 1 -f review_comment.md

# Pipe comment from another command or stdin
cat review_comment.md | ./scripts/comment_pr.py 1
```

---

### 3. `toggle_pr_sync.sh`
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

### 4. `check_ci.py`
Queries the Gitea Actions API to display recent workflow runs and their build status without printing tokens or running large inline commands.

**Usage:**
```bash
# List 5 most recent runs
./scripts/check_ci.py

# List 10 most recent runs
./scripts/check_ci.py -n 10

# Inspect specific run details and job step logs
./scripts/check_ci.py 136
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

- **`.env`**: Required by `push_branch.sh`, `create_pr.py`, and `check_ci.py` for `GITEA_USER` and `GITEA_TOKEN`.
- **`kubectl`**: Required by `check_cluster.sh`.
- **`curl` & `openssl`**: Required by `test_endpoints.sh`.
- **`python3`**: Standard Python 3 standard library (no third-party dependencies required).
