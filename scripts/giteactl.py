#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "python-dotenv",
#     "requests",
#     "typer",
# ]
# ///
"""
Gitea Control CLI (gitactl / giteactl)
Unified CLI utility to manage Pull Requests, reviews, comments, and CI workflows on Gitea.

Usage:
    uv run ./scripts/giteactl.py --help
    uv run ./scripts/giteactl.py comment 3 --body "Looks great!"
    uv run ./scripts/giteactl.py comment 3 --file review.md
    uv run ./scripts/giteactl.py comments 3
    uv run ./scripts/giteactl.py ci
    uv run ./scripts/giteactl.py ci 153
    uv run ./scripts/giteactl.py create-pr --title "feat: new feature"
"""
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

import requests
import typer
from dotenv import find_dotenv, load_dotenv

REPO_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(find_dotenv(usecwd=True) or (REPO_ROOT / ".env"))

BASE_API_URL = "https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server"

app = typer.Typer(
    name="giteactl",
    help="Unified CLI for managing Gitea pull requests, comments, and CI workflow actions.",
    add_completion=False,
)

def get_token() -> str:
    token = os.getenv("GITEA_TOKEN")
    if not token:
        typer.secho("Error: GITEA_TOKEN environment variable not found.", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)
    return token

def get_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"token {token}",
        "Accept": "application/json",
    }

def get_current_branch() -> str:
    try:
        output = subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return output
    except Exception:
        return "feat/utility-scripts"

