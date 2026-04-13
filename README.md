# dbt_dugout

Monorepo example for **multiple dbt projects** wired to **dbt Cloud** with **GitHub Actions** for CI (pull requests) and CD (pushes to the default branch). Workflows call the dbt Cloud Admin API, wait for runs to finish, and (on CI) post a sticky comment on the PR with a link to the dbt Cloud run. Heavy lifting stays in dbt Cloud—Actions is orchestration only.

## Architecture (short)

1. **Path filters** decide which logical project (`project_1`, `project_2`) changed.
2. **Python** triggers the right **dbt Cloud job** and polls until success or failure ([`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py)).
3. **CI** runs on `pull_request`; **CD** runs on `push` to `main` or `master` ([workflows](#github-actions-workflows) below).
4. **Optional:** self-hosted runners on **GitHub Enterprise Server** plus AWS—see [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh).

Prior art for the API pattern: [Github Actions for Triggering dbt CI and Merge Jobs](https://gist.github.com/trouze/26e578d92cd803514f29f6a33d5fd2cd).

## Repository map

| Area | Path | Role |
|------|------|------|
| dbt project (example 1) | [`first_dbt_project/`](first_dbt_project/) | Matches `project_1` path filter in workflows |
| dbt project (example 2) | [`second_dbt_project/`](second_dbt_project/) | Matches `project_2` path filter |
| CI workflow | [`.github/workflows/dbt-cloud-ci.yml`](.github/workflows/dbt-cloud-ci.yml) | PR → dbt Cloud CI jobs → PR comment |
| CD workflow | [`.github/workflows/dbt-cloud-cd.yml`](.github/workflows/dbt-cloud-cd.yml) | Push to default branch → dbt Cloud deploy jobs |
| dbt Cloud API helper | [`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py) | Trigger job, poll, optional sticky PR comment via GitHub API |
| Push secrets/vars to GitHub | [`scripts/gh-sync-dbt-cloud-actions-env.sh`](scripts/gh-sync-dbt-cloud-actions-env.sh) | Uses `gh` CLI from a `.env` file |
| Env template | [`scripts/.env.example`](scripts/.env.example) | Copy to `.env` (gitignored); fill values for sync script |
| GHES runner on AWS (optional) | [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh) | EC2 user-data + optional dbt Cloud HTTPS egress rules on security groups |
| CODEOWNERS check (optional) | [`.github/workflows/codeowners-check.yml`](.github/workflows/codeowners-check.yml) | Separate hygiene workflow |

Edit the **`filters:`** blocks in both dbt Cloud workflows so `project_1` / `project_2` glob paths match **your** directories. Matrix keys (`project_1`, `project_2`) must match those filter names.

## Setup (end-to-end)

### 1. dbt Cloud

- Create **two dbt Cloud projects** (or one project with two jobs—your choice), each pointing at the correct **subdirectory** of this repo (`first_dbt_project`, `second_dbt_project`, or whatever you rename them to).
- Add a **CI-oriented job** per project (PR branch, schema override, defer/state as you prefer).
- Add a **CD-oriented job** per project (default branch / production target).
- Enable **GitHub** integration where you need PR metadata in dbt Cloud.
- Note **account id**, **project ids**, and **job ids** for the next step.

### 2. GitHub repository secrets and variables

Required naming matches the workflows:

- **Secret:** `DBT_API_KEY` (dbt Cloud token with permission to trigger jobs).
- **Variables:** `DBT_ACCOUNT_ID`, `DBT_PROJECT_ID_1`, `DBT_JOB_CI_1`, `DBT_JOB_CD_1`, `DBT_PROJECT_ID_2`, `DBT_JOB_CI_2`, `DBT_JOB_CD_2`.
- **Optional variable:** `DBT_URL` if you use a single-tenant or regional dbt Cloud host (otherwise defaults apply in code).

**Bulk load via `gh`:** copy [`scripts/.env.example`](scripts/.env.example) to `.env`, fill it in, then run:

```bash
chmod +x scripts/gh-sync-dbt-cloud-actions-env.sh
ENV_FILE=.env ./scripts/gh-sync-dbt-cloud-actions-env.sh owner/repo
```

Use `DRY_RUN=1` first if you want a no-op preview. See the script header for `GH_REPO` and other options.

### 3. Branch protection

- Require the **dbt Cloud CI** check(s) on pull requests before merge.
- Restrict pushes to `main` / `master` if you rely on **CD** only after merge.

### 4. GitHub Enterprise Server (optional)

- GitHub.com demos can use `runs-on: ubuntu-latest`.
- **GHES** without hosted runners: provision **self-hosted** runners (labels must match `runs-on` in [`.github/workflows/dbt-cloud-ci.yml`](.github/workflows/dbt-cloud-ci.yml) and [`.github/workflows/dbt-cloud-cd.yml`](.github/workflows/dbt-cloud-cd.yml)).
- Use [`scripts/deploy-ghe-actions-runner-aws.sh`](scripts/deploy-ghe-actions-runner-aws.sh) for an AWS EC2–based bootstrap pattern; adjust `RUNNER_LABELS` and workflow `runs-on` together.
- Ensure outbound **HTTPS** to your GHES host and to **dbt Cloud** (the script can add security group egress to a fixed dbt Cloud IP list—verify current IPs with dbt’s documentation).

### 5. Extending to more projects

- Add a new filter key (e.g. `project_3`) and paths in **both** workflows.
- Add a matrix row and new repository variables (`DBT_PROJECT_ID_3`, `DBT_JOB_CI_3`, `DBT_JOB_CD_3`).
- Extend [`scripts/gh-sync-dbt-cloud-actions-env.sh`](scripts/gh-sync-dbt-cloud-actions-env.sh) and [`scripts/.env.example`](scripts/.env.example) if you want the sync script to push those too.

## CI PR comments (optional toggles)

[`scripts/dbt_cloud/call_dbt_job.py`](scripts/dbt_cloud/call_dbt_job.py) posts or updates a sticky comment when `GITHUB_TOKEN`, `GITHUB_REPOSITORY`, `GH_PULL_REQUEST_ID`, and `DBT_CI_MATRIX_PROJECT` are set (as in the CI workflow). Set `GH_PR_COMMENT=false` to disable.

## Related files

- [`.gitignore`](.gitignore) — includes `.env` so local credentials are not committed.
