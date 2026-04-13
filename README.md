# dbt_dugout

Monorepo example for **multiple dbt projects** wired to **dbt Cloud** with **GitHub Actions** for CI (pull requests) and CD (pushes). Workflows call the dbt Cloud Admin API, wait for runs to finish, and (on CI) post a sticky PR comment with a link to the dbt Cloud run. Execution stays in dbt Cloud—Actions orchestrates only.

**Branch → environment mapping**

| Branch (PR base / push) | GitHub Environment | Typical use |
|-------------------------|--------------------|-------------|
| `dev` | `development` | Pre-prod |
| `staging` | `staging` | Pre-prod |
| `main` | `production` | Prod |

CI and CD each use a **strategy matrix**: `environment` × `project`. Every matrix cell runs with `environment: ${{ matrix.environment }}`, so **environment-scoped variables**, **secrets**, and **protection rules** apply per deployment tier. An `if:` on the job matches **PR base branch** (CI) or **push branch** (CD) to the right GitHub Environment so only the relevant cells run.

## Architecture (short)

1. **Path filters** decide which logical project (`project_1`, `project_2`) changed.
2. **Python** triggers the right **dbt Cloud job** and polls ([`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py)).
3. **CI**: one matrix job (3 environments × 2 projects); each combination is gated by **PR base branch** + paths.
4. **CD**: one matrix job; each combination is gated by **push branch** + paths.
5. **Optional:** self-hosted runners on **GitHub Enterprise Server**—[`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh).

Prior art: [Github Actions for Triggering dbt CI and Merge Jobs](https://gist.github.com/trouze/26e578d92cd803514f29f6a33d5fd2cd).

## Repository map

| Area | Path | Role |
|------|------|------|
| dbt project (example 1) | [`first_dbt_project/`](first_dbt_project/) | `project_1` path filter |
| dbt project (example 2) | [`second_dbt_project/`](second_dbt_project/) | `project_2` path filter |
| CI workflow | [`.github/workflows/dbt-cloud-ci.yml`](.github/workflows/dbt-cloud-ci.yml) | PR → environments → dbt Cloud CI jobs → PR comment |
| CD workflow | [`.github/workflows/dbt-cloud-cd.yml`](.github/workflows/dbt-cloud-cd.yml) | Push `dev` / `staging` / `main` → deploy jobs |
| dbt Cloud API helper | [`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py) | Trigger job, poll, optional sticky PR comment |
| Push secrets/vars | [`scripts/gh-sync-dbt-cloud-actions-env.sh`](scripts/gh-sync-dbt-cloud-actions-env.sh) | Repo-level + per-environment via `gh` |
| Env template | [`scripts/.env.example`](scripts/.env.example) | Copy to `.env` / `.env.development` etc. |
| GHES runner (optional) | [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh) | EC2 + optional dbt Cloud egress rules |
| CODEOWNERS (optional) | [`.github/workflows/codeowners-check.yml`](.github/workflows/codeowners-check.yml) | Hygiene workflow |

Edit **`filters:`** in both dbt Cloud workflows if your directories differ.

## Setup

### 1. GitHub Environments

In the repo: **Settings → Environments** — create **`development`**, **`staging`**, **`production`**.

On **each** environment, add **variable**:

- `DBT_PROJECTS`

Optionally add **`DBT_API_KEY`** as an **environment secret** on `production` (or all envs) so tokens differ by tier; otherwise use a single **repository** secret (see below).

Configure **protection rules** on `production` (required reviewers, deployment branches) as needed.

### 2. Repository-level variables and secret

**Settings → Secrets and variables → Actions → Variables** (repository):

- `DBT_ACCOUNT_ID`
- Optional: `DBT_URL` (single-tenant / regional dbt Cloud host)

**Secrets** (repository): `DBT_API_KEY` if you are not using per-environment API keys.

### 3. dbt Cloud

For each GitHub environment, create matching **dbt Cloud environments** and **jobs** (CI + deploy) per monorepo project; paste job IDs into the GitHub Environment variables above.

### 4. Sync with `gh`

Repository-level:

```bash
chmod +x scripts/gh-sync-dbt-cloud-actions-env.sh
ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
```

Per GitHub Environment (repeat with different files):

```bash
ENVIRONMENT=development ENV_FILE=.env.development ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=staging ENV_FILE=.env.staging ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=production ENV_FILE=.env.production ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
```

Use `DRY_RUN=1` to preview. See [`scripts/.env.example`](scripts/.env.example).

### 5. Branch protection

Configure **required status checks** per target branch (e.g. require `dbt Cloud CI — production — project_1` on `main`). Skipped jobs do not block merges.

### 6. GitHub Enterprise Server (optional)

Use self-hosted runners and align `runs-on` with your labels. See [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh).

### 7. Adding a third dbt project

- Add `project_3` to path filters in **both** workflows.
- Add three new `matrix.include` rows per environment (one per `project_3`), with `dbt_project_id: ${{ vars.DBT_PROJECT_ID_3 }}` and `dbt_cloud_job_id: ${{ vars.DBT_JOB_CI_3 }}` / `DBT_JOB_CD_3` as appropriate.
- Add `DBT_PROJECT_ID_3` (repository) and per-environment `DBT_JOB_CI_3` / `DBT_JOB_CD_3`; extend [`scripts/gh-sync-dbt-cloud-actions-env.sh`](scripts/gh-sync-dbt-cloud-actions-env.sh) and [`scripts/.env.example`](scripts/.env.example).

## CI PR comments

[`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py) updates a sticky comment when `DBT_CI_MATRIX_PROJECT` is set. Set `GH_PR_COMMENT=false` to disable.

## Related files

- [`.gitignore`](.gitignore) — includes `.env`.
