#!/usr/bin/env python3
"""Map a git branch name to a GitHub Environment name and write to GITHUB_OUTPUT.

Input env vars:
  BRANCH_REF   - git branch name (e.g. "dev", "staging", "main")

Output (GITHUB_OUTPUT):
  environment  - GitHub Environment name, or empty string if unmapped
"""
import os
import sys

ENV_MAP = {"dev": "development", "staging": "staging", "main": "production"}

branch = os.environ.get("BRANCH_REF", "").strip()
env_name = ENV_MAP.get(branch, "")

if not env_name:
    print(f"::warning::No environment mapped for branch {branch!r}", file=sys.stderr)

with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
    f.write(f"environment={env_name}\n")
