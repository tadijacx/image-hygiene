# Image Hygiene — Internal Design Document

## Overview

Image Hygiene is a monthly maintenance process that keeps container images in Azure Container Registry (ACR) fresh and the registry lean. It has three sequential phases:

```
dispatch_all.sh  →  bump.sh  →  cleanup_acr.sh
(rebuild images)    (update k8s)   (delete stale tags)
```

All three scripts are driven by the same lookup CSV (`Maps/lookup-service-non-mol.csv`) and operate on the same ACR (`acxcr`) and k8s repo (`beacx/acx-kubernetes-app`).

---

## The Lookup CSV

**Path:** `Maps/lookup-service.csv`

**Columns:**

| Column | Description |
|---|---|
| `github_repo` | GitHub repo name (under `beacx/`) |
| `acr_repo` | ACR repository name in `acxcr` |
| `chart_dir` | Directory under `charts/` in the k8s repo |
| `prod_prefix` | Tag prefix for prod-like builds (e.g. `master`, `main`) |
| `dev_prefix` | Tag prefix for dev-like builds (e.g. `dev`, `stage`) |

**Fill-down rule:** If `github_repo` is blank in a row, it inherits from the row above. This lets one GitHub repo map to multiple ACR repos or chart directories without repetition:

```csv
Internal-Api,internal-api,internal-api/api,master-api-service,dev-api-service
,internal-api,internal-api/interop,master-api-interop,dev-api-interop
```

**Skipped rows:** A row is silently skipped if `dev_prefix` or `prod_prefix` is empty or `/` for the selected mode. Some services (e.g. most ML services) have no dev-like build.

---

## Tag Convention

All ACR tags follow:

```
<prefix>-<7-char-sha>[-vN]
```

Examples: `master-abc1234`, `dev-abc1234`, `dev-abc1234-v2`

The prefix encodes the branch (`master`, `dev`, `stage`, `dev-api-service`, etc.). The optional `-vN` suffix is appended by the dispatcher when the same commit is rebuilt (same sha, different run).

Scripts derive the prefix from a tag by stripping the sha and optional version suffix:
- `dev-abc1234-v2` → `dev`
- `master-api-service-abc1234` → `master-api-service`

---

## Phase 1: Dispatch (`dispatch_all.sh`)

**What it does:** For each row in the CSV, checks whether the newest ACR tag with the matching prefix is older than `STALE_DAYS` (default: 30). If stale or absent, triggers the `dispatcher.yaml` workflow in the service's GitHub repo to rebuild and push a fresh image.

**Key variables:**

| Variable | Default | Effect |
|---|---|---|
| `DRY_RUN` | `1` | `0` = actually dispatch; anything else = print only for testing |
| `STALE_DAYS` | `30` | Age threshold in days |
| `ACR_NAME` | `acxcr` | ACR instance |
| `MAP_FILE` | `lookup-service.csv` | Lookup CSV |
| `WORKFLOW_PATH` | `.github/workflows/dispatcher.yaml` | Workflow file path in each repo |

**Run safely (dry run):**
```bash
DRY_RUN=1 ./Scripts/dispatch_all.sh
```

**Run for real:**
```bash
DRY_RUN=0 ./Scripts/dispatch_all.sh "monthly refresh March"
```

**What it calls per service:**
1. `az acr repository show-tags` — finds newest tag for the prefix
2. `gh repo view` — resolves the repo's default branch (workflow must exist there)
3. `gh workflow run` — triggers the dispatch (only if `DRY_RUN=0`)

**Note:** The optional positional argument (`$1`) becomes the `reason` input passed to the workflow. Default: `"bulk refresh"`.

---

## Phase 2: Bump (`bump.sh`)

**What it does:** Clones `beacx/acx-kubernetes-app`, checks each service's current tag in the relevant Helm `values-*.yaml` file, looks up the latest ACR tag for the same prefix, and updates the file in-place. Commits all changes to a new branch and opens a PR.

**Key variables:**

