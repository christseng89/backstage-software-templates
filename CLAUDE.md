# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A **Backstage Software Scaffolder template repository**. It is not a runnable application — it contains template definitions that the Backstage scaffolder uses to generate new GitHub repositories. There are no build, lint, or test commands.

## Template Structure

Each template lives in its own directory (e.g., `python-app/`) with this layout:

```
<template-name>/
├── template.yaml           # Backstage template definition (parameters + steps)
├── README-cicd.md          # CI/CD pipeline documentation (not scaffolded)
└── template/               # Skeleton files copied into the new repo
    ├── .github/workflows/  # Templated CI/CD pipeline
    ├── charts/             # Helm chart with per-env values files
    ├── k8s/                # Raw Kubernetes manifests (not used in GitOps flow)
    ├── src/                # Application source
    ├── docs/               # TechDocs source (mkdocs.yaml at template root)
    ├── catalog-info.yaml   # Backstage catalog registration
    ├── runnerdeployment.yaml  # ARC runner deployment (applied manually)
    └── README.md           # Post-scaffolding manual steps
```

## Template Variable Syntax

Backstage scaffolder uses `${{values.<key>}}` (double braces) for variable substitution in skeleton files — not Jinja `{{ }}` or shell `${}`. This applies to filenames, directory names, and file contents.

**All** GitHub Actions `${{ }}` expressions inside skeleton files must be escaped as nunjucks string literals — this applies to every namespace (`github.*`, `secrets.*`, `inputs.*`, `steps.*`, `needs.*`, etc.):

```yaml
# In a skeleton file — outputs: ${{ github.ref }}
group: cicd-${{ '${{ github.ref }}' }}
# In a skeleton file — outputs: ${{ inputs.argocd_version }}
tag: ${{ '${{ inputs.argocd_version }}' }}
```

The `template.yaml` maps user inputs to `values.*`:
- `component_id` (kebab-case, validated by regex) → `values.app_name`
- `environment` (enum: dev / staging / prod) → `values.app_env`

## Scaffolding Steps (template.yaml)

1. **`fetch:template`** — copies `./template/` skeleton with variable substitution
2. **`publish:github`** — creates a public repo under `christseng89` org; `protectDefaultBranch: false`
3. **`catalog:register`** — registers the component in Backstage via `catalog-info.yaml`

## Generated Repo Architecture

Scaffolded repos follow a GitOps pattern:

- **CI** (GitHub-hosted `ubuntu-latest`): triggers on `src/**` pushes to `main`; builds a multi-arch (`linux/amd64,linux/arm64`) Docker image tagged with the short commit SHA (`${GITHUB_SHA::6}`); pushes to Docker Hub as `christseng89/<app_name>:<sha>` with a `buildcache` layer cache tag
- **CD** (self-hosted ARC runner `[self-hosted, linux]`): installs `kubectl`, `yq`, and `argocd` CLI from `christseng89/*-bin` Docker Hub mirrors; writes the new image tag into `charts/<app_name>/values-dev.yaml`; commits back to `main` with rebase-pull; registers the GitHub repo in ArgoCD using `GH_PAT`; creates the ArgoCD app if absent; syncs and waits for healthy status
- **Tool versions**: `ARGOCD_VERSION`, `YQ_VERSION`, `KUBECTL_VERSION` are stored as **GitHub Actions repository variables** (not hardcoded in the workflow). Both CD workflows read from `vars.*`; `mirror-cli-binaries.yaml` can update them automatically when given a version override as input.
- **Helm charts**: base `values.yaml` holds all defaults; env-specific files (`values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`) override only what differs (replica count, resource requests). The CD job writes `.image.tag` into the env-specific file only.
- **ArgoCD**: the pipeline creates the app on first run if it does not exist (`argocd app create` with `--validate=false`). ArgoCD is accessed via in-cluster DNS (`argocd-server.argocd.svc.cluster.local`) because `argocd.test.com` only resolves via the Windows hosts file. ArgoCD and nginx ingress controller are cluster-level infrastructure installed separately — their Helm values live in `python-app1/charts/argocd/` and `python-app1/charts/nginx/`, not in the scaffolded app repo.
- **Kubernetes**: Nginx ingress at `<app_name>-<env>.test.com:9080`; health probes at `/api/v1/healthz` on port 5000. Port 9080 is intentional — Docker Desktop occupies ports 80 and 8080, so the nginx ingress controller (`ingress-nginx-controller`) is configured with `9080:32426/TCP`. The `k8s/` raw manifests are alternatives to the Helm chart and are not part of the GitOps flow.
- **TechDocs**: `mkdocs.yaml` and `docs/index.md` are included in the skeleton; `catalog-info.yaml` sets `backstage.io/techdocs-ref: dir:.`

