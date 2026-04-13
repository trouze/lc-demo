#!/usr/bin/env python3
"""
Trigger a dbt Cloud job via Admin API v2, poll until completion, optionally post a sticky PR comment.

Can be used as a standalone script (reads config from env vars) or imported — call run_project(cfg)
directly from ci_runner.py / cd_runner.py.

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
    schema_override: str | None = None,
    github_pull_request_id: int | None = None,
) -> int:
    payload: dict[str, Any] = {"cause": cause}
    if branch and not branch.startswith("$("):
        payload["git_branch"] = branch.replace("refs/heads/", "")
    if schema_override:
        payload["schema_override"] = schema_override.replace("-", "_")
    if github_pull_request_id is not None:
        payload["github_pull_request_id"] = github_pull_request_id

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


def _github_api(
    method: str,
    path: str,
    *,
    token: str,
    body: dict[str, Any] | None = None,
) -> Any:
    base = (os.getenv("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
    url = f"{base}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    payload: bytes | None = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, method=method, headers=headers, data=payload)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"::warning::GitHub API {method} {path} HTTP {e.code}: {err_body}")
        raise


def _post_pr_comment(*, success: bool, run_url: str | None, cfg: dict) -> None:
    if (os.getenv("GH_PR_COMMENT") or "1").strip().lower() in ("0", "false", "no"):
        return
    token = os.getenv("GITHUB_TOKEN") or ""
    pr_raw = cfg.get("github_pull_request_id")
    repo_full = os.getenv("GITHUB_REPOSITORY") or ""
    project = (cfg.get("dbt_ci_matrix_project") or "").strip()

    if not token or not pr_raw or not repo_full or not project:
        return

    try:
        pr_num = int(pr_raw)
    except (ValueError, TypeError):
        print(f"::warning::Skipping PR comment: invalid github_pull_request_id={pr_raw!r}")
        return

    owner, _, repo = repo_full.partition("/")
    if not owner or not repo:
        return

    marker = f"<!-- dbt-cloud-ci:{project} -->"
    server = (os.getenv("GITHUB_SERVER_URL") or "https://github.com").rstrip("/")
    workflow = os.getenv("GITHUB_WORKFLOW") or "workflow"
    run_id = os.getenv("GITHUB_RUN_ID") or ""
    workflow_link = f"{server}/{repo_full}/actions/runs/{run_id}" if run_id else server

    emoji = "✅" if success else "❌"
    conclusion = "Passed" if success else "Failed"
    run_href = run_url or "_Run URL unavailable (job failed before a run was created)._"
    body_md = (
        f"{marker}\n"
        f"### dbt Cloud CI ({project})\n\n"
        f"{emoji} **{conclusion}**\n\n"
        f"[dbt Cloud run]({run_href})\n\n"
        f"_Workflow: [`{workflow}`]({workflow_link})_"
    )

    try:
        comments = _github_api(
            "GET",
            f"/repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
            token=token,
        )
        existing_id: int | None = next(
            (int(c["id"]) for c in comments if marker in (c.get("body") or "")),
            None,
        )
        if existing_id is not None:
            _github_api("PATCH", f"/repos/{owner}/{repo}/issues/comments/{existing_id}",
                        token=token, body={"body": body_md})
            print(f"::notice::Updated PR comment {existing_id}")
        else:
            _github_api("POST", f"/repos/{owner}/{repo}/issues/{pr_num}/comments",
                        token=token, body={"body": body_md})
            print("::notice::Created PR comment")
    except Exception as e:
        print(f"::warning::Could not post PR comment: {e}")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def run_project(cfg: dict) -> bool:
    """Trigger a dbt Cloud job, poll until completion, optionally post a sticky PR comment.

    cfg keys:
      api_base, api_key, account_id, project_id, job_id,
      job_cause, git_branch, schema_override, github_pull_request_id,
      poll_initial_sleep, poll_interval, max_wait_seconds,
      dbt_ci_matrix_project (optional, for PR comment marker)
    Returns True on success.
    """
    api_base: str = cfg["api_base"]
    auth_headers = {"Authorization": f"Token {cfg['api_key']}"}
    post_headers = {**auth_headers, "Content-Type": "application/json"}
    trigger_url = f"{api_base}api/v2/accounts/{cfg['account_id']}/jobs/{cfg['job_id']}/run/"

    pr_id_raw = cfg.get("github_pull_request_id")
    pr_id_int: int | None = None
    if pr_id_raw:
        try:
            pr_id_int = int(pr_id_raw)
        except (ValueError, TypeError):
            pass

    print(
        f"\nConfiguration:\n"
        f"  api_base:               {api_base}\n"
        f"  job_cause:              {cfg.get('job_cause')}\n"
        f"  git_branch:             {cfg.get('git_branch')}\n"
        f"  schema_override:        {cfg.get('schema_override')}\n"
        f"  account_id:             {cfg['account_id']}\n"
        f"  project_id:             {cfg['project_id']}\n"
        f"  job_id:                 {cfg['job_id']}\n"
        f"  github_pull_request_id: {pr_id_int}\n"
    )

    ok = False
    run_url: str | None = None
    try:
        run_id = _trigger_job(
            trigger_url,
            post_headers,
            cfg.get("job_cause", "API triggered Job"),
            cfg.get("git_branch"),
            cfg.get("schema_override"),
            pr_id_int,
        )
        status_url = f"{api_base}api/v2/accounts/{cfg['account_id']}/runs/{run_id}/"
        run_url = f"{api_base.rstrip('/')}/deploy/{cfg['account_id']}/projects/{cfg['project_id']}/runs/{run_id}/"

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

    finally:
        _post_pr_comment(success=ok, run_url=run_url, cfg=cfg)

    return ok


# ---------------------------------------------------------------------------
# Standalone entry point (used by CD via call_dbt_job.py directly)
# ---------------------------------------------------------------------------

def main() -> int:
    api_base = ((os.getenv("DBT_URL") or "https://cloud.getdbt.com/").strip().rstrip("/") + "/")
    cfg = {
        "api_base":               api_base,
        "api_key":                os.environ["DBT_API_KEY"],
        "account_id":             os.environ["DBT_ACCOUNT_ID"],
        "project_id":             os.environ["DBT_PROJECT_ID"],
        "job_id":                 os.environ["DBT_PR_JOB_ID"],
        "job_cause":              os.getenv("DBT_JOB_CAUSE", "API triggered Job"),
        "git_branch":             os.getenv("DBT_JOB_BRANCH"),
        "schema_override":        os.getenv("DBT_JOB_SCHEMA_OVERRIDE"),
        "github_pull_request_id": os.getenv("GH_PULL_REQUEST_ID"),
        "poll_initial_sleep":     int(os.getenv("DBT_POLL_INITIAL_SLEEP_SECONDS", "30")),
        "poll_interval":          int(os.getenv("DBT_POLL_INTERVAL_SECONDS", "10")),
        "max_wait_seconds":       int(os.getenv("DBT_RUN_TIMEOUT_SECONDS", "0")),
        "dbt_ci_matrix_project":  os.getenv("DBT_CI_MATRIX_PROJECT", ""),
    }
    return 0 if run_project(cfg) else 1


if __name__ == "__main__":
    sys.exit(main())
