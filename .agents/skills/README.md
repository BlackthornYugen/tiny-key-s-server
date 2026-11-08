# Workspace Skills & Global Installation

This directory contains reusable Antigravity skills that can be used locally in this repository or installed globally across all projects on this machine.

---

## Included Skills

- **[`preview-environments`](./preview-environments/SKILL.md)**: Manages dynamic PR preview environments on Kubernetes deployed via ArgoCD and Helm.
  - Inspects pods, services, ingresses, and ArgoCD application status (`check_cluster.sh`).
  - Pauses ArgoCD auto-sync and adopts resources for manual Helm upgrades (`toggle_pr_sync.sh`).
  - Tests UI endpoints and OpenSSL s_client SNI certificate chains (`test_endpoints.sh`).
- **[`git-mirror-sync`](./git-mirror-sync/SKILL.md)**: Manages multi-remote git synchronization between primary upstream (Gitea) and mirror (GitHub).
  - Pushes branches with credential injection to Gitea and GitHub (`push_branch.sh`).
  - Fast-forwards mirror branches and automatically closes merged GitHub shadow PRs (`sync_mirror.sh`).

---

## Installing Globally via Symlinks

All scripts in these skills use dynamic auto-detection (`PROJECT_ROOT`, git remotes, and `chart/Chart.yaml`), meaning they automatically adapt to whatever repository is active when invoked by Antigravity.

To share these skills across all projects without copying files:

### Method A: Standalone Global Skills (Recommended)

Link each skill directly into the global skills directory:

```bash
# 1. Ensure the global skills directory exists
mkdir -p ~/.gemini/config/skills

# 2. Symlink the skills (run from this repository root)
ln -sf "$(pwd)/.agents/skills/preview-environments" ~/.gemini/config/skills/preview-environments
ln -sf "$(pwd)/.agents/skills/git-mirror-sync" ~/.gemini/config/skills/git-mirror-sync
```

### Method B: Symlink into a Global Plugin

If you use the `gitea` plugin (or another global plugin under `~/.gemini/config/plugins/`), you can mount them into that plugin's `skills/` folder:

```bash
mkdir -p ~/.gemini/config/plugins/gitea/skills

ln -sf "$(pwd)/.agents/skills/preview-environments" ~/.gemini/config/plugins/gitea/skills/preview-environments
ln -sf "$(pwd)/.agents/skills/git-mirror-sync" ~/.gemini/config/plugins/gitea/skills/git-mirror-sync
```

---

## Verifying Global Installation

1. Reload your IDE window or start a new chat session.
2. In any project workspace, ask Antigravity:
   > *"What skills do you have for preview environments or git mirroring?"*
3. The agent will discover and list them automatically.

---

## Uninstalling / Unlinking

To remove global access:

```bash
rm -f ~/.gemini/config/skills/preview-environments
rm -f ~/.gemini/config/skills/git-mirror-sync
```

