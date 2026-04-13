#!/usr/bin/env python3
"""
Trigger a dbt Cloud job via Admin API v2, poll until completion, optionally post a sticky PR comment.

Prior art: https://gist.github.com/trouze/26e578d92cd803514f29f6a33d5fd2cd
Fixes: pass github_pull_request_id into the run payload; optional timeout; GITHUB_OUTPUT; PR comments in Python.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any

# ------------------------------------------------------------------------------
# Environment — dbt Cloud
# ------------------------------------------------------------------------------
_dbt_url = (os.getenv("DBT_URL") or "").strip() or "https://cloud.getdbt.com/"
api_base = _dbt_url.rstrip("/") + "/"
job_cause = os.getenv("DBT_JOB_CAUSE", "API triggered Job")
git_branch = os.getenv("DBT_JOB_BRANCH") or None
schema_override = os.getenv("DBT_JOB_SCHEMA_OVERRIDE") or None
github_pull_request_id = os.getenv("GH_PULL_REQUEST_ID") or None
api_key = os.environ["DBT_API_KEY"]
account_id = os.environ["DBT_ACCOUNT_ID"]
project_id = os.environ["DBT_PROJECT_ID"]
job_id = os.environ["DBT_PR_JOB_ID"]
poll_initial_sleep = int(os.getenv("DBT_POLL_INITIAL_SLEEP_SECONDS", "30"))
poll_interval = int(os.getenv("DBT_POLL_INTERVAL_SECONDS", "10"))
max_wait_seconds = int(os.getenv("DBT_RUN_TIMEOUT_SECONDS", "0"))  # 0 = no limit

print(
    f"""
Configuration:
  api_base: {api_base}
  job_cause: {job_cause}
  git_branch: {git_branch}
  schema_override: {schema_override}
  account_id: {account_id}
  project_id: {project_id}
  job_id: {job_id}
  github_pull_request_id: {github_pull_request_id}
