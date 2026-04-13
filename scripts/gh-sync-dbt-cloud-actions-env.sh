#!/usr/bin/env bash
#
# Load GitHub Actions secrets and variables from a .env file using gh.
# Works with dbt-cloud-ci.yml / dbt-cloud-cd.yml + GitHub Environments.
#
# Prerequisites:
#   - gh CLI authenticated (gh auth login)
#   - Environments created in the repo: development, staging, production
#
# Usage — repository-level (shared across environments):
#   ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#
# Usage — variables scoped to one GitHub Environment (repeat per env with different files):
#   ENVIRONMENT=development ENV_FILE=.env.development ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#   ENVIRONMENT=staging ENV_FILE=.env.staging ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
#   ENVIRONMENT=production ENV_FILE=.env.production ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
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
  ENVIRONMENT       If set (e.g. development), sync job IDs to that GitHub Environment only
  DRY_RUN           If 1, print actions only (secrets redacted)

Repository-level (ENVIRONMENT unset):
  Secret:   DBT_API_KEY
  Variables: DBT_ACCOUNT_ID, DBT_URL, DBT_PROJECT_ID_1, DBT_PROJECT_ID_2

Per GitHub Environment (ENVIRONMENT=development|staging|production):
  Variables: DBT_JOB_CI_1, DBT_JOB_CI_2, DBT_JOB_CD_1, DBT_JOB_CD_2
  Optional secret: DBT_API_KEY (overrides repo secret for jobs using that environment)
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
  set_var_env "${GITHUB_ENV_NAME}" DBT_JOB_CI_1
  set_var_env "${GITHUB_ENV_NAME}" DBT_JOB_CI_2
  set_var_env "${GITHUB_ENV_NAME}" DBT_JOB_CD_1
  set_var_env "${GITHUB_ENV_NAME}" DBT_JOB_CD_2
  set_secret_env "${GITHUB_ENV_NAME}" DBT_API_KEY
  echo ""
  echo "Done. Verify: gh variable list -R ${REPO} --env ${GITHUB_ENV_NAME}"
else
  echo "Syncing repository-level Actions config to repo: ${REPO}"
  echo ""
  set_secret DBT_API_KEY
  set_var DBT_ACCOUNT_ID
  set_var DBT_URL
  set_var DBT_PROJECT_ID_1
  set_var DBT_PROJECT_ID_2
  echo ""
  echo "Done. Verify: gh secret list -R ${REPO} && gh variable list -R ${REPO}"
  echo "Then push per-environment job IDs: ENVIRONMENT=development ENV_FILE=.env.development $0 ${REPO}"
fi
