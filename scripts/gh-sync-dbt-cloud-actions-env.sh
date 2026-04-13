#!/usr/bin/env bash
#
# Load GitHub Actions secrets and variables from a .env file into a repository using gh.
# Intended for dbt-cloud-ci.yml / dbt-cloud-cd.yml (DBT_* names).
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - A .env file with assignments (optionally export KEY=value). Use set -a + source below.
#
# Usage:
#   export ENV_FILE=.env.dbt-cloud   # optional; default .env
#   ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#
#   # or rely on GH_REPO
#   export GH_REPO=myorg/my-data-repo
#   ./scripts/gh-sync-dbt-cloud-actions-env.sh
#
# Only keys that are non-empty after sourcing are sent. Optional vars (e.g. DBT_URL) are skipped if unset.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gh-sync-dbt-cloud-actions-env.sh [<owner/repo>]

Environment:
  ENV_FILE          Path to dotenv file (default: .env)
  GH_REPO           Default repo if <owner/repo> omitted
  DRY_RUN           If set to 1, print what would be set (secrets redacted)

Repository secrets (gh secret set):
  DBT_API_KEY

Repository variables (gh variable set):
  DBT_ACCOUNT_ID
  DBT_URL
  DBT_PROJECT_ID_1  DBT_JOB_CI_1   DBT_JOB_CD_1
  DBT_PROJECT_ID_2  DBT_JOB_CI_2   DBT_JOB_CD_2

Source your .env before running, or rely on this script sourcing ENV_FILE, e.g.:

  DBT_API_KEY=...
  DBT_ACCOUNT_ID=12345
  DBT_URL=https://cloud.getdbt.com
  DBT_PROJECT_ID_1=...
  DBT_JOB_CI_1=...
  DBT_JOB_CD_1=...
  DBT_PROJECT_ID_2=...
  DBT_JOB_CI_2=...
  DBT_JOB_CD_2=...
USAGE
}

REPO="${1:-${GH_REPO:-}}"
if [[ -z "${REPO}" ]]; then
  usage >&2
  exit 1
fi

ENV_FILE="${ENV_FILE:-.env}"
DRY_RUN="${DRY_RUN:-0}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
else
  echo "warning: ${ENV_FILE} not found; using only already-exported environment variables" >&2
fi

require_gh() {
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh CLI not found" >&2
    exit 1
  }
}

set_secret() {
  local name="$1"
  local val="${!name:-}"
  if [[ -z "${val}" ]]; then
    echo "skip secret ${name} (empty)"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry-run: gh secret set ${name} -R ${REPO}  (value hidden)"
    return 0
  fi
  printf '%s' "${val}" | gh secret set "${name}" --repo "${REPO}"
  echo "set secret ${name}"
}

set_var() {
  local name="$1"
  local val="${!name:-}"
  if [[ -z "${val}" ]]; then
    echo "skip variable ${name} (empty)"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry-run: gh variable set ${name} -b <${#val} chars> -R ${REPO}"
    return 0
  fi
  gh variable set "${name}" --body "${val}" --repo "${REPO}"
  echo "set variable ${name}"
}

require_gh

echo "Syncing Actions config to repo: ${REPO}"
echo ""

# --- secrets ---
set_secret DBT_API_KEY

# --- variables (aligned with .github/workflows/dbt-cloud-ci.yml + dbt-cloud-cd.yml) ---
set_var DBT_ACCOUNT_ID
set_var DBT_URL
set_var DBT_PROJECT_ID_1
set_var DBT_JOB_CI_1
set_var DBT_JOB_CD_1
set_var DBT_PROJECT_ID_2
set_var DBT_JOB_CI_2
set_var DBT_JOB_CD_2

echo ""
echo "Done. Verify: gh secret list -R ${REPO} && gh variable list -R ${REPO}"
