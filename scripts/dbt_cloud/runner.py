#!/usr/bin/env python3
"""Unified dbt Cloud runner for a single project (matrix fans out at workflow level).

Reads DBT_PROJECTS JSON env var, looks up config for PROJECT_NAME, builds
the cfg dict, and calls run_project() from call_dbt_job.py.

Expected env vars:
  PROJECT_NAME               Key matching an entry in DBT_PROJECTS JSON
  MODE                       "deploy"
  SCOPE                      "trunk"
  ENVIRONMENT                GitHub Environment name (e.g. "staging")
  DBT_URL                    dbt Cloud base URL
  DBT_ACCOUNT_ID             dbt Cloud account ID
  DBT_API_KEY                dbt Cloud API token
  DBT_PROJECTS               JSON per GitHub Environment — staging shape:
                               {"first_dbt_project": {"project_id": ..., "staging_merge_job_id": ...}, ...}
  DBT_JOB_BRANCH             Git branch to run the job against
  DBT_RUN_TIMEOUT_SECONDS    Max seconds to wait per job run (0 = no limit)
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from call_dbt_job import run_project  # noqa: E402


def main() -> int:
    project_name = os.environ["PROJECT_NAME"]

    projects_raw = os.environ["DBT_PROJECTS"]
    projects: dict = json.loads(projects_raw)

    if project_name not in projects:
        print(f"::error::Project {project_name!r} not found in DBT_PROJECTS")
        return 1

    project_cfg = projects[project_name]
    job_id = project_cfg["staging_merge_job_id"]

    api_base = ((os.getenv("DBT_URL") or "https://cloud.getdbt.com/").strip().rstrip("/") + "/")

    branch = os.environ["DBT_JOB_BRANCH"]
    sha = os.getenv("GITHUB_SHA", "")[:7]

    cfg: dict = {
        "api_base":           api_base,
        "api_key":            os.environ["DBT_API_KEY"],
        "account_id":         os.environ["DBT_ACCOUNT_ID"],
        "project_id":         project_cfg["project_id"],
        "job_id":             job_id,
        "job_cause":          f"github-actions:merge-to-staging:{branch}@{sha}",
        "git_branch":         branch,
        "poll_initial_sleep": int(os.getenv("DBT_POLL_INITIAL_SLEEP_SECONDS", "30")),
        "poll_interval":      int(os.getenv("DBT_POLL_INTERVAL_SECONDS", "10")),
        "max_wait_seconds":   int(os.getenv("DBT_RUN_TIMEOUT_SECONDS", "0")),
    }

    ok = run_project(cfg)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
