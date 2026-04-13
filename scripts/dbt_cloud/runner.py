#!/usr/bin/env python3
"""Unified dbt Cloud runner for a single project (matrix fans out at workflow level).

Reads DBT_PROJECTS JSON env var, looks up config for PROJECT_NAME, builds
the cfg dict based on MODE (ci/cd), and calls run_project() from call_dbt_job.py.

Expected env vars (set by _dbt-cloud-run.yml):
  PROJECT_NAME               Key matching an entry in DBT_PROJECTS JSON
  MODE                       "ci" or "cd"
  ENVIRONMENT                GitHub Environment name (e.g. "development")
  DBT_URL                    dbt Cloud base URL
  DBT_ACCOUNT_ID             dbt Cloud account ID
  DBT_API_KEY                dbt Cloud API token
  DBT_PROJECTS               JSON: {"project_1": {"project_id": ..., "ci_job_id": ..., "cd_job_id": ...}, ...}
  DBT_JOB_BRANCH             Git branch to run the job against
  DBT_RUN_TIMEOUT_SECONDS    Max seconds to wait per job run (0 = no limit)

CI-only env vars:
  GH_PULL_REQUEST_ID         GitHub PR number
  DBT_SCHEMA_OVERRIDE_PREFIX Schema override prefix (e.g. "dbt_cloud_pr_42")
  GIT_SHA                    PR head SHA (for schema suffix)
  GITHUB_TOKEN               GitHub token for posting sticky PR comments

CD-only env vars:
  DBT_JOB_CAUSE_SUFFIX       Appended to job cause (e.g. "push-main@abc1234")
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from call_dbt_job import run_project  # noqa: E402


def main() -> int:
    project_name = os.environ["PROJECT_NAME"]
    mode = os.environ["MODE"]
    environment = os.environ["ENVIRONMENT"]

    projects_raw = os.environ["DBT_PROJECTS"]
    projects: dict = json.loads(projects_raw)

    if project_name not in projects:
        print(f"::error::Project {project_name!r} not found in DBT_PROJECTS")
        return 1

    project_cfg = projects[project_name]
    job_id_key = "ci_job_id" if mode == "ci" else "cd_job_id"
    job_id = project_cfg[job_id_key]

    api_base = ((os.getenv("DBT_URL") or "https://cloud.getdbt.com/").strip().rstrip("/") + "/")

    cfg: dict = {
        "api_base":           api_base,
        "api_key":            os.environ["DBT_API_KEY"],
        "account_id":         os.environ["DBT_ACCOUNT_ID"],
        "project_id":         project_cfg["project_id"],
        "job_id":             job_id,
        "git_branch":         os.environ["DBT_JOB_BRANCH"],
        "poll_initial_sleep": int(os.getenv("DBT_POLL_INITIAL_SLEEP_SECONDS", "30")),
        "poll_interval":      int(os.getenv("DBT_POLL_INTERVAL_SECONDS", "10")),
        "max_wait_seconds":   int(os.getenv("DBT_RUN_TIMEOUT_SECONDS", "0")),
    }

    if mode == "ci":
        pr_id = os.environ["GH_PULL_REQUEST_ID"]
        schema_prefix = os.environ["DBT_SCHEMA_OVERRIDE_PREFIX"]
        short_sha = os.environ.get("GIT_SHA", "")[:7]
        cfg.update({
            "job_cause":             f"github-actions-ci:{environment}:pr-{pr_id}",
            "schema_override":       f"{schema_prefix}_{short_sha}" if short_sha else schema_prefix,
            "github_pull_request_id": pr_id,
            "dbt_ci_matrix_project": project_name,
        })
    else:
        cause_suffix = os.environ["DBT_JOB_CAUSE_SUFFIX"]
        cfg["job_cause"] = f"github-actions-cd:{environment}:{cause_suffix}"

    ok = run_project(cfg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