def get_latest_commit_title() -> str:
    try:
        output = subprocess.check_output(
            ["git", "log", "-1", "--format=%s"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
        return output
    except Exception:
        return "chore: update"

@app.command("comment", help="Post a comment on a Pull Request or Issue.")
def comment(
    pr_number: int = typer.Argument(1, help="Pull Request or issue number (default: 1)"),
    body: Optional[str] = typer.Option(None, "--body", "-b", help="Comment body text"),
    file_path: Optional[Path] = typer.Option(None, "--file", "-f", help="Path to markdown file containing comment body"),
):
    token = get_token()
    comment_body = ""

    if body:
        comment_body = body
    elif file_path:
        if not file_path.exists():
            typer.secho(f"Error: File '{file_path}' does not exist.", fg=typer.colors.RED, err=True)
            raise typer.Exit(code=1)
        with open(file_path, "r", encoding="utf-8") as file_handle:
            comment_body = file_handle.read()
    elif not sys.stdin.isatty():
        comment_body = sys.stdin.read()

    comment_body = comment_body.strip()
    if not comment_body:
        typer.secho("Error: No comment body provided. Specify --body, --file, or pipe content through stdin.", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

    url = f"{BASE_API_URL}/issues/{pr_number}/comments"
    payload = {"body": comment_body}

    try:
        response = requests.post(url, headers=get_headers(token), json=payload, timeout=30)
        response.raise_for_status()
        data = response.json()
        comment_id = data.get("id")
        comment_url = data.get("html_url")
        typer.secho(f"Successfully posted comment on PR #{pr_number} (ID: {comment_id})", fg=typer.colors.GREEN)
        typer.echo(f"URL: {comment_url}")
    except requests.exceptions.RequestException as request_error:
        typer.secho(f"Failed to post comment: {request_error}", fg=typer.colors.RED, err=True)
        if response_obj := getattr(request_error, "response", None):
            typer.secho(response_obj.text, fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

def display_pr_comments(token: str, pr_number: int, title: str = ""):
    headers = get_headers(token)

    try:
        issue_comments = requests.get(f"{BASE_API_URL}/issues/{pr_number}/comments", headers=headers, timeout=30).json()
    except Exception:
        issue_comments = []

    try:
        review_comments = requests.get(f"{BASE_API_URL}/pulls/{pr_number}/comments", headers=headers, timeout=30).json()
    except Exception:
        review_comments = []

    try:
        reviews = requests.get(f"{BASE_API_URL}/pulls/{pr_number}/reviews", headers=headers, timeout=30).json()
    except Exception:
        reviews = []

    header = f"=== PR #{pr_number}"
    if title:
        header += f": {title}"
    header += " ==="
    typer.secho(header, bold=True)

    found_anything = False

    # 1. PR Reviews and their comments
    if isinstance(reviews, list) and reviews:
        typer.secho("\n--- Code Reviews ---", bold=True)
        for review in reviews:
            review_id = review.get("id")
            user = review.get("user", {}).get("login", "unknown")
            state = review.get("state", "COMMENT")
            review_summary = review.get("body", "").strip()
            submitted = review.get("submitted_at", "")
            
            state_color = typer.colors.YELLOW
            if state == "APPROVED":
                state_color = typer.colors.GREEN
            elif state == "REQUEST_CHANGES":
                state_color = typer.colors.RED

            typer.echo(f"• Review by @{user} [", nl=False)
            typer.secho(state, fg=state_color, nl=False)
            typer.echo(f"] at {submitted}:")

            if review_summary:
                typer.echo(f"  Review Summary: {review_summary}")

            try:
                comments_in_review = requests.get(
                    f"{BASE_API_URL}/pulls/{pr_number}/reviews/{review_id}/comments",
                    headers=headers,
                    timeout=30,
                ).json()
            except Exception:
                comments_in_review = []

            if isinstance(comments_in_review, list) and comments_in_review:
                for comment_item in comments_in_review:
                    comment_body = comment_item.get("body", "").strip()
                    comment_path = comment_item.get("path", "")
                    comment_line = comment_item.get("line") or comment_item.get("old_line") or ""
                    typer.echo(f"  - [{comment_path}:{comment_line}]:")
                    typer.echo(f"    {comment_body}")
            elif not review_summary:
                typer.echo("  (Review has no summary body or comments)")
        found_anything = True

    # 2. Inline Code Comments
    if isinstance(review_comments, list) and review_comments:
        typer.secho("\n--- Inline Code Comments ---", bold=True)
        for comment_item in review_comments:
            user = comment_item.get("user", {}).get("login", "unknown")
            created = comment_item.get("created_at", "")
            path = comment_item.get("path", "")
            line = comment_item.get("line") or comment_item.get("old_line") or ""
            comment_body = comment_item.get("body", "").strip()
            typer.echo(f"• File {path}:{line} by @{user} at {created}:")
            typer.echo(f"  {comment_body}")
        found_anything = True

    # 3. Conversation Comments
    if isinstance(issue_comments, list) and issue_comments:
        typer.secho("\n--- Conversation Comments ---", bold=True)
        for comment_item in issue_comments:
            user = comment_item.get("user", {}).get("login", "unknown")
            created = comment_item.get("created_at", "")
            comment_body = comment_item.get("body", "").strip()
            typer.echo(f"• Comment by @{user} at {created}:")
            typer.echo(f"  {comment_body}")
        found_anything = True

    if not found_anything:
        typer.echo("  (No comments or reviews found)")
    typer.echo()

@app.command("comments", help="Inspect reviews, line comments, and conversation comments on PRs.")
def comments(
    pr_number: Optional[int] = typer.Argument(None, help="PR number to inspect (default: latest open PR)"),
    all_prs: bool = typer.Option(False, "--all", "-a", help="Inspect comments across all recent PRs"),
):
    token = get_token()
    headers = get_headers(token)

    if pr_number is not None:
        display_pr_comments(token, pr_number)
    elif all_prs:
        try:
            response = requests.get(f"{BASE_API_URL}/pulls?state=all", headers=headers, timeout=30)
            response.raise_for_status()
            pull_requests = response.json()
        except requests.exceptions.RequestException as request_error:
            typer.secho(f"Error fetching PR list: {request_error}", fg=typer.colors.RED, err=True)
            raise typer.Exit(code=1)

        if not pull_requests:
            typer.echo("No PRs found.")
            return

        for pull in pull_requests[:5]:
            display_pr_comments(token, pull["number"], pull.get("title", ""))
    else:
        try:
            response = requests.get(f"{BASE_API_URL}/pulls?state=open", headers=headers, timeout=30)
            response.raise_for_status()
            open_pulls = response.json()
        except requests.exceptions.RequestException as request_error:
            typer.secho(f"Error fetching open PRs: {request_error}", fg=typer.colors.RED, err=True)
            raise typer.Exit(code=1)

        if open_pulls:
            latest = open_pulls[0]
            display_pr_comments(token, latest["number"], latest.get("title", ""))
        else:
            typer.echo("No open PRs found. Use --all to view comments on closed PRs.")

@app.command("ci", help="Check CI workflow runs or inspect a specific workflow run.")
def ci(
    run_id: Optional[int] = typer.Argument(None, help="Workflow run ID to inspect"),
    limit: int = typer.Option(5, "--limit", "-l", help="Number of recent workflow runs to list"),
):
    token = get_token()
    headers = get_headers(token)
    actions_url = f"{BASE_API_URL}/actions"

    if run_id is not None:
        try:
            run_response = requests.get(f"{actions_url}/runs/{run_id}", headers=headers, timeout=30)
            run_response.raise_for_status()
            run_data = run_response.json()

            status = run_data.get("status")
            conclusion = run_data.get("conclusion")
            typer.echo(f"Run #{run_id}: status={status}, conclusion={conclusion}")

            jobs_response = requests.get(f"{actions_url}/runs/{run_id}/jobs", headers=headers, timeout=30)
            jobs_response.raise_for_status()
            jobs_data = jobs_response.json()

            for job in jobs_data.get("jobs", []):
                job_name = job.get("name")
                job_status = job.get("status")
                job_conclusion = job.get("conclusion")
                typer.echo(f"  - Job: {job_name}, status={job_status}, conclusion={job_conclusion}")
                for step in job.get("steps", []):
                    step_status = step.get("status")
                    step_name = step.get("name")
                    typer.echo(f"      [{step_status}] {step_name}")
        except requests.exceptions.RequestException as request_error:
            typer.secho(f"Error fetching workflow run #{run_id}: {request_error}", fg=typer.colors.RED, err=True)
            raise typer.Exit(code=1)
    else:
        try:
            runs_response = requests.get(f"{actions_url}/runs", headers=headers, timeout=30)
            runs_response.raise_for_status()
            runs_data = runs_response.json()
            workflow_runs = runs_data.get("workflow_runs", [])[:limit]

            header = f"{'RUN ID':<8} {'STATUS':<14} {'CONCLUSION':<12} {'HEAD SHA':<10} {'TITLE'}"
            typer.secho(header, bold=True)
            typer.echo("-" * 75)
            for workflow_run in workflow_runs:
                current_id = workflow_run.get("id")
                status = workflow_run.get("status") or "-"
                conclusion = workflow_run.get("conclusion") or "-"
                sha = (workflow_run.get("head_sha") or "")[:8]
                title = workflow_run.get("display_title") or ""
                typer.echo(f"#{current_id:<7} {status:<14} {conclusion:<12} {sha:<10} {title}")
        except requests.exceptions.RequestException as request_error:
            typer.secho(f"Error listing workflow runs: {request_error}", fg=typer.colors.RED, err=True)
            raise typer.Exit(code=1)

@app.command("create-pr", help="Create a Pull Request on Gitea.")
def create_pr(
    title: Optional[str] = typer.Option(None, "--title", "-t", help="PR title (default: latest commit subject)"),
    body: Optional[str] = typer.Option(None, "--body", "-b", help="PR description body"),
    head: Optional[str] = typer.Option(None, "--head", help="Source branch (default: current git branch)"),
    base: str = typer.Option("main", "--base", help="Target branch (default: main)"),
):
    token = get_token()
    headers = get_headers(token)

    head_branch = head or get_current_branch()
    pr_title = title or get_latest_commit_title()
    pr_body = body or f"Automated pull request for branch `{head_branch}`."

    payload = {
        "base": base,
        "head": head_branch,
        "title": pr_title,
        "body": pr_body,
    }

    url = f"{BASE_API_URL}/pulls"
    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        data = response.json()
        pr_number = data.get("number")
        pr_url = data.get("html_url")
        typer.secho(f"Successfully created PR #{pr_number}: {pr_url}", fg=typer.colors.GREEN)
    except requests.exceptions.HTTPError as http_error:
        response_obj = http_error.response
        if response_obj is not None and response_obj.status_code == 409:
            typer.secho(f"Notice: A pull request for '{head_branch}' -> '{base}' may already exist.", fg=typer.colors.YELLOW)
            try:
                list_response = requests.get(f"{url}?state=open", headers=headers, timeout=30)
                list_response.raise_for_status()
                pull_requests = list_response.json()
                for pull in pull_requests:
                    if pull.get("head", {}).get("ref") == head_branch:
                        typer.echo(f"Existing PR #{pull.get('number')}: {pull.get('html_url')}")
                        return
            except Exception:
                pass
        typer.secho(f"Failed to create PR: {http_error}", fg=typer.colors.RED, err=True)
        if response_obj is not None:
            typer.secho(response_obj.text, fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)
    except requests.exceptions.RequestException as request_error:
        typer.secho(f"Request error: {request_error}", fg=typer.colors.RED, err=True)
        raise typer.Exit(code=1)

if __name__ == "__main__":
    app()
