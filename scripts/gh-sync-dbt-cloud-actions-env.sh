#!/usr/bin/env bash
#
# Load GitHub Actions secrets and variables from a .env file using gh.
# Works with merge-to-staging.yml / release-branch-flip.yml + GitHub Environments.
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Environments created in the repo: staging, pre-prod, prod
#
# Usage — repository-level (shared across environments):
#   ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#
# Usage — variables scoped to one GitHub Environment (repeat per env with different files):
#   ENVIRONMENT=staging  ENV_FILE=.env.staging  ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#   ENVIRONMENT=pre-prod ENV_FILE=.env.pre-prod ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#   ENVIRONMENT=prod     ENV_FILE=.env.prod     ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#
# Only non-empty keys after sourcing are sent. DRY_RUN=1 for a preview.
#
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  gh-sync-dbt-cloud-actions-env.sh [<owner/repo>]

Environment (shell):
  ENV_FILE          Dotenv path (default: .env)
  GH_REPO           Default repo if <owner/repo> omitted
  ENVIRONMENT       If set (e.g. staging), sync DBT_PROJECTS to that GitHub Environment only
  DRY_RUN           If 1, print actions only (secrets redacted)

Repository-level (ENVIRONMENT unset):
  Secret:    DBT_API_KEY
  Variables: DBT_ACCOUNT_ID, DBT_URL

Per GitHub Environment (ENVIRONMENT=staging|pre-prod|prod):
  Variable: DBT_PROJECTS — JSON shape differs by environment:
    staging:  {"first_dbt_project":{"project_id":"...","staging_merge_job_id":"..."}, ...}
    pre-prod: {"first_dbt_project":{"project_id":"...","environment_id":"..."}, ...}
    prod:     {"first_dbt_project":{"project_id":"...","environment_id":"..."}, ...}
  Optional secret: DBT_API_KEY (overrides repo secret for that environment)
USAGE
}

REPO="${1:-${GH_REPO:-}}"
if [[ -z "${REPO}" ]]; then
  usage >&2
  exit 1
fi

ENV_FILE="${ENV_FILE:-.env}"
DRY_RUN="${DRY_RUN:-0}"
GITHUB_ENV_NAME="${ENVIRONMENT:-}"

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
  echo "set secret ${name} (repository)"
}

set_secret_env() {
  local env_name="$1"
  local name="$2"
  local val="${!name:-}"
  if [[ -z "${val}" ]]; then
    echo "skip secret ${name} for env ${env_name} (empty)"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry-run: gh secret set ${name} --env ${env_name} -R ${REPO}  (value hidden)"
    return 0
  fi
  printf '%s' "${val}" | gh secret set "${name}" --env "${env_name}" --repo "${REPO}"
  echo "set secret ${name} (environment: ${env_name})"
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
  echo "set variable ${name} (repository)"
}

set_var_env() {
  local env_name="$1"
  local name="$2"
  local val="${!name:-}"
  if [[ -z "${val}" ]]; then
    echo "skip variable ${name} for env ${env_name} (empty)"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry-run: gh variable set ${name} -b <${#val} chars> --env ${env_name} -R ${REPO}"
    return 0
  fi
  gh variable set "${name}" --body "${val}" --env "${env_name}" --repo "${REPO}"
  echo "set variable ${name} (environment: ${env_name})"
}

require_gh

if [[ -n "${GITHUB_ENV_NAME}" ]]; then
  echo "Syncing environment-scoped Actions config to repo: ${REPO} (GitHub Environment: ${GITHUB_ENV_NAME})"
  echo ""
  set_var_env "${GITHUB_ENV_NAME}" DBT_PROJECTS
  set_secret_env "${GITHUB_ENV_NAME}" DBT_API_KEY
  echo ""
  echo "Done. Verify: gh variable list -R ${REPO} --env ${GITHUB_ENV_NAME}"
else
  echo "Syncing repository-level Actions config to repo: ${REPO}"
  echo ""
  set_secret DBT_API_KEY
  set_var DBT_ACCOUNT_ID
  set_var DBT_URL
  echo ""
  echo "Done. Verify: gh secret list -R ${REPO} && gh variable list -R ${REPO}"
  echo "Then push per-environment config:"
  echo "  ENVIRONMENT=staging  ENV_FILE=.env.staging  $0 ${REPO}"
  echo "  ENVIRONMENT=pre-prod ENV_FILE=.env.pre-prod $0 ${REPO}"
  echo "  ENVIRONMENT=prod     ENV_FILE=.env.prod     $0 ${REPO}"
fi