| Variable | Default | Effect |
|---|---|---|
| `DRY_RUN` | `0` | `1` = print only, no changes; `0` = create PR |
| `ACR_NAME` | `acxcr` | ACR instance |
| `DEVOPS_REPO` | `beacx/acx-kubernetes-app` | k8s repo |
| `MAP_FILE` | `lookup_service-2repotest.csv` | Lookup CSV |

**Run (default — creates PR):**
```bash
./Scripts/bump.sh
```

**Run dry:**
```bash
DRY_RUN=1 ./Scripts/bump.sh
```

**Values file selection:** For each chart, the script searches for a values file in priority order:
- **dev-like:** `values-dev.yaml` → `values-stage.yaml` → `values-staging.yaml` 
- **prod-like:** `values-prod.yaml` → `values-master.yaml`
- Falls back to the first `values-*.yaml` found.

**PR output:** Branch is named `image-bump/<mode>-<timestamp>`, targeting `dev` or `master` depending on mode. The PR body lists every updated service with old → new tags.

**After the PR is merged,** Argo CD picks up the new tags and rolls out the updated images. Wait for rollout before proceeding to cleanup.

---

## Phase 3: Cleanup (`cleanup_acr.sh`)

**What it does:** For each service, reads the current tag from the k8s repo (across all three protected branches), derives the prefix, lists all ACR tags for that prefix ordered newest-first, and deletes everything beyond `KEEP_COUNT` (default: 3) — never touching protected tags.

**Key variables:**

| Variable | Default | Effect |
|---|---|---|
| `DRY_RUN` | `1` | `1` = print only; `0` = actually delete (also requires `ALLOW_REAL_DELETE=1`) |
| `ALLOW_REAL_DELETE` | `0` (hardcoded) | Must be manually set to `1` in the script to enable real deletion |
| `KEEP_COUNT` | `3` | Tags to keep per prefix (protected tags always kept, then newest fill up to this count) |
| `ACR_NAME` | `acxcr` | ACR instance |
| `DEVOPS_REPO` | `beacx/acx-kubernetes-app` | k8s repo |
| `MAP_FILE` | `Maps/lookup-service.csv` | Lookup CSV |
| `K8S_BRANCH_DEVLIKE` | `dev` | Dev branch of k8s repo |
| `K8S_BRANCH_DEV_EASTUS` | `dev-eastus` | East US dev branch |
| `K8S_BRANCH_PRODLIKE` | `master` | Prod branch |

**Double gate:** Real deletion requires **both** `DRY_RUN=0` AND `ALLOW_REAL_DELETE=1`. The `ALLOW_REAL_DELETE` flag is hardcoded to `0` and must be edited in the script file before running — this is intentional to prevent accidental deletion.

**Run dry (default):**
```bash
./Scripts/cleanup_acr.sh
```

**Run for real:**
```bash
# 1. Edit the script: change ALLOW_REAL_DELETE=0 to ALLOW_REAL_DELETE=1
# 2. Then run:
DRY_RUN=0 ./Scripts/cleanup_acr.sh
```

**Protection logic:**
1. The script reads the referenced tag from all three k8s branches (`dev`, `dev-eastus`, `master`) using `git cat-file` — no checkout required.
2. Any tag currently referenced in any branch is added to the protected set.
3. Only tags sharing the same derived prefix as the current tag are considered for deletion — if a chart switched prefixes, the old prefix tags are untouched.
4. If no protected tags match the prefix, the service is skipped entirely (safety net).
5. Keep list = protected tags + newest tags until `KEEP_COUNT` is reached.

---

## Running the Full Monthly Process

### Prerequisites
- `az` logged in with access to `acxcr`
- `gh` authenticated with write access to service repos and `beacx/acx-kubernetes-app`
- `git` and `python3` in PATH

### Step 1 — Audit current state
```bash
./Scripts/dispatch-inspect_only.sh
# Select: 3 (both)
```

