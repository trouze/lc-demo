# dbt Cloud Promotion — Monorepo Reference

Reference implementation for promoting dbt models across environments in a two-project monorepo backed by dbt Cloud. GitHub Actions workflows are the reference architecture; Jenkinsfiles are the active deployment artifact today.

## Branch & environment model

| Branch | Who works here | GitHub Environments | dbt Cloud environments |
|--------|---------------|--------------------|-----------------------|
| `feature/*` | Individual developers | — | `user-development` (IDE / dbt Cloud scheduler) |
| `develop` | Integration / staging | `staging` | `dev-deploy`, `staging` |
| `main` | Trunk | — | — |
| `release/*` (fork) | Release | `pre-prod`, `prod` | `pre-prod`, `prod` |

Flow: `feature/*` → PR → merge to `develop` → staging deploy fires → release manager cuts `release/<n>` in the fork → branch flip updates pre-prod/prod.

## Two artifacts, one source of truth

The GHA workflows in `.github/workflows/` are the authoritative design. The `Jenkinsfile.*` at the repo root mirror the same logic for the current Jenkins runtime. When the customer migrates to GitHub Actions the Jenkinsfiles become obsolete.

## Workflows

| File | Trigger | What it does |
|------|---------|-------------|
| `merge-to-staging.yml` | `push` on `develop` (feature PR merge) | Path-filters changed folders, fans out a matrix deploy job per changed project, waits for dbt Cloud staging job to complete |
| `release-branch-flip.yml` | `push` on `release/**` (in fork) or `workflow_dispatch` | PATCHes the dbt Cloud environment `custom_branch` to the active `release/*` branch for every folder × `{pre-prod, prod}` |
| `codeowners-check.yml` | PRs | CODEOWNERS hygiene; unrelated to dbt Cloud |
| `Jenkinsfile.merge-to-staging` | Jenkins SCM trigger on `develop` | Same semantics as `merge-to-staging.yml` |
| `Jenkinsfile.release-branch-flip` | Multibranch pipeline on `release/**` | Same semantics as `release-branch-flip.yml`; includes manual `input` gate before prod |

## dbt Cloud setup

**Why 4 dbt Cloud projects?** A dbt Cloud project can link to exactly one Git repository. Because pre-prod and prod run from `release/*` branches that live in a fork, each monorepo folder must back two dbt Cloud projects:

| dbt Cloud project | Git connection | Environments |
|-------------------|---------------|-------------|
| `first_dbt_project` — Trunk | this repo | `user-development`, `dev-deploy`, `staging` |
| `first_dbt_project` — Release | fork | `pre-prod`, `prod` |
| `second_dbt_project` — Trunk | this repo | `user-development`, `dev-deploy`, `staging` |
| `second_dbt_project` — Release | fork | `pre-prod`, `prod` |

That gives **4 dbt Cloud projects** and **10 environments** total. Automation (Actions / Jenkins) only touches `staging`, `pre-prod`, and `prod`. `user-development` and `dev-deploy` run via the dbt Cloud scheduler or IDE.

## Secrets & variables

### Repository-level (all environments share these)

| Name | Type | Value |
|------|------|-------|
| `DBT_API_KEY` | Secret | dbt Cloud service-account token |
| `DBT_ACCOUNT_ID` | Variable | dbt Cloud account ID |
| `DBT_URL` | Variable | Base URL (default `https://cloud.getdbt.com`; omit for multi-tenant) |

### Per GitHub Environment — `staging`

Variable `DBT_PROJECTS` (Trunk dbt Cloud project per folder):

```json
{
  "first_dbt_project":  {"project_id": "<trunk project id>",  "staging_merge_job_id": "<deploy job id>"},
  "second_dbt_project": {"project_id": "<trunk project id>",  "staging_merge_job_id": "<deploy job id>"}
}
```

### Per GitHub Environment — `pre-prod` and `prod`

Variable `DBT_PROJECTS` (Release dbt Cloud project per folder; set separately per environment):

```json
{
  "first_dbt_project":  {"project_id": "<release project id>", "environment_id": "<env id>"},
  "second_dbt_project": {"project_id": "<release project id>", "environment_id": "<env id>"}
}
```

### Jenkins credential IDs

| Credential ID | Scope |
|---------------|-------|
| `dbt-cloud-api-key` | all pipelines |
| `dbt-cloud-account-id` | all pipelines |
| `dbt-projects-staging` | `Jenkinsfile.merge-to-staging` |
| `dbt-projects-pre-prod` | `Jenkinsfile.release-branch-flip` |
| `dbt-projects-prod` | `Jenkinsfile.release-branch-flip` |

