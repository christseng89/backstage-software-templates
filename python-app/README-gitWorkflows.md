# CI/CD Pipeline

This document covers the three GitHub Actions workflows generated into every repo scaffolded from the `python-app` Backstage template.

| Workflow file | Purpose | Trigger |
|---|---|---|
| `.github/workflows/<app_name>-cicd.yaml` | Build image + deploy to **dev** | Auto on `src/**` push |
| `.github/workflows/<app_name>-cd.yaml` | Deploy to **staging or prod** | Auto on values file change |
| `.github/workflows/mirror-cli-binaries.yaml` | Mirror `argocd`, `yq`, `kubectl` binaries to Docker Hub | Manual (`workflow_dispatch`) |

---

## Overview

```
src/** push to main
        │
        ▼
   ┌─────────┐
   │   ci    │  GitHub-hosted (ubuntu-latest)
   │         │  • builds multi-arch Docker image
   │         │  • pushes to Docker Hub as <app_name>:<commit_id>
   └────┬────┘
        │ commit_id
        ▼
   ┌─────────┐
   │  cd     │  Self-hosted ARC runner (linux)          cicd.yaml
   │  (dev)  │  • writes commit_id into values-dev.yaml
   │         │  • commits back to main
   │         │  • ArgoCD registers repo, creates/syncs <app_name>-dev
   └─────────┘
        │
        │   User edits values-staging.yaml or values-prod.yaml and commits
        ▼
   ┌─────────┐
   │  cd     │  Self-hosted ARC runner (linux)          cd.yaml
   │(stg/prd)│  • detects which env file changed
   │         │  • skips if image.tag is empty
   │         │  • ArgoCD registers repo, creates/syncs <app_name>-staging or <app_name>-prod
   └─────────┘
```

---

## `cicd.yaml` — Build + Deploy to Dev

### Triggers

| Event | Condition |
|---|---|
| `push` | Any change under `src/**` on `main` |
| `workflow_dispatch` | Manual re-run from Actions tab (no code change needed) |

### Environment Variables

| Variable | Source | Purpose |
|---|---|---|
| `ARGOCD_VERSION` | `vars.ARGOCD_VERSION` (repo variable) | ArgoCD CLI version pulled from Docker Hub mirror |
| `YQ_VERSION` | `vars.YQ_VERSION` (repo variable) | yq version pulled from Docker Hub mirror |
| `KUBECTL_VERSION` | `vars.KUBECTL_VERSION` (repo variable) | kubectl version pulled from Docker Hub mirror |
| `IMAGE_NAME` | hardcoded | `christseng89/<app_name>` Docker Hub image repository |
| `VALUES_PATH` | hardcoded | `charts/<app_name>/values-dev.yaml` — Helm values file updated by CD |
| `ARGOCD_APP` | hardcoded | `<app_name>-dev` — ArgoCD application name for dev |
| `ARGOCD_SERVER` | hardcoded | `argocd-server.argocd.svc.cluster.local` — in-cluster ArgoCD DNS |
| `ARGOCD_CHART_PATH` | hardcoded | `charts/<app_name>` — Helm chart path for ArgoCD app create |

To upgrade a tool version: update the repo variable in GitHub Settings → Variables (or pass the new version as input to `mirror-cli-binaries.yaml` which auto-updates it). The cache key includes the version string so the next run automatically invalidates and re-downloads.

### CI Job — Build and Push

Runs on `ubuntu-latest` (GitHub-hosted).

