#!/usr/bin/env bash
set -euo pipefail

# Source environment variables for Gitea authentication
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

GITEA_REMOTE_URL="https://${GITEA_USER}:${GITEA_TOKEN}@git.tower.jskw.dev/webapps/tiny-key-s-server.git"

echo "=== Pushing branch '${BRANCH}' to Gitea (origin) ==="
# shellcheck disable=SC2086
git push ${FORCE_FLAG} "${GITEA_REMOTE_URL}" "${BRANCH}"
echo "Successfully pushed to Gitea!"

if [ "$PUSH_GITHUB" = true ]; then
  echo "=== Pushing branch '${BRANCH}' to GitHub (gh) ==="
  # shellcheck disable=SC2086
  git push ${FORCE_FLAG} gh "${BRANCH}"
  echo "Successfully pushed to GitHub!"
fi
