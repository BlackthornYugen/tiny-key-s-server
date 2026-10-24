#!/usr/bin/env python3
"""
Utility script to create a Pull Request on Gitea for webapps/tiny-key-s-server.

Usage:
    ./scripts/create_pr.py
    ./scripts/create_pr.py -t "PR Title" -b "PR Description"
    ./scripts/create_pr.py --head feat/my-branch --base main -t "My PR"
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT_DIR / ".env"

def get_current_branch():
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=str(ROOT_DIR),
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return out
    except Exception:
        return "feat/utility-scripts"

def get_latest_commit_title():
    try:
        out = subprocess.check_output(
            ["git", "log", "-1", "--format=%s"],
            cwd=str(ROOT_DIR),
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return out
    except Exception:
        return "Update"

def load_env():
    env = {}
    if ENV_FILE.exists():
        with open(ENV_FILE, "r") as env_file:
            for line in env_file:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    env[key.strip()] = value.strip().strip("\"'")
    return env

def main():
    parser = argparse.ArgumentParser(description="Create a Pull Request on Gitea")
    parser.add_argument("-t", "--title", help="PR title (default: latest commit subject)")
    parser.add_argument("-b", "--body", help="PR body/description")
    parser.add_argument("--head", help="Head branch (default: current git branch)")
    parser.add_argument("--base", default="main", help="Base branch (default: main)")
    args = parser.parse_args()

    env = load_env()
    token = env.get("GITEA_TOKEN")
    if not token:
        print("Error: GITEA_TOKEN not found in .env", file=sys.stderr)
        sys.exit(1)

    head_branch = args.head or get_current_branch()
    base_branch = args.base
    title = args.title or get_latest_commit_title()
    body = args.body or f"Pull request for branch `{head_branch}` merging into `{base_branch}`."

    api_url = "https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server/pulls"
    headers = {
        "Authorization": f"token {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    payload = {
        "base": base_branch,
        "head": head_branch,
        "title": title,
        "body": body,
    }

    req = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            pr_num = data.get("number")
            pr_url = data.get("html_url")
            print(f"Successfully created PR #{pr_num}: {pr_url}")
    except urllib.error.HTTPError as http_error:
        error_body = http_error.read().decode()
        if http_error.code == 409:
            print(f"Notice: A pull request for '{head_branch}' -> '{base_branch}' may already exist.")
            # Try to fetch existing PR
            try:
                list_req = urllib.request.Request(f"{api_url}?state=open", headers=headers)
                with urllib.request.urlopen(list_req) as list_response:
                    pulls = json.loads(list_response.read().decode())
                    for pull in pulls:
                        if pull.get("head", {}).get("ref") == head_branch:
                            print(f"Existing PR #{pull.get('number')}: {pull.get('html_url')}")
                            return
            except Exception:
                pass
        print(f"Error ({http_error.code}): {error_body}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