| Step | What it does |
|---|---|
| Checkout | Checks out the repo |
| Shorten commit id | Takes first 6 chars of `GITHUB_SHA` (e.g. `a1b2c3`); passed to CD job via `commit_id` output |
| Set up QEMU + Buildx | Enables cross-arch emulation for `linux/amd64` + `linux/arm64` builds |
| Login to Docker Hub | Authenticates with `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets |
| Build and push | Pushes `<app_name>:<commit_id>`; uses `<app_name>:buildcache` registry cache to save 60–120 s on warm builds |

### CD Job — Deploy to Dev

Runs on `[self-hosted, linux]` (ARC runner pod in-cluster).

| Step | What it does |
|---|---|
| Checkout | Checks out repo with `GITHUB_TOKEN` for push permission |
| Detect runner architecture | Sets `amd64` or `arm64` for tool downloads |
| Cache + install kubectl | Restores kubectl from `actions/cache`; on miss, pulls `christseng89/kubectl-bin:<version>` from Docker Hub and extracts via `docker cp` |
| Cache + install yq | Same mirror pattern; on miss, pulls `christseng89/yq-bin:<version>` |
| Update dev values file | Runs `yq -i '.image.tag = "<commit_id>"' values-dev.yaml` |
| Commit changes | Pushes updated `values-dev.yaml` to `main` with `--rebase --autostash` |
| Cache + install ArgoCD CLI | Same mirror pattern; cold run ~5–10 min, cached <1 s |
| ArgoCD login | Logs into ArgoCD server via in-cluster DNS with `--plaintext --grpc-web` |
| Register GitHub repo in ArgoCD | Runs `argocd repo add --username x-access-token --password GH_PAT --upsert` |
| Create ArgoCD app if absent | Checks `argocd app get`; if missing, runs `argocd app create` with automated sync policy |
| ArgoCD app sync | Runs `argocd app sync` + `argocd app wait --health --timeout 180` |
| Diagnose on failure | Dumps app state, pod events, and logs when any step above fails |

### Concurrency

```yaml
concurrency:
  group: cicd-${{ github.ref }}
  cancel-in-progress: false
```

One run per branch at a time. A second push waits rather than cancelling — ensures a CD job already writing `values-dev.yaml` and syncing ArgoCD is never killed mid-flight.

### Permissions

```yaml
permissions:
  contents: write
```

Required for the CD job to commit the updated `values-dev.yaml` back to `main`.

---

## `cd.yaml` — Deploy to Staging or Prod

### Triggers

| Event | Condition |
|---|---|
| `push` | Change to `charts/<app_name>/values-staging.yaml` or `values-prod.yaml` on `main` |
| `workflow_dispatch` | Manual re-sync (environment already set in values file) |

The typical flow is:
1. Edit `values-staging.yaml` or `values-prod.yaml` — set `image.tag` to the desired tag
2. Commit and push to `main`
3. `cd.yaml` triggers automatically, detects the environment, and syncs ArgoCD

### Environment Variables

| Variable | Source | Purpose |
|---|---|---|
| `ARGOCD_VERSION` | `vars.ARGOCD_VERSION` (repo variable) | ArgoCD CLI version |
| `KUBECTL_VERSION` | `vars.KUBECTL_VERSION` (repo variable) | kubectl version |
| `ARGOCD_SERVER` | hardcoded | `argocd-server.argocd.svc.cluster.local` — in-cluster ArgoCD DNS |
| `ARGOCD_CHART_PATH` | hardcoded | `charts/<app_name>` — Helm chart path for ArgoCD app create |

`DEPLOY_ENV` and `ARGOCD_APP` are set dynamically per run (see "Detect environment" step below).

### CD Job

Runs on `[self-hosted, linux]` (ARC runner pod in-cluster).

| Step | What it does |
|---|---|
| Checkout | Checks out the repo |
| Detect environment | On push: derives env from whichever values file changed (`staging` or `prod`). On `workflow_dispatch`: uses the `environment` input. Sets `DEPLOY_ENV` and `ARGOCD_APP=<app_name>-<env>` |
| Validate image tag | Reads `.image.tag` from the values file. If empty, prints a notice and skips all deployment steps |
| Detect runner architecture | Sets `amd64` or `arm64` |
| Cache + install kubectl | Same Docker Hub mirror pattern as `cicd.yaml` |
| Cache + install ArgoCD CLI | Same Docker Hub mirror pattern as `cicd.yaml` |
| ArgoCD login | Logs into ArgoCD server via in-cluster DNS |
| Register GitHub repo in ArgoCD | Runs `argocd repo add --upsert` with `GH_PAT` |
| Create ArgoCD app if absent | Checks `argocd app get`; if missing, creates `<app_name>-<env>` with automated sync policy |
| ArgoCD app sync | Runs `argocd app sync` + `argocd app wait --health --timeout 180` |
| Diagnose on failure | Dumps app state, pods, and logs — skipped if image tag was empty |

### Concurrency

```yaml
concurrency:
  group: cd-${{ github.event.inputs.environment }}-${{ github.ref }}
  cancel-in-progress: false
```

Serializes runs per environment. Staging and prod promotions can run in parallel with each other.

### Permissions

```yaml
permissions:
  contents: read