### Step 2 — Dispatch (dry run first)
```bash
DRY_RUN=1 ./Scripts/dispatch_all.sh
# Review output, then:
DRY_RUN=0 ./Scripts/dispatch_all.sh "monthly refresh $(date +%B)"
# Select: 3 (both)
```
Wait for GitHub Actions workflows to complete across all repos (can take 10–30 min).

### Step 3 — Bump (creates PR)
```bash
./Scripts/bump.sh
# Select: 3 (both)
```
Review the PR, then merge. Wait for Argo CD to roll out all updated images before proceeding.

### Step 4 — Cleanup (dry run first)
```bash
./Scripts/cleanup_acr.sh
# Select: 3 (both), review output carefully
```
If the dry run looks correct, edit `ALLOW_REAL_DELETE=0` → `1` in `cleanup_acr.sh`, then:
```bash
DRY_RUN=0 ./Scripts/cleanup_acr.sh
# Select: 3 (both)
```
Reset `ALLOW_REAL_DELETE` back to `0` after.

---

## Adding a New Service to the Map

1. Add a row to `Maps/lookup-service.csv`:
   ```csv
   MyNewService,mynewservice,my-new-service,master,dev
   ```
   - `github_repo`: exact repo name under `beacx/`
   - `acr_repo`: ACR repository name (lowercase, no spaces)
   - `chart_dir`: directory name under `charts/` in `beacx/acx-kubernetes-app`
   - `prod_prefix`: branch name used for prod builds (usually `master` or `main`)
   - `dev_prefix`: branch name used for dev builds (usually `dev` or `stage`); leave blank if none

2. If the service has multiple ACR repos or chart dirs (e.g. an API with separate `api` and `interop` charts), add additional rows with the `github_repo` column left blank — fill-down will carry it forward:
   ```csv
   MyNewService,mynewservice,my-new-service/api,master-api-service,dev-api-service
   ,mynewservice,my-new-service/interop,master-api-interop,dev-api-interop
   ```

3. Make sure the dispatcher workflow is in place (see next section).

---

## Adding the Dispatcher Workflow to a New Service

Copy `Scripts/dispatcher_template.yaml` to `.github/workflows/dispatcher.yaml` in the service repo and fill in two fields:

```yaml
# Line 9 — set the repo's default branch
default: master   # or dev, main, etc.

# Line 21 — set the ACR repository name (must match acr_repo in the CSV)
ACR_REPOSITORY: mynewservice
```

The workflow requires these secrets to be configured on the repo (they are typically inherited from the org):

| Secret | Purpose |
|---|---|
| `REGISTRY_LOGIN_SERVER` | ACR login server URL |
| `REGISTRY_USERNAME` | ACR username |
| `REGISTRY_PASSWORD` | ACR password |
| `AZURE_CREDENTIALS` | Azure service principal JSON for `azure/login` |
| `GH_USER` | GitHub user for private package access during build |
| `GH_KEY` | GitHub PAT for private package access during build |

**How the workflow tags images:** It looks up the latest existing tag for the branch prefix in ACR. If the commit sha changed, it uses `<branch>-<sha>`. If the same commit is being rebuilt (e.g. base image update), it appends `-vN` (e.g. `master-abc1234-v2`). This ensures every build produces a unique, traceable tag.

---

## Troubleshooting

**`dispatch_all.sh` skips a service with "Could not determine default branch"**
The script cannot reach the GitHub repo. Check `gh auth status` and confirm the repo name in the CSV is correct.

**`bump.sh` skips a service with "Could not read current tag"**
The k8s chart's values file doesn't have a `tag:` field, or the `chart_dir` in the CSV doesn't match the actual directory under `charts/`. Verify with:
```bash
ls beacx/acx-kubernetes-app/charts/<chart_dir>/values-*.yaml
```

**`cleanup_acr.sh` skips a service with "No protected tags matched prefix"**
The prefix derived from the k8s tag doesn't match any tag currently in ACR for that prefix. This usually means the service was recently migrated to a different branch/prefix. Investigate manually before enabling deletion.

**`bump.sh` says "Already up to date" for everything**
The dispatcher workflows haven't finished yet, or they failed. Check the Actions tab on the relevant repos.
