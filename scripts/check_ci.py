#!/usr/bin/env python3
"""
Utility script to check Gitea Actions CI/CD runs for webapps/tiny-key-s-server.
Usage:
    ./scripts/check_ci.py          # List 5 most recent workflow runs
    ./scripts/check_ci.py -n 10    # List 10 most recent workflow runs
    ./scripts/check_ci.py <id>     # Check details/jobs for specific run ID
"""
import sys
import os
import json
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = ROOT_DIR / ".env"

token = None
if ENV_FILE.exists():
    with open(ENV_FILE, "r") as env_file:
        for line in env_file:
            if line.startswith("GITEA_TOKEN="):
                token = line.split("=", 1)[1].strip().strip("\"'")

if not token:
    print("Error: GITEA_TOKEN not found in .env", file=sys.stderr)
    sys.exit(1)

BASE_URL = "https://git.tower.jskw.dev/api/v1/repos/webapps/tiny-key-s-server/actions"
headers = {"Authorization": f"token {token}"}

def get_json(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read().decode())

def list_runs(limit=5):
    data = get_json(f"{BASE_URL}/runs")
    runs = data.get("workflow_runs", [])[:limit]
    print(f"{'RUN ID':<8} {'STATUS':<14} {'CONCLUSION':<12} {'HEAD SHA':<10} {'TITLE'}")
    print("-" * 75)
    for run in runs:
        run_id = run.get("id")
        status = run.get("status") or "-"
        conclusion = run.get("conclusion") or "-"
        sha = (run.get("head_sha") or "")[:8]
        title = run.get("display_title") or ""
        print(f"#{run_id:<7} {status:<14} {conclusion:<12} {sha:<10} {title}")

def check_run(run_id):
    run = get_json(f"{BASE_URL}/runs/{run_id}")
    print(f"Run #{run_id}: status={run.get('status')}, conclusion={run.get('conclusion')}")
    jobs_data = get_json(f"{BASE_URL}/runs/{run_id}/jobs")
    for job in jobs_data.get("jobs", []):
        print(f"  - Job: {job.get('name')}, status={job.get('status')}, conclusion={job.get('conclusion')}")
        for step in job.get("steps", []):
            print(f"      [{step.get('status')}] {step.get('name')}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        check_run(sys.argv[1])
    else:
        limit = 5
        if len(sys.argv) > 2 and sys.argv[1] == "-n":
            limit = int(sys.argv[2])
        list_runs(limit)