```

Read-only — the values file is already updated by the user's commit. No write-back needed.

---

## `mirror-cli-binaries.yaml` — Mirror CLI Binaries to Docker Hub

### Purpose

The self-hosted ARC runner pod runs inside the cluster where GitHub Releases downloads are slow or flaky from Asia. This workflow pre-mirrors the `argocd`, `yq`, and `kubectl` binaries to Docker Hub (Cloudflare CDN with Asia POPs) so both CD jobs can pull them quickly.

The three mirror images produced are:

| Docker Hub image | Binary |
|---|---|
| `christseng89/argocd-bin:<version>` | `/argocd` |
| `christseng89/yq-bin:<version>` | `/yq` |
| `christseng89/kubectl-bin:<version>` | `/kubectl` |

All are `FROM scratch` multi-arch images (`linux/amd64` + `linux/arm64`). No `docker login` is needed to pull them — they are public.

### When to Run

Run this workflow **before** bumping a version in the repo variables. The CD job's cache key includes the version string, so a version bump invalidates the cache and triggers a fresh pull — the mirror must already exist on Docker Hub or the pull will fail.

```
1. Run mirror-cli-binaries.yaml (Actions → Run workflow)
      argocd_version: v3.5.0   ← new version (leave blank to mirror from repo variable)
      yq_version:              ← leave blank to skip
      kubectl_version:         ← leave blank to skip

2. The workflow automatically updates ARGOCD_VERSION repo variable to v3.5.0
3. Next CD run pulls the new binary from Docker Hub (cache key changed)
```

### Trigger

`workflow_dispatch` only — never runs automatically.

### Inputs

| Input | Default | Description |
|---|---|---|
| `argocd_version` | _(blank — uses `ARGOCD_VERSION` repo variable)_ | ArgoCD CLI version to mirror. Leave blank to use repo variable. |
| `yq_version` | _(blank — uses `YQ_VERSION` repo variable)_ | yq version to mirror. Leave blank to use repo variable. |
| `kubectl_version` | _(blank — uses `KUBECTL_VERSION` repo variable)_ | kubectl version to mirror. Leave blank to use repo variable. |

Leave all blank to re-mirror all three tools at their currently configured versions. Pass a version to override and automatically update the corresponding repo variable.

### Steps

| Step | What it does |
|---|---|
| Login to Docker Hub | Authenticates with `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` |
| Set up QEMU + Buildx | Enables cross-arch builds from the amd64 GitHub-hosted runner |
| Mirror ArgoCD CLI | Downloads `argocd-linux-amd64` and `argocd-linux-arm64` from GitHub Releases; builds a `FROM scratch` multi-arch image; pushes to `christseng89/argocd-bin:<version>` |
| Mirror yq | Same pattern for `christseng89/yq-bin:<version>` |
| Mirror kubectl | Downloads from `dl.k8s.io`; builds and pushes `christseng89/kubectl-bin:<version>` |
| Update repo variables | If an input version was provided, updates the corresponding repo variable (`ARGOCD_VERSION`, `YQ_VERSION`, or `KUBECTL_VERSION`) so the CI/CD workflows stay in sync |
| Summary | Writes a job summary table with the mirrored tags and pull commands |

### Permissions

```yaml
permissions:
  contents: read
```

Only Docker Hub push and `gh variable set` (via `GITHUB_TOKEN`) are needed — no repo code write access required.

---

## Multi-Environment Image Promotion

Each environment is independently tracked by its values file:

| File | Updated by | Ingress URL |
|---|---|---|
| `values-dev.yaml` | `cicd.yaml` automatically (COMMIT_ID) | `<app_name>-dev.test.com` |
| `values-staging.yaml` | User commits `image.tag` directly | `<app_name>-staging.test.com` |
| `values-prod.yaml` | User commits `image.tag` directly | `<app_name>-prod.test.com` |

Example — promote staging to `a1b2c3`, prod to `001122`:

```yaml
# values-staging.yaml
image:
  tag: a1b2c3    ← commit this change → cd.yaml triggers → staging updated

# values-prod.yaml
image:
  tag: "001122"  ← commit this change → cd.yaml triggers → prod updated