"""
)

req_auth_header = {"Authorization": f"Token {api_key}"}
post_headers = {
    "Authorization": f"Token {api_key}",
    "Content-Type": "application/json",
}
req_job_url = f"{api_base}api/v2/accounts/{account_id}/jobs/{job_id}/run/"
run_status_map: dict[int, str] = {
    1: "Queued",
    2: "Starting",
    3: "Running",
    10: "Success",
    20: "Error",
    30: "Cancelled",
}


def _github_output(name: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{name}={value}\n")


def run_job(
    url: str,
    cause: str,
    branch: str | None = None,
    schema_ov: str | None = None,
    gh_pr_id: str | None = None,
) -> int:
    req_payload: dict[str, Any] = {"cause": cause}
    if branch and not branch.startswith("$("):
        req_payload["git_branch"] = branch.replace("refs/heads/", "")
    if schema_ov:
        req_payload["schema_override"] = schema_ov.replace("-", "_")
    if gh_pr_id:
        req_payload["github_pull_request_id"] = int(gh_pr_id)

    print(f"Triggering job:\n  url: {url}\n  payload: {req_payload}")

    data = json.dumps(req_payload).encode("utf-8")
    request = urllib.request.Request(method="POST", data=data, headers=post_headers, url=url)
    try:
        with urllib.request.urlopen(request, timeout=120) as req:
            response = req.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"::error::dbt Cloud API HTTP {e.code}: {body}")
        raise

    run_job_resp = json.loads(response)
    return int(run_job_resp["data"]["id"])


def get_run_status(url: str, headers: dict[str, str]) -> str:
    request = urllib.request.Request(headers=headers, url=url)
    with urllib.request.urlopen(request, timeout=60) as req:
        response = req.read().decode("utf-8")
    req_status_resp = json.loads(response)
    run_status_code = int(req_status_resp["data"]["status"])
    return run_status_map[run_status_code]


def _github_api(
    method: str,
    path: str,
    *,
    token: str,
    body: dict[str, Any] | None = None,
) -> Any:
    base = (os.getenv("GITHUB_API_URL") or "https://api.github.com").rstrip("/")
    url = f"{base}{path}"
    payload: bytes | None = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
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


def _maybe_post_pr_comment(*, success: bool, run_url: str | None) -> None:
    if (os.getenv("GH_PR_COMMENT") or "1").strip().lower() in ("0", "false", "no"):
        return
    token = os.getenv("GITHUB_TOKEN") or ""
    pr_raw = os.getenv("GH_PULL_REQUEST_ID") or ""
    repo_full = os.getenv("GITHUB_REPOSITORY") or ""
    project = (os.getenv("DBT_CI_MATRIX_PROJECT") or "").strip()
    if not token or not pr_raw or not repo_full:
        return
    if not project:
        print("::notice::Skipping PR comment: DBT_CI_MATRIX_PROJECT not set")
        return

    try:
        pr_num = int(pr_raw)
    except ValueError:
        print(f"::warning::Skipping PR comment: invalid GH_PULL_REQUEST_ID={pr_raw!r}")
        return

    owner, _, repo = repo_full.partition("/")
    if not owner or not repo:
        print(f"::warning::Skipping PR comment: bad GITHUB_REPOSITORY={repo_full!r}")
        return

    marker = f"<!-- dbt-cloud-ci:{project} -->"
    server = (os.getenv("GITHUB_SERVER_URL") or "https://github.com").rstrip("/")
    workflow = os.getenv("GITHUB_WORKFLOW") or "workflow"
    run_id = os.getenv("GITHUB_RUN_ID") or ""
    workflow_link = f"{server}/{repo_full}/actions/runs/{run_id}" if run_id else server

    conclusion = "Passed" if success else "Failed"
    emoji = "✅" if success else "❌"
    run_href = run_url or "_Run URL unavailable (job failed before a run was created)._"
    body_md = (
        f"{marker}\n"
        f"### dbt Cloud CI ({project})\n\n"
        f"{emoji} **{conclusion}**\n\n"
        f"[dbt Cloud run]({run_href})\n\n"
        f"_Workflow: [`{workflow}`]({workflow_link})_"
    )

    try:
        listed = _github_api(
            "GET",
            f"/repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
            token=token,
        )
        existing_id: int | None = None
        for c in listed:
            b = c.get("body") or ""
            if marker in b:
                existing_id = int(c["id"])
                break
        if existing_id is not None:
            _github_api(
                "PATCH",
                f"/repos/{owner}/{repo}/issues/comments/{existing_id}",
                token=token,
                body={"body": body_md},
            )
            print(f"::notice::Updated PR comment {existing_id}")
        else:
            _github_api(
                "POST",
                f"/repos/{owner}/{repo}/issues/{pr_num}/comments",
                token=token,
                body={"body": body_md},
            )
            print("::notice::Created PR comment")
    except Exception as e:
        print(f"::warning::Could not post PR comment: {e}")


def main() -> int:
    ok = False
    run_url: str | None = None
    try:
        print("Beginning dbt Cloud job run...")
        run_id = run_job(
            req_job_url,
            job_cause,
            git_branch,
            schema_override,
            github_pull_request_id,
        )
        req_status_url = f"{api_base}api/v2/accounts/{account_id}/runs/{run_id}/"
        run_url = f"{api_base.rstrip('/')}/deploy/{account_id}/projects/{project_id}/runs/{run_id}/"

        _github_output("run_id", str(run_id))
        _github_output("run_url", run_url)

        print(f"Job running. Status: {run_url}")
        print(f"::notice::dbt Cloud run {run_id} — {run_url}")

        deadline = time.monotonic() + max_wait_seconds if max_wait_seconds > 0 else None
        time.sleep(poll_initial_sleep)

        while True:
            if deadline is not None and time.monotonic() > deadline:
                print(f"::error::Timed out after {max_wait_seconds}s waiting for dbt Cloud run {run_id}")
                ok = False
                break

            status = get_run_status(req_status_url, req_auth_header)
            print(f"Run status -> {status}")

            if status in ("Error", "Cancelled"):
                print(f"::error::Run failed or canceled: {run_url}")
                ok = False
                break

            if status == "Success":
                print(f"Job completed successfully: {run_url}")
                ok = True
                break

            time.sleep(poll_interval)
    except Exception as e:
        print(f"::error::dbt Cloud job failed: {e}")
        ok = False
    finally:
        _maybe_post_pr_comment(success=ok, run_url=run_url)

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