## Setup

### 1. GitHub Environments

**Settings → Environments** — create `staging`, `pre-prod`, `prod`.

On each environment add the `DBT_PROJECTS` variable with the schema shown above. Optionally add a per-environment `DBT_API_KEY` secret to override the repo-level token.

Configure required reviewers and deployment branch rules on `prod` as needed.

### 2. Repository-level variables and secret

**Settings → Secrets and variables → Actions → Variables**: `DBT_ACCOUNT_ID`, `DBT_URL`.
**Secrets**: `DBT_API_KEY`.

### 3. Sync with `gh`

```bash
chmod +x scripts/gh-sync-dbt-cloud-actions-env.sh

# Repository-level
ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo

# Per environment (repeat for each)
ENVIRONMENT=staging  ENV_FILE=.env.staging  ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=pre-prod ENV_FILE=.env.pre-prod ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=prod     ENV_FILE=.env.prod     ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
```

Use `DRY_RUN=1` to preview. See [`scripts/.env.example`](scripts/.env.example).

### 4. Fork setup for release pipelines

The fork must have its own `pre-prod` and `prod` GitHub Environments with `DBT_PROJECTS` variables pointing at the Release dbt Cloud project. Copy `release-branch-flip.yml` to the fork's `.github/workflows/` directory.

## Why no CI

There are no CI jobs in this estate. Contributors must validate changes locally via `dbt run` / `dbt test` in their `user-development` dbt Cloud environment before merging. The rationale is owned by the customer and can be added here.

## Release flow

1. Merge all feature work into `develop` (triggers `merge-to-staging.yml` → staging is updated).
2. Sync the fork with upstream: `git fetch upstream && git merge upstream/main`.
3. Cut `release/<n>` in the fork off `main`.
4. Push `release/<n>` → `release-branch-flip.yml` fires automatically, PATCHing the `pre-prod` dbt Cloud environment in the Release project to `release/<n>`.
5. Validate in pre-prod for ~1 week. Run the pre-prod deploy job manually or on schedule in dbt Cloud.
6. When ready to promote: trigger `release-branch-flip.yml` via the Actions UI → **Run workflow** → select `environment=prod` and supply `release_branch=release/<n>`.
7. Run the prod deploy job manually or on schedule in dbt Cloud.
8. Merge `release/<n>` to `main` in the fork when the release is complete.

## Adding a new dbt project folder

1. Add the new folder to `.github/path-filters.yml`.
2. Add an entry for the folder in `DBT_PROJECTS` for each GitHub Environment (`staging`, `pre-prod`, `prod`).
3. Add the folder name to the `PROJECT_NAME` axis in `Jenkinsfile.merge-to-staging` and `Jenkinsfile.release-branch-flip`.
4. Create the Trunk and Release dbt Cloud projects and the corresponding environments/jobs; paste the IDs into the `DBT_PROJECTS` JSON.

## Repository map

| Area | Path |
|------|------|
| dbt project 1 | [`first_dbt_project/`](first_dbt_project/) |
| dbt project 2 | [`second_dbt_project/`](second_dbt_project/) |
| Staging deploy workflow | [`.github/workflows/merge-to-staging.yml`](.github/workflows/merge-to-staging.yml) |
| Release branch-flip workflow | [`.github/workflows/release-branch-flip.yml`](.github/workflows/release-branch-flip.yml) |
| Jenkins — staging deploy | [`Jenkinsfile.merge-to-staging`](Jenkinsfile.merge-to-staging) |
| Jenkins — release flip | [`Jenkinsfile.release-branch-flip`](Jenkinsfile.release-branch-flip) |
| dbt Cloud job trigger + poller | [`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py) |
| dbt Cloud environment branch flip | [`scripts/dbt_cloud/update_env_branch.py`](scripts/dbt_cloud/update_env_branch.py) |
| Runner (ties runner + config together) | [`scripts/dbt_cloud/runner.py`](scripts/dbt_cloud/runner.py) |
| Push secrets/vars | [`scripts/gh-sync-dbt-cloud-actions-env.sh`](scripts/gh-sync-dbt-cloud-actions-env.sh) |
| Env template | [`scripts/.env.example`](scripts/.env.example) |
| GHES runner (optional) | [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh) |