```

Git history on these files is the full audit trail of who promoted what and when.

---

## Required Secrets

| Secret | Used by | Description |
|---|---|---|
| `DOCKERHUB_USERNAME` | `cicd.yaml` CI job, `mirror-cli-binaries.yaml` | Docker Hub login |
| `DOCKERHUB_TOKEN` | `cicd.yaml` CI job, `mirror-cli-binaries.yaml` | Docker Hub access token |
| `ARGOCD_PASSWORD` | Both CD jobs | ArgoCD `admin` password |
| `GH_PAT` | Both CD jobs | GitHub PAT (`repo` scope) — used to register the repo in ArgoCD |

`GITHUB_TOKEN` is provided automatically by GitHub Actions (used for committing values files and updating repo variables).

## Required Repository Variables

| Variable | Default value | Description |
|---|---|---|
| `ARGOCD_VERSION` | `v3.4.2` | ArgoCD CLI version — read by both CD workflows and `mirror-cli-binaries.yaml` |
| `YQ_VERSION` | `v4.44.3` | yq version — read by `cicd.yaml` and `mirror-cli-binaries.yaml` |
| `KUBECTL_VERSION` | `v1.36.1` | kubectl version — read by both CD workflows and `mirror-cli-binaries.yaml` |

Set these once after scaffolding:

```bash
gh variable set ARGOCD_VERSION  --body "v3.4.2"  --repo christseng89/<app_name>
gh variable set YQ_VERSION      --body "v4.44.3" --repo christseng89/<app_name>
gh variable set KUBECTL_VERSION --body "v1.36.1" --repo christseng89/<app_name>
```

---

## Docker Hub Mirror Images

The `docker create` / `docker cp` pattern extracts each binary from a `FROM scratch` image without running a container. No `docker login` is needed to pull the public mirror images.

See [`mirror-cli-binaries.yaml`](#mirror-cli-binariesyaml--mirror-cli-binaries-to-docker-hub) for how the mirrors are built and when to run the workflow.

---

## Troubleshooting

**`cicd.yaml` never starts**
- Confirm the change touched a file under `src/`. Changes to `charts/`, `.github/`, or the repo root do not match the path filter.

**`cd.yaml` never starts after editing a values file**
- Confirm you edited `values-staging.yaml` or `values-prod.yaml` — `values-dev.yaml` is intentionally excluded (updated by `cicd.yaml`, not the user).
- Confirm the commit landed on `main`, not a feature branch.

**CI fails on "Login to Docker Hub"**
- Verify secrets are set: `gh secret list --repo christseng89/<app_name>`

**CD fails on yq/kubectl/argocd pull hanging or timing out**
- The runner pod may lack internet egress. Check network policies in the `arc-runners` namespace.
- Run `mirror-cli-binaries.yaml` first if the Docker Hub mirror for that version doesn't exist yet.

**`cd.yaml` skips deployment with "image.tag is empty"**
- Set `image.tag` in the values file to a real tag and commit again.

**ArgoCD sync fails with `UNAUTHENTICATED`**
- The `ARGOCD_PASSWORD` secret is stale. Rotate: `gh secret set ARGOCD_PASSWORD --body <new> --repo christseng89/<app_name>`

**ArgoCD repo registration fails with permission error**
- The `GH_PAT` secret is missing or expired. Create a new PAT with `repo` scope and update: `gh secret set GH_PAT --body <token> --repo christseng89/<app_name>`

**ArgoCD wait times out (`context deadline exceeded`)**
- The `--timeout 180` expired. Check "Diagnose on failure" output for pod events and logs.
- Common causes: bad image tag, Docker Hub rate limit, failing readiness probe at `/api/v1/healthz`.

**"Commit changes" fails with a merge conflict**
- Another commit landed on `main` between checkout and push. The `--rebase --autostash` strategy handles most cases automatically. If it still fails, re-run manually from the Actions tab.

**CD fails pulling argocd or yq with "manifest unknown"**
- The mirror image for that version does not exist on Docker Hub yet. Run `mirror-cli-binaries.yaml` first with the required version, then re-run the CD job.

**`mirror-cli-binaries.yaml` fails on "Login to Docker Hub"**
- Verify `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set on the repo.

**`mirror-cli-binaries.yaml` curl step times out**
- GitHub Releases may be temporarily slow. Re-run the workflow — the `--retry 3` flag handles transient failures automatically.

**Workflow reads wrong tool version**
- Confirm the repo variable is set: `gh variable list --repo christseng89/<app_name>`
- If you updated the variable manually in Settings, the cache key for the old version is now stale — the next run will re-download automatically.
