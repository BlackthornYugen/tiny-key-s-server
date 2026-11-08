#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PUSH_GITHUB=false
FORCE_FLAG=""
BRANCH=""

for arg in "$@"; do
  case "$arg" in
    --github|--all)
      PUSH_GITHUB=true
      ;;
    --force|-f)
      FORCE_FLAG="--force"
      ;;
    *)
      if [ -z "$BRANCH" ]; then
        BRANCH="$arg"
      fi
      ;;
  esac
done

if [ -z "$BRANCH" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

# Determine Gitea remote URL:
# If GITEA_USER & GITEA_TOKEN are present, embed them into the origin remote URL
if [ -n "${GITEA_REMOTE_URL:-}" ]; then
  TARGET_GITEA_URL="$GITEA_REMOTE_URL"
elif [ -n "${GITEA_USER:-}" ] && [ -n "${GITEA_TOKEN:-}" ]; then
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || echo "")"
  CLEAN_URL="$(echo "$ORIGIN_URL" | sed -E 's|^https?://([^@]+@)?||')"
  if [ -n "$CLEAN_URL" ]; then
    TARGET_GITEA_URL="https://${GITEA_USER}:${GITEA_TOKEN}@${CLEAN_URL}"
  else
    TARGET_GITEA_URL="origin"
  fi
else
  TARGET_GITEA_URL="origin"
fi

echo "=== Pushing branch '${BRANCH}' to Gitea (origin) ==="
# shellcheck disable=SC2086
git push ${FORCE_FLAG} "${TARGET_GITEA_URL}" "${BRANCH}"
echo "Successfully pushed to Gitea!"

if [ "$PUSH_GITHUB" = true ]; then
  echo "=== Pushing branch '${BRANCH}' to GitHub (gh) ==="
  # shellcheck disable=SC2086
  git push ${FORCE_FLAG} gh "${BRANCH}"
  echo "Successfully pushed to GitHub!"
fi
