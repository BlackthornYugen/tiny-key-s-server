#!/usr/bin/env python3
"""
Utility script to post a comment on a Pull Request (or Issue) on Gitea for webapps/tiny-key-s-server.

Usage:
    ./scripts/comment_pr.py 1 -b "Comment text"
    ./scripts/comment_pr.py 1 -f comment.md
    cat comment.md | ./scripts/comment_pr.py 1
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT_DIR / ".env"

def load_env():
    env = {}
    if ENV_FILE.exists():
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env[k.strip()] = v.strip().strip("\"'")
    return env

def main():
    parser = argparse.ArgumentParser(description="Post a comment on a Gitea Pull Request")
    parser.add_argument("pr_number", type=int, nargs="?", default=1, help="PR or issue number (default: 1)")
    parser.add_argument("-b", "--body", help="Comment body text")
    parser.add_argument("-f", "--file", help="Path to markdown file containing comment body")
    args = parser.parse_args()

    env = load_env()
    token = env.get("GITEA_TOKEN")
    if not token:
        print("Error: GITEA_TOKEN not found in .env", file=sys.stderr)
        sys.exit(1)

    comment_text = ""
    if args.body:
        comment_text = args.body
    elif args.file:
        with open(args.file, "r") as f:
            comment_text = f.read()
    elif not sys.stdin.isatty():
        comment_text = sys.stdin.read()
    else:
        print("Error: No comment body provided. Use -b, -f, or pipe via stdin.", file=sys.stderr)
        sys.exit(1)

    if not comment_text.strip():
        print("Error: Comment body is empty.", file=sys.stderr)
        sys.exit(1)

    api_url = f"https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server/issues/{args.pr_number}/comments"
    headers = {
        "Authorization": f"token {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    payload = {"body": comment_text}

    req = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode())
            comment_id = data.get("id")
            html_url = data.get("html_url")
            print(f"Successfully posted comment on PR #{args.pr_number} (ID: {comment_id})")
            if html_url:
                print(f"URL: {html_url}")
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        print(f"Error ({e.code}): {error_body}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
