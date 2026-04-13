# dbt_dugout

Monorepo template for **multiple dbt projects** wired to **dbt Cloud** via **GitHub Actions** CI/CD. On a pull request, only the projects whose files changed get a CI run. On a push, only changed projects get deployed. Execution stays in dbt Cloud — Actions orchestrates only.

**Branch → environment mapping**

| Branch (PR base / push) | GitHub Environment |
|-------------------------|--------------------|
| `dev` | `development` |
| `staging` | `staging` |
| `main` | `production` |

## How it works

1. A **`detect` job** checks out the repo, resolves the target GitHub Environment from the branch name, and runs `dorny/paths-filter` against `.github/path-filters.yml` to produce a JSON array of changed project keys.
2. A **matrix job** fans out over that array — one job per changed project — and calls the reusable workflow `.github/workflows/_dbt-cloud-run.yml`.
3. The **reusable workflow** sets `environment: <env>` so GitHub resolves per-environment variables, then runs `scripts/dbt_cloud/runner.py`.
4. **`runner.py`** reads the `DBT_PROJECTS` JSON variable, looks up the project's IDs, and calls `run_project()` from `call_dbt_job.py` to trigger and poll the dbt Cloud job.
5. A **`ci-complete` / `cd-complete` gate job** provides a single stable check name for branch protection rules regardless of how many projects ran.

## Repository map

| Path | Role |
|------|------|
| `.github/path-filters.yml` | Maps project keys to file paths — **edit this for your projects** |
| `.github/workflows/dbt-cloud-ci.yml` | PR trigger: detect → matrix CI → gate |
| `.github/workflows/dbt-cloud-cd.yml` | Push trigger: detect → matrix CD → gate |
| `.github/workflows/_dbt-cloud-run.yml` | Reusable workflow (one project, one env) |
| `scripts/dbt_cloud/runner.py` | Unified single-project runner |
| `scripts/dbt_cloud/call_dbt_job.py` | dbt Cloud API: trigger, poll, sticky PR comment |
| `scripts/gh-sync-dbt-cloud-actions-env.sh` | Push secrets/vars to GitHub via `gh` CLI |
| `scripts/.env.example` | Template for `.env` / `.env.<environment>` files |

---

## Setup

### 1. Replace example projects with your own

**`.github/path-filters.yml`** maps a short key to the directory paths that belong to each dbt project. Edit this file to match your repo layout:

```yaml
# .github/path-filters.yml
analytics:
  - 'analytics/**'
finance:
  - 'finance/**'
```

The keys (`analytics`, `finance`) are what you will reference everywhere else. You can have as many projects as you need.

### 2. Create GitHub Environments

In your repo: **Settings → Environments** — create three environments:

- `development`
- `staging`
- `production`

On `production`, configure protection rules (required reviewers, deployment branch `main`) as needed.

### 3. Add the `DBT_PROJECTS` variable to each environment

On **each** GitHub Environment, create a variable named **`DBT_PROJECTS`** whose value is a JSON object mapping your project keys to their dbt Cloud IDs:

```json
{
  "analytics": {
    "project_id": "111",
    "ci_job_id":  "222",
    "cd_job_id":  "333"
  },
  "finance": {
    "project_id": "444",
    "ci_job_id":  "555",
    "cd_job_id":  "666"
  }
}
```

The values will differ per environment (each environment has its own dbt Cloud jobs). Get these IDs from dbt Cloud: **Deploy → Jobs → <job> → Settings** — the job ID is in the URL.

### 4. Add repository-level variables and secret

**Settings → Secrets and variables → Actions**

Variables (repository-level, shared across environments):

| Name | Value |
|------|-------|
| `DBT_ACCOUNT_ID` | Your dbt Cloud account ID (found in dbt Cloud URL: `/accounts/<id>/`) |
| `DBT_URL` | _(optional)_ Custom dbt Cloud host, e.g. `https://emea.dbt.com` — omit for the default `https://cloud.getdbt.com` |

Secrets (repository-level):

| Name | Value |
|------|-------|
| `DBT_API_KEY` | dbt Cloud service token with **Job Admin** permissions |

If you need different API keys per tier, add `DBT_API_KEY` as an **environment secret** on the relevant environments — it overrides the repository secret.

### 5. Sync variables using the helper script

Copy `scripts/.env.example` to `.env` and fill in the shared values:

```bash
cp scripts/.env.example .env
# edit .env: set DBT_API_KEY, DBT_ACCOUNT_ID, optionally DBT_URL
```

Create per-environment files (e.g. `.env.development`) containing the `DBT_PROJECTS` JSON for that environment:

```bash
# .env.development
DBT_PROJECTS='{"analytics":{"project_id":"111","ci_job_id":"222","cd_job_id":"333"},"finance":{"project_id":"444","ci_job_id":"555","cd_job_id":"666"}}'
```

Push everything to GitHub:

```bash
chmod +x scripts/gh-sync-dbt-cloud-actions-env.sh

# Repository-level secret + variables
ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo

# Per-environment variables (repeat for staging and production)
ENVIRONMENT=development  ENV_FILE=.env.development  ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=staging      ENV_FILE=.env.staging      ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
ENVIRONMENT=production   ENV_FILE=.env.production   ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
```

Use `DRY_RUN=1` to preview what would be set without making changes.

### 6. Configure branch protection

The matrix produces variable check names (`ci — analytics`, `ci — finance`, etc.) that change as projects are added or removed. Use the **gate jobs** as your required status checks instead — they are always present and stable:

| Workflow | Gate job name | Use as required check on |
|----------|---------------|--------------------------|
| CI | `dbt Cloud CI` | all target branches (`dev`, `staging`, `main`) |
| CD | `dbt Cloud CD` | _(informational; branch protection is usually CI-only)_ |

In **Settings → Branches → Branch protection rules**, add `dbt Cloud CI` as a required status check on each protected branch.

---

## Adding a new dbt project

Only two changes are needed:

1. **`.github/path-filters.yml`** — add an entry:
   ```yaml
   marketing:
     - 'marketing/**'
   ```

2. **`DBT_PROJECTS`** on each GitHub Environment — add the new project's IDs to the JSON:
   ```json
   {
     "analytics": { ... },
     "finance":   { ... },
     "marketing": { "project_id": "777", "ci_job_id": "888", "cd_job_id": "999" }
   }
   ```

No workflow YAML changes. No Python changes.

---

## CI PR comments

After each CI run, `call_dbt_job.py` upserts a sticky comment on the PR with a link to the dbt Cloud run. The comment is keyed by project so multiple projects each get their own comment block. Set `GH_PR_COMMENT=false` on the workflow step (or as a repo variable) to disable.

## GitHub Enterprise Server (optional)

Use self-hosted runners and update `runs-on` in `_dbt-cloud-run.yml` to match your runner labels. See [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh) for an EC2-based runner setup.
