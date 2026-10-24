#!/usr/bin/env bash
set -euo pipefail

# Utility script to sync Gitea main branch to GitHub main branch and reconcile shadow PRs.
# Usage:
#   ./scripts/sync_mirror.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

BRANCH="${1:-main}"
GITEA_REMOTE_URL="https://${GITEA_USER}:${GITEA_TOKEN}@git.tower.jskw.dev/webapps/tiny-key-s-server.git"
GITHUB_REPO="BlackthornYugen/tiny-key-s-server"

echo "=== 1. Fetching latest '${BRANCH}' from Gitea (origin) ==="
git fetch "${GITEA_REMOTE_URL}" "${BRANCH}:${BRANCH}" --update-head-ok

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" = "$BRANCH" ]; then
  git reset --hard "${BRANCH}"
fi

LATEST_SHA="$(git rev-parse "${BRANCH}")"
echo "Latest Gitea '${BRANCH}' commit: ${LATEST_SHA}"

echo -e "\n=== 2. Pushing '${BRANCH}' to GitHub (gh) ==="
git push gh "${BRANCH}"
echo "Successfully synchronized '${BRANCH}' to GitHub!"

if command -v gh >/dev/null 2>&1; then
  echo -e "\n=== 3. Reconciling GitHub Pull Requests ==="
  python3 - <<'EOF'
import json
import subprocess
import urllib.request
import os

repo = "BlackthornYugen/tiny-key-s-server"
try:
    main_sha = subprocess.check_output(["git", "rev-parse", "main"], text=True).strip()
except Exception:
    main_sha = ""
token = os.environ.get("GITEA_TOKEN", "")

# 1. Fetch open PRs on GitHub
try:
    gh_out = subprocess.check_output(
        ["gh", "pr", "list", "--repo", repo, "--state", "open", "--json", "number,headRefName,headRefOid,title"],
        text=True
    )
    open_prs = json.loads(gh_out)
except Exception as e:
    print(f"Failed to query GitHub PRs: {e}")
    open_prs = []

if not open_prs:
    print("All GitHub pull requests are already merged or closed.")
else:
    # 2. Fetch closed/merged PRs from Gitea
    gitea_merged = {}
    try:
        req = urllib.request.Request(
            "https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server/pulls?state=closed",
            headers={"Authorization": f"token {token}", "Accept": "application/json"}
        )
        with urllib.request.urlopen(req) as resp:
            closed_prs = json.loads(resp.read().decode())
            for cp in closed_prs:
                if cp.get("merged") and cp.get("head", {}).get("ref"):
                    gitea_merged[cp["head"]["ref"]] = cp.get("merge_commit_sha") or main_sha
    except Exception as e:
        print(f"Notice: Could not fetch closed PRs from Gitea API: {e}")

    # 3. Check each open GitHub PR
    for pr in open_prs:
        pr_num = pr["number"]
        branch = pr["headRefName"]
        head_sha = pr.get("headRefOid", "")

        merged_sha = gitea_merged.get(branch)

        # Also check git ancestry if branch head_sha is in main
        if not merged_sha and head_sha and main_sha:
            try:
                subprocess.check_call(
                    ["git", "merge-base", "--is-ancestor", head_sha, main_sha],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                merged_sha = main_sha
            except subprocess.CalledProcessError:
                pass

        if merged_sha:
            commit_url = f"https://github.com/{repo}/commit/{merged_sha}"
            close_comment = (
                f"Merged upstream in Gitea commit [`{merged_sha[:8]}`]({commit_url}).\n\n"
                f"This pull request has been automatically closed because the underlying changes were merged into `main`."
            )
            print(f"Closing GitHub PR #{pr_num} (branch '{branch}') merged in commit {merged_sha[:8]}...")
            try:
                subprocess.check_call([
                    "gh", "pr", "close", str(pr_num),
                    "--repo", repo,
                    "--comment", close_comment
                ])
                print(f"Successfully closed GitHub PR #{pr_num}!")
            except Exception as e:
                print(f"Notice: {e}")
        else:
            print(f"GitHub PR #{pr_num} ('{branch}') is still open and unmerged on Gitea.")
EOF
fi
