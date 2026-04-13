#!/usr/bin/env python3
"""Build the strategy.matrix.include JSON for CI/CD workflows and write to GITHUB_OUTPUT.

Each matrix row contains the environment, project name, and the resolved dbt Cloud
project ID + job ID — so the consuming job needs no conditional expressions.

Input env vars:
  PROJECTS_JSON      - JSON array of changed project names (from dorny/paths-filter)
  ENVIRONMENT        - GitHub Environment name (e.g. "development", "staging", "production")
  DBT_PROJECT_ID_1   - dbt Cloud project ID for project_1
  DBT_PROJECT_ID_2   - dbt Cloud project ID for project_2
  DBT_JOB_1          - dbt Cloud job ID for project_1 (CI or CD job, caller decides)
  DBT_JOB_2          - dbt Cloud job ID for project_2 (CI or CD job, caller decides)

Output (GITHUB_OUTPUT):
  matrix_json  - JSON array of matrix include objects
"""
import json
import os

projects = json.loads(os.environ["PROJECTS_JSON"])
environment = os.environ["ENVIRONMENT"]

project_config = {
    "project_1": {
        "dbt_project_id": os.environ["DBT_PROJECT_ID_1"],
        "dbt_job_id":     os.environ["DBT_JOB_1"],
    },
    "project_2": {
        "dbt_project_id": os.environ["DBT_PROJECT_ID_2"],
        "dbt_job_id":     os.environ["DBT_JOB_2"],
    },
}

matrix = [
    {"environment": environment, "project": p, **project_config[p]}
    for p in projects
    if p in project_config
]

with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
    f.write("matrix_json<<EOF\n")
    f.write(json.dumps(matrix))
    f.write("\nEOF\n")
