# CI/CD Pipeline

This document covers the GitHub Actions pipeline generated into every repo scaffolded from the `python-app` Backstage template. The workflow file is `.github/workflows/<app_name>-cicd.yaml`.

## Overview

The pipeline has two sequential jobs:

```
push to src/** on main
        │
        ▼
   ┌─────────┐
   │   ci    │  GitHub-hosted runner (ubuntu-latest)
   │         │  • builds multi-arch Docker image
   │         │  • pushes to Docker Hub
   └────┬────┘
        │ commit_id output
        ▼
   ┌─────────┐
   │   cd    │  Self-hosted ARC runner (linux)
   │         │  • updates image tag in Helm values file
   │         │  • commits the change back to main
   │         │  • triggers ArgoCD sync
   └─────────┘
```

## Triggers

| Event | Condition |
|---|---|
| `push` | Any change under `src/**` on `main` |
| `workflow_dispatch` | Manual run from the Actions tab — useful for redeploying without a code change |

## Environment Variables

Defined at the top of the workflow so all jobs share them:

| Variable | Value | Purpose |
|---|---|---|
| `ARGOCD_VERSION` | `v3.4.2` | ArgoCD CLI version pulled from the Docker Hub mirror |
| `YQ_VERSION` | `v4.44.3` | yq version pulled from the Docker Hub mirror |
| `IMAGE_NAME` | `christseng89/<app_name>` | Docker Hub image repository |
| `VALUES_PATH` | `charts/<app_name>/values-<env>.yaml` | Helm values file updated by CD |
| `ARGOCD_APP` | `<app_name>` | ArgoCD application name |
| `ARGOCD_SERVER` | `argocd-server.argocd.svc.cluster.local` | In-cluster ArgoCD service DNS |

To upgrade ArgoCD or yq, change only the version variables — the cache key includes the version, so the next run automatically invalidates the cache and re-downloads.

## Required Secrets

Set these on the repo before the first run (see `README.md` for the setup commands):

| Secret | Used by | Description |
|---|---|---|
| `DOCKERHUB_USERNAME` | ci | Docker Hub login |
| `DOCKERHUB_TOKEN` | ci | Docker Hub access token |
| `ARGOCD_PASSWORD` | cd | ArgoCD `admin` password |

`GITHUB_TOKEN` is provided automatically by GitHub Actions and requires no setup.

## CI Job — Build and Push

Runs on `ubuntu-latest` (GitHub-hosted). GitHub-hosted runners have fast access to GitHub Releases and Docker Hub, so setup actions download in seconds.

### Steps

1. **Checkout** — checks out the repo.
2. **Shorten commit id** — takes the first 6 characters of `GITHUB_SHA` as the image tag (e.g. `a1b2c3`). Passed to the CD job via the `commit_id` output.
3. **Set up QEMU + Buildx** — enables cross-architecture emulation so a single build produces both `linux/amd64` and `linux/arm64` layers. Without this, ARM64 nodes (Apple Silicon, Surface Pro) crash the container with `exec format error`.
4. **Login to Docker Hub** — authenticates for the push.
5. **Build and push** — builds the image from the repo root and pushes:
   - Tag: `christseng89/<app_name>:<commit_id>`
   - Cache: `christseng89/<app_name>:buildcache` (registry cache, `mode=max`) — saves 60–120 s on warm multi-arch builds.

## CD Job — Deploy

Runs on `[self-hosted, linux]` (Actions Runner Controller pod in the cluster). Needs in-cluster DNS to reach `argocd-server.argocd.svc.cluster.local`.

### Steps

1. **Checkout** — checks out the repo with `GITHUB_TOKEN` so the subsequent commit step has push permission.
2. **Detect runner architecture** — sets `steps.arch.outputs.tag` to `amd64` or `arm64` for tool downloads.
3. **Cache + install yq** — restores yq from `actions/cache` (key: `yq-<arch>-<version>`). On a cache miss, pulls the binary from `christseng89/yq-bin:<version>` on Docker Hub (a `FROM scratch` mirror image). The `docker create` / `docker cp` pattern extracts the binary without running a container.
4. **Modify values file** — runs:
   ```
   yq -i '.image.tag = "<commit_id>"' charts/<app_name>/values-<env>.yaml
   ```
5. **Commit changes** — uses `EndBug/add-and-commit@v9` to commit and push the values file change. `pull: --rebase --autostash` handles the case where another run or a manual edit pushed to `main` since checkout.
6. **Cache + install ArgoCD CLI** — same Docker mirror pattern as yq, key: `argocd-<arch>-<version>`. First cold run: ~5–10 min. Subsequent cached runs: <1 s restore.
7. **ArgoCD app sync** — logs in with `--plaintext` (the server runs with `server.insecure: true`) and runs:
   ```
   argocd app sync <app_name>
   argocd app wait <app_name> --health --timeout 180
   ```
8. **Diagnose on failure** _(runs only if a previous step failed)_ — dumps `argocd app get`, `argocd app history`, `kubectl get pods`, `kubectl describe deploy`, and recent pod logs so you can diagnose without manually shelling into the cluster.

## Concurrency

```yaml
concurrency:
  group: cicd-${{ github.ref }}
  cancel-in-progress: false
```

Only one run per branch executes at a time. A second push queued behind an active run will wait, not cancel it — `cancel-in-progress: false` ensures a CD job that has already started writing to `values.yaml` and triggering ArgoCD is never killed mid-flight.

## Permissions

```yaml
permissions:
  contents: write
```

Newer GitHub repos default `GITHUB_TOKEN` to read-only. The `contents: write` permission is required for the CD job to commit and push the updated values file back to `main`.

## Docker Hub Mirror Images

The CD runner pod runs inside the cluster, where direct GitHub Releases downloads can be slow or flaky. Instead of `curl`-ing from GitHub, the pipeline uses two purpose-built `FROM scratch` mirror images:

| Image | Contents |
|---|---|
| `christseng89/yq-bin:<version>` | Single `yq` binary at `/yq` |
| `christseng89/argocd-bin:<version>` | Single `argocd` binary at `/argocd` |

These are public Docker Hub images — no `docker login` is needed to pull them.

## Troubleshooting

**Pipeline never starts**
- Confirm the change touched a file under `src/`. Changes to `charts/`, `.github/`, or the repo root do not trigger the path filter.

**CI fails on "Login to Docker Hub"**
- Verify `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets are set: `gh secret list --repo christseng89/<app_name>`

**CD fails on "Modify values file" (yq pull hangs or times out)**
- The runner pod may not have internet egress. Check network policies in the `arc-runners` namespace.
- Increase the `timeout-minutes` on the `cd` job temporarily to rule out a slow cold pull.

**CD fails on "ArgoCD app sync" with `UNAUTHENTICATED`**
- The `ARGOCD_PASSWORD` secret may be stale. Rotate it: `gh secret set ARGOCD_PASSWORD --body <new-password> --repo christseng89/<app_name>`

**CD fails on "ArgoCD app sync" with `context deadline exceeded`**
- The `argocd app wait --timeout 180` expired. Check the "Diagnose on failure" step output in the run log — it will show pod events and recent logs.
- Common causes: image pull failure (bad tag, Docker Hub rate limit) or a failing readiness probe.

**"Commit changes" fails with a merge conflict**
- Another commit landed on `main` between the checkout and push. The `--rebase --autostash` pull strategy handles most cases automatically. If it still fails, re-run the workflow manually from the Actions tab.