## Self-Hosted Runner

`runnerdeployment.yaml` uses the **summerwind Actions Runner Controller v1** API (`actions.summerwind.dev/v1alpha1`), not the newer GitHub ARC v2 (`actions.github.com`). `dockerEnabled: false` means no DinD sidecar — the runner accesses Docker via the host socket. The CD job uses `docker pull` / `docker create` / `docker cp` to extract tool binaries from `FROM scratch` mirror images without running a container.

## Reference Files

`.github1/workflows/cicd.yaml` is the **canonical working pipeline** deployed on the `christseng89/python-app1` monorepo (hardcoded paths like `python-app/src/**`). It serves as the reference when updating the template. The template version (`${{values.app_name}}-cicd.yaml`) is derived from it with `${{values.*}}` substitutions and the `cicd` + `cd` split.

`.github1/workflows/mirror-cli-binaries.yaml` is the reference for the scaffolded `mirror-cli-binaries.yaml`.

## Updating CLI Tool Versions (yq / ArgoCD / kubectl)

Tool versions are stored as **GitHub Actions repository variables** in each generated repo — not hardcoded in the workflow files. The three variables are:

| Variable | Default |
|---|---|
| `ARGOCD_VERSION` | `v3.4.2` |
| `YQ_VERSION` | `v4.44.3` |
| `KUBECTL_VERSION` | `v1.36.1` |

`mirror-cli-binaries.yaml` is a **scaffolded** `workflow_dispatch` workflow that mirrors these binaries from GitHub Releases (slow from Asia) to Docker Hub (`christseng89/argocd-bin`, `christseng89/yq-bin`, `christseng89/kubectl-bin`) as `FROM scratch` multi-arch images. The CD job pulls from Docker Hub for speed and caches the binary in `/tmp/` keyed by version+arch.

**Version bump procedure:**
1. Run `mirror-cli-binaries.yaml` manually (Actions tab) in each generated repo, passing the new version(s) as inputs — the workflow automatically updates the repo variable after a successful mirror
2. The mirror must exist on Docker Hub before the cache-miss path tries to pull it
3. The cache key includes the version string, so the next CD run automatically invalidates and re-downloads

The CD job's `timeout-minutes: 25` is conservative for cold cache (first pull of ~150 MB argocd binary takes 5–10 min). After the cache warms, actual runtime is under 2 min; you can safely lower the timeout to 10 in generated repos once the cache is populated.

## Adding a New Template

1. Create a new top-level directory (e.g., `node-app/`)
2. Write `template.yaml` with `apiVersion: scaffolder.backstage.io/v1beta3`
3. Create a `template/` skeleton using `${{values.*}}` placeholders; escape all GitHub Actions `${{ }}` expressions with the nunjucks string literal pattern above
4. Register `template.yaml` in your Backstage `app-config.yaml` catalog locations

## Post-Scaffolding Manual Steps

After Backstage creates the repo, four steps are required before CI/CD will work:

**1. Register the self-hosted runner and RBAC** (Docker Desktop k8s):
```bash
kubectl config use-context docker-desktop
kubectl apply -f k8s/runner-rbac.yaml
kubectl apply -f runnerdeployment.yaml
```

`runner-rbac.yaml` grants the ARC runner read access to pods and deployments — required for the `kubectl` commands in the Diagnose-on-failure step of both CD jobs.

**2. Set GitHub Actions secrets** (load values from a local `.env` first):
```bash
source .env   # Bash / Git Bash / WSL only
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/<app_name>
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/<app_name>
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/<app_name>
gh secret set GH_PAT             --body $GITHUB_PAT         --repo christseng89/<app_name>
gh secret list --repo christseng89/<app_name>
```

`GH_PAT` must have `repo` scope — it is used by both CD jobs to register the GitHub repo in ArgoCD via `argocd repo add`. Secrets cannot be embedded in `template.yaml`, so this step must remain manual.

**3. Set GitHub Actions variables**:
```bash
gh variable set ARGOCD_VERSION  --body "v3.4.2"  --repo christseng89/<app_name>
gh variable set YQ_VERSION      --body "v4.44.3" --repo christseng89/<app_name>
gh variable set KUBECTL_VERSION --body "v1.36.1" --repo christseng89/<app_name>
gh variable list --repo christseng89/<app_name>
```

**4. Mirror CLI binaries** — run `mirror-cli-binaries.yaml` once from the Actions tab (leave all inputs blank to mirror all three tools at the versions just set).
