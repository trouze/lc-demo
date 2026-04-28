#!/usr/bin/env python3
"""Flip a dbt Cloud environment's custom_branch to a release/* branch.

Calls PATCH /api/v3/accounts/{account_id}/projects/{project_id}/environments/{env_id}/
to update the environment's custom_branch. Used by release-branch-flip.yml (and its
Jenkins equivalent) when a new release/* branch is cut in the fork repo.

Expected env vars:
  PROJECT_NAME      Key matching an entry in DBT_PROJECTS JSON
  RELEASE_BRANCH    Branch name to set (e.g. "release/1")
  DBT_URL           dbt Cloud base URL
  DBT_ACCOUNT_ID    dbt Cloud account ID
  DBT_API_KEY       dbt Cloud API token
  DBT_PROJECTS      JSON per GitHub Environment — pre-prod/prod shape:
                      {"first_dbt_project": {"project_id": ..., "environment_id": ...}, ...}
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    project_name = os.environ["PROJECT_NAME"]
    release_branch = os.environ["RELEASE_BRANCH"]

    projects_raw = os.environ["DBT_PROJECTS"]
    projects: dict = json.loads(projects_raw)

    if project_name not in projects:
        print(f"::error::Project {project_name!r} not found in DBT_PROJECTS")
        return 1

    project_cfg = projects[project_name]
    api_base = ((os.getenv("DBT_URL") or "https://cloud.getdbt.com/").strip().rstrip("/") + "/")
    account_id = os.environ["DBT_ACCOUNT_ID"]
    api_key = os.environ["DBT_API_KEY"]
    project_id = project_cfg["project_id"]
    environment_id = project_cfg["environment_id"]

    url = (
        f"{api_base}api/v3/accounts/{account_id}/projects/{project_id}"
        f"/environments/{environment_id}/"
    )
    headers = {
        "Authorization": f"Token {api_key}",
        "Content-Type": "application/json",
    }
    payload = json.dumps(
        {"custom_branch": release_branch, "use_custom_branch": True}
    ).encode("utf-8")

    print(
        f"Flipping environment {environment_id} in project {project_id}"
        f" to branch {release_branch!r}"
    )
    request = urllib.request.Request(method="PATCH", url=url, data=payload, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"::error::dbt Cloud API HTTP {e.code}: {err_body}")
        return 1

    result = json.loads(body)
    env_name = result.get("data", {}).get("name", environment_id)
    print(f"::notice::Flipped '{env_name}' (id={environment_id}) → {release_branch!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
