# CI/CD Pipeline

This document covers the three GitHub Actions workflows generated into every repo scaffolded from the `python-app` Backstage template.

| Workflow file | Purpose | Trigger |
|---|---|---|
| `.github/workflows/<app_name>-cicd.yaml` | Build image + deploy to **dev** | Auto on `src/**` push |
| `.github/workflows/<app_name>-cd.yaml` | Deploy to **staging or prod** | Auto on values file change |
| `.github/workflows/mirror-cli-binaries.yaml` | Mirror `argocd` + `yq` binaries to Docker Hub | Manual (`workflow_dispatch`) |

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
   │         │  • ArgoCD syncs <app_name>-dev
   └─────────┘
        │
        │   User edits values-staging.yaml or values-prod.yaml and commits
        ▼
   ┌─────────┐
   │  cd     │  Self-hosted ARC runner (linux)          cd.yaml
   │(stg/prd)│  • detects which env file changed
   │         │  • skips if image.tag is empty
   │         │  • ArgoCD syncs <app_name>-staging or <app_name>-prod
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

| Variable | Value | Purpose |
|---|---|---|
| `ARGOCD_VERSION` | `v3.4.2` | ArgoCD CLI version pulled from Docker Hub mirror |
| `YQ_VERSION` | `v4.44.3` | yq version pulled from Docker Hub mirror |
| `IMAGE_NAME` | `christseng89/<app_name>` | Docker Hub image repository |
| `VALUES_PATH` | `charts/<app_name>/values-dev.yaml` | Helm values file updated by CD |
| `ARGOCD_APP` | `<app_name>-dev` | ArgoCD application name for dev |
| `ARGOCD_SERVER` | `argocd-server.argocd.svc.cluster.local` | In-cluster ArgoCD service DNS |

To upgrade ArgoCD or yq, change only the version variables — the cache key includes the version so the next run automatically invalidates and re-downloads.

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
| Cache + install yq | Restores yq from `actions/cache`; on miss, pulls `christseng89/yq-bin:<version>` from Docker Hub and extracts via `docker cp` |
| Update dev values file | Runs `yq -i '.image.tag = "<commit_id>"' values-dev.yaml` |
| Commit changes | Pushes updated `values-dev.yaml` to `main` with `--rebase --autostash` |
| Cache + install ArgoCD CLI | Same mirror pattern as yq; cold run ~5–10 min, cached <1 s |
| ArgoCD app sync | Logs in with `--plaintext` and runs `argocd app sync <app_name>-dev` + `app wait --health --timeout 180` |
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

| Variable | Value | Purpose |
|---|---|---|
| `ARGOCD_VERSION` | `v3.4.2` | ArgoCD CLI version |
| `ARGOCD_SERVER` | `argocd-server.argocd.svc.cluster.local` | In-cluster ArgoCD DNS |

`DEPLOY_ENV` and `ARGOCD_APP` are set dynamically per run (see "Detect environment" step below).

### CD Job

Runs on `[self-hosted, linux]` (ARC runner pod in-cluster).

| Step | What it does |
|---|---|
| Checkout | Checks out the repo |
| Detect environment | On push: derives env from whichever values file changed (`staging` or `prod`). On `workflow_dispatch`: uses the `environment` input. Sets `DEPLOY_ENV` and `ARGOCD_APP=<app_name>-<env>` |
| Validate image tag | Reads `.image.tag` from the values file. If empty, prints a notice and skips all deployment steps |
| Detect runner architecture | Sets `amd64` or `arm64` |
| Cache + install ArgoCD CLI | Same Docker Hub mirror pattern as `cicd.yaml` |
| ArgoCD app sync | Logs in and runs `argocd app sync <app_name>-<env>` + `app wait --health --timeout 180` |
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

The self-hosted ARC runner pod runs inside the cluster where GitHub Releases downloads are slow or flaky from Asia. This workflow pre-mirrors the `argocd` and `yq` binaries to Docker Hub (Cloudflare CDN with Asia POPs) so both CD jobs can pull them quickly.

The two mirror images produced are:

| Docker Hub image | Binary |
|---|---|
| `christseng89/argocd-bin:<version>` | `/argocd` |
| `christseng89/yq-bin:<version>` | `/yq` |

Both are `FROM scratch` multi-arch images (`linux/amd64` + `linux/arm64`). No `docker login` is needed to pull them — they are public.

### When to Run

Run this workflow **before** bumping `ARGOCD_VERSION` or `YQ_VERSION` in `<app_name>-cicd.yaml`. The CD job's cache key includes the version string, so a version bump invalidates the cache and triggers a fresh pull — the mirror must already exist on Docker Hub or the pull will fail.

```
1. Run mirror-cli-binaries.yaml (Actions → Run workflow)
      argocd_version: v3.5.0   ← new version
      yq_version:    v4.44.3   ← leave unchanged to skip

2. Update ARGOCD_VERSION: v3.5.0 in <app_name>-cicd.yaml
3. Commit → next CD run pulls the new binary from Docker Hub
```

### Trigger

`workflow_dispatch` only — never runs automatically.

### Inputs

| Input | Default | Description |
|---|---|---|
| `argocd_version` | `v3.4.2` | ArgoCD CLI version to mirror. Leave blank to skip. |
| `yq_version` | `v4.44.3` | yq version to mirror. Leave blank to skip. |

Both inputs have defaults so both tools are mirrored in one run by default. Clear a field to mirror only one tool.

### Steps

| Step | What it does |
|---|---|
| Login to Docker Hub | Authenticates with `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` |
| Set up QEMU + Buildx | Enables cross-arch builds from the amd64 GitHub-hosted runner |
| Mirror ArgoCD CLI | Downloads `argocd-linux-amd64` and `argocd-linux-arm64` from GitHub Releases; builds a `FROM scratch` multi-arch image; pushes to `christseng89/argocd-bin:<version>` |
| Mirror yq | Same pattern for `christseng89/yq-bin:<version>` |
| Summary | Writes a job summary table with the mirrored tags and pull commands |

### Permissions

```yaml
permissions:
  contents: read
```

Only Docker Hub push is needed — no repo write access required.

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
| `DOCKERHUB_USERNAME` | `cicd.yaml` CI job | Docker Hub login |
| `DOCKERHUB_TOKEN` | `cicd.yaml` CI job | Docker Hub access token |
| `ARGOCD_PASSWORD` | Both CD jobs | ArgoCD `admin` password |

`GITHUB_TOKEN` is provided automatically by GitHub Actions.

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

**CD fails on yq pull hanging or timing out**
- The runner pod may lack internet egress. Check network policies in the `arc-runners` namespace.

**`cd.yaml` skips deployment with "image.tag is empty"**
- Set `image.tag` in the values file to a real tag and commit again.

**ArgoCD sync fails with `UNAUTHENTICATED`**
- The `ARGOCD_PASSWORD` secret is stale. Rotate: `gh secret set ARGOCD_PASSWORD --body <new> --repo christseng89/<app_name>`

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
