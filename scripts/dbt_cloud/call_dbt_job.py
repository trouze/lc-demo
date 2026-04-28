#!/usr/bin/env python3
"""
Trigger a dbt Cloud job via Admin API v2, poll until completion.

Can be used as a standalone script (reads config from env vars) or imported — call run_project(cfg)
directly from runner.py.

Prior art: https://gist.github.com/trouze/26e578d92cd803514f29f6a33d5fd2cd
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any

RUN_STATUS_MAP: dict[int, str] = {
    1: "Queued",
    2: "Starting",
    3: "Running",
    10: "Success",
    20: "Error",
    30: "Cancelled",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _github_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{name}={value}\n")


def _trigger_job(
    url: str,
    headers: dict[str, str],
    cause: str,
    branch: str | None = None,
) -> int:
    payload: dict[str, Any] = {"cause": cause}
    if branch and not branch.startswith("$("):
        payload["git_branch"] = branch.replace("refs/heads/", "")

    print(f"Triggering job:\n  url: {url}\n  payload: {payload}")

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(method="POST", data=data, headers=headers, url=url)
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"::error::dbt Cloud API HTTP {e.code}: {err_body}")
        raise

    return int(json.loads(body)["data"]["id"])


def _poll_run(url: str, auth_headers: dict[str, str]) -> str:
    request = urllib.request.Request(headers=auth_headers, url=url)
    with urllib.request.urlopen(request, timeout=60) as resp:
        body = resp.read().decode("utf-8")
    code = int(json.loads(body)["data"]["status"])
    return RUN_STATUS_MAP[code]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run_project(cfg: dict) -> bool:
    """Trigger a dbt Cloud job and poll until completion.

    cfg keys:
      api_base, api_key, account_id, project_id, job_id,
      job_cause, git_branch,
      poll_initial_sleep, poll_interval, max_wait_seconds
    Returns True on success.
    """
    api_base: str = cfg["api_base"]
    auth_headers = {"Authorization": f"Token {cfg['api_key']}"}
    post_headers = {**auth_headers, "Content-Type": "application/json"}
    trigger_url = f"{api_base}api/v2/accounts/{cfg['account_id']}/jobs/{cfg['job_id']}/run/"

    print(
        f"\nConfiguration:\n"
        f"  api_base:    {api_base}\n"
        f"  job_cause:   {cfg.get('job_cause')}\n"
        f"  git_branch:  {cfg.get('git_branch')}\n"
        f"  account_id:  {cfg['account_id']}\n"
        f"  project_id:  {cfg['project_id']}\n"
        f"  job_id:      {cfg['job_id']}\n"
    )

    ok = False
    try:
        run_id = _trigger_job(
            trigger_url,
            post_headers,
            cfg.get("job_cause", "API triggered Job"),
            cfg.get("git_branch"),
        )
        status_url = f"{api_base}api/v2/accounts/{cfg['account_id']}/runs/{run_id}/"
        run_url = (
            f"{api_base.rstrip('/')}/deploy/{cfg['account_id']}"
            f"/projects/{cfg['project_id']}/runs/{run_id}/"
        )

        _github_output("run_id", str(run_id))
        _github_output("run_url", run_url)
        print(f"Job running: {run_url}")
        print(f"::notice::dbt Cloud run {run_id} — {run_url}")

        max_wait: int = cfg.get("max_wait_seconds", 0)
        deadline = time.monotonic() + max_wait if max_wait > 0 else None
        time.sleep(cfg.get("poll_initial_sleep", 30))

        while True:
            if deadline is not None and time.monotonic() > deadline:
                print(f"::error::Timed out after {max_wait}s waiting for run {run_id}")
                break
            status = _poll_run(status_url, auth_headers)
            print(f"Run status → {status}")
            if status in ("Error", "Cancelled"):
                print(f"::error::Run failed or canceled: {run_url}")
                break
            if status == "Success":
                print(f"Job completed successfully: {run_url}")
                ok = True
                break
            time.sleep(cfg.get("poll_interval", 10))

    except Exception as e:
        print(f"::error::dbt Cloud job failed: {e}")

    return ok


if __name__ == "__main__":
    api_base = ((os.getenv("DBT_URL") or "https://cloud.getdbt.com/").strip().rstrip("/") + "/")
    cfg = {
        "api_base":           api_base,
        "api_key":            os.environ["DBT_API_KEY"],
        "account_id":         os.environ["DBT_ACCOUNT_ID"],
        "project_id":         os.environ["DBT_PROJECT_ID"],
        "job_id":             os.environ["DBT_JOB_ID"],
        "job_cause":          os.getenv("DBT_JOB_CAUSE", "API triggered Job"),
        "git_branch":         os.getenv("DBT_JOB_BRANCH"),
        "poll_initial_sleep": int(os.getenv("DBT_POLL_INITIAL_SLEEP_SECONDS", "30")),
        "poll_interval":      int(os.getenv("DBT_POLL_INTERVAL_SECONDS", "10")),
        "max_wait_seconds":   int(os.getenv("DBT_RUN_TIMEOUT_SECONDS", "0")),
    }
    sys.exit(0 if run_project(cfg) else 1)
