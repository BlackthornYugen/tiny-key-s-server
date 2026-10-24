#!/usr/bin/env python3
"""
Utility script to check all comments and reviews on Gitea Pull Requests for webapps/tiny-key-s-server.

Usage:
    ./scripts/check_comments.py        # Checks comments and reviews on latest open PR
    ./scripts/check_comments.py 3      # Checks comments and reviews on PR #3
    ./scripts/check_comments.py --all  # Checks comments across all recent PRs
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
        with open(ENV_FILE, "r") as env_file:
            for line in env_file:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    env[key.strip()] = value.strip().strip("\"'")
    return env

def api_get(token, endpoint):
    url = f"https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server/{endpoint}"
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/json",
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as http_error:
        if http_error.code == 404:
            return []
        print(f"Error fetching {endpoint} ({http_error.code}): {http_error.read().decode()}", file=sys.stderr)
        return []
    except Exception as error:
        print(f"Error fetching {endpoint}: {error}", file=sys.stderr)
        return []

def get_prs(token, state="open"):
    return api_get(token, f"pulls?state={state}")

def print_pr_comments(token, pr_num, title=""):
    issue_comments = api_get(token, f"issues/{pr_num}/comments")
    review_comments = api_get(token, f"pulls/{pr_num}/comments")
    reviews = api_get(token, f"pulls/{pr_num}/reviews")

    header = f"=== PR #{pr_num}"
    if title:
        header += f": {title}"
    header += " ==="
    print(header)

    found_anything = False

    # 1. PR Reviews and their comments
    if reviews:
        print("\n--- Code Reviews ---")
        for review in reviews:
            review_id = review.get("id")
            user = review.get("user", {}).get("login", "unknown")
            state = review.get("state", "COMMENT")
            body = review.get("body", "").strip()
            submitted = review.get("submitted_at", "")
            print(f"• Review by @{user} [{state}] at {submitted}:")
            if body:
                print(f"  Review Summary: {body}")
            
            # Fetch review-specific comments
            comments_in_review = api_get(token, f"pulls/{pr_num}/reviews/{review_id}/comments")
            if comments_in_review:
                for comment in comments_in_review:
                    comment_body = comment.get("body", "").strip()
                    comment_path = comment.get("path", "")
                    comment_line = comment.get("line") or comment.get("old_line") or ""
                    print(f"  - [{comment_path}:{comment_line}]:")
                    print(f"    {comment_body}")
            elif not body:
                print("  (Review has no summary body or comments)")
        found_anything = True

    # 2. General Pull Request Line Comments
    if review_comments:
        print("\n--- Inline Code Comments ---")
        for comment in review_comments:
            user = comment.get("user", {}).get("login", "unknown")
            created = comment.get("created_at", "")
            path = comment.get("path", "")
            line = comment.get("line") or comment.get("old_line") or ""
            body = comment.get("body", "").strip()
            print(f"• File {path}:{line} by @{user} at {created}:")
            print(f"  {body}")
        found_anything = True

    # 3. Conversation Comments
    if issue_comments:
        print("\n--- Conversation Comments ---")
        for comment in issue_comments:
            user = comment.get("user", {}).get("login", "unknown")
            created = comment.get("created_at", "")
            body = comment.get("body", "").strip()
            print(f"• Comment by @{user} at {created}:")
            print(f"  {body}")
        found_anything = True

    if not found_anything:
        print("  (No comments or reviews found)")
    print()

def main():
    parser = argparse.ArgumentParser(description="Check comments and reviews on Gitea PRs")
    parser.add_argument("pr_number", type=int, nargs="?", help="PR number to check (default: latest open PR)")
    parser.add_argument("--all", action="store_true", help="Check comments on all recent PRs")
    args = parser.parse_args()

    env = load_env()
    token = env.get("GITEA_TOKEN")
    if not token:
        print("Error: GITEA_TOKEN not found in .env", file=sys.stderr)
        sys.exit(1)

    if args.pr_number:
        print_pr_comments(token, args.pr_number)
    elif args.all:
        pulls = get_prs(token, state="all")
        if not pulls:
            print("No PRs found.")
            return
        for pull in pulls[:5]:
            print_pr_comments(token, pull["number"], pull.get("title", ""))
    else:
        open_prs = get_prs(token, state="open")
        if open_prs:
            latest = open_prs[0]
            print_pr_comments(token, latest["number"], latest.get("title", ""))
        else:
            print("No open PRs found. Use --all to view comments on closed PRs.")

if __name__ == "__main__":
    main()
