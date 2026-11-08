---
name: git-mirror-sync
description: >-
  Manage multi-remote git branches and synchronize Gitea and GitHub mirrors.
  Use when the user asks to push branches to Gitea or GitHub, synchronize main/feature branches
  between remotes, or reconcile and close shadow GitHub PRs merged upstream in Gitea.
---

# Git Multi-Remote Mirror & Branch Synchronization

This skill provides step-by-step procedures to maintain synchronization across dual Git remotes:
- **Primary Remote (Gitea / `origin`)**: Where development and canonical merges occur.
- **Mirror Remote (GitHub / `gh`)**: Public or shadow mirror repository where shadow PRs and releases are tracked.

---

## Workflows and Procedures

### 1. Push Branch to Gitea (and GitHub)
Pushes the active branch (or specified branch) with credentials loaded from `.env`. By default it pushes to Gitea (`origin`). Pass `--github` or `--all` to mirror immediately to GitHub.

```bash
# Push current branch to Gitea only
./scripts/push_branch.sh

# Push specific branch to Gitea only
./scripts/push_branch.sh feat/my-branch

# Push branch to both Gitea and GitHub
./scripts/push_branch.sh feat/my-branch --github

# Force push if rebasing
./scripts/push_branch.sh feat/my-branch --force
```

**Script reference**: [push_branch.sh](./scripts/push_branch.sh)

---

### 2. Synchronize Mirror & Reconcile Shadow PRs
When a PR is merged into `main` on Gitea:
1. Fetches the latest `main` (or specified branch) from Gitea.
2. Fast-forwards the local branch.
3. Pushes the updated branch to GitHub (`gh`).
4. Reconciles open GitHub PRs: Queries open PRs on GitHub, checks if their commits or branches are merged upstream in Gitea, and automatically closes them with an informative merge comment.

```bash
# Synchronize main branch and reconcile shadow PRs
./scripts/sync_mirror.sh

# Synchronize a specific branch
./scripts/sync_mirror.sh my-feature-branch
```

**Script reference**: [sync_mirror.sh](./scripts/sync_mirror.sh)

---

## Prerequisites & Environment Variables

- **`.env`**: Must define `GITEA_USER` and `GITEA_TOKEN` for authenticated pushes and API reconciliation.
- **`gh` CLI**: Installed and authenticated to GitHub for PR reconciliation.
- **Git Remotes**:
  - `origin`: Points to the Gitea repository (e.g. `https://git.tower.jskw.dev/...`).
  - `gh`: Points to the GitHub repository (e.g. `https://github.com/...`).

