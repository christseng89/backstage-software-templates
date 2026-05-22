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

GitHub Actions expressions (`${{ github.ref }}`, `${{ secrets.FOO }}`) inside skeleton files must be escaped as nunjucks string literals to prevent Backstage from treating them as template expressions:

```yaml
# In a skeleton file — outputs: ${{ github.ref }}
group: cicd-${{ '${{ github.ref }}' }}
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
- **CD** (self-hosted ARC runner `[self-hosted, linux]`): uses `yq` (pulled from `christseng89/yq-bin` Docker Hub mirror) to write the new image tag into `charts/<app_name>/values-<env>.yaml`; commits back to `main` with rebase-pull; syncs ArgoCD via CLI (pulled from `christseng89/argocd-bin` mirror); waits for healthy status
- **Helm charts**: base `values.yaml` holds all defaults; env-specific files (`values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`) override only what differs (replica count, resource requests). The CD job writes `.image.tag` into the env-specific file only.
- **ArgoCD**: expected to be pre-configured before first run — the pipeline does **not** create the app. `charts/argocd/values-argo.yaml` is the Helm values for deploying ArgoCD itself (via `argo-cd` Helm chart), not the application. ArgoCD is accessed via in-cluster DNS (`argocd-server.argocd.svc.cluster.local`) because `argocd.test.com` only resolves via the Windows hosts file.
- **Kubernetes**: Nginx ingress at `<app_name>-<env>.test.com`; health probes at `/api/v1/healthz` on port 5000. The `k8s/` raw manifests are alternatives to the Helm chart and are not part of the GitOps flow.
- **TechDocs**: `mkdocs.yaml` and `docs/index.md` are included in the skeleton; `catalog-info.yaml` sets `backstage.io/techdocs-ref: dir:.`

## Self-Hosted Runner

`runnerdeployment.yaml` uses the **summerwind Actions Runner Controller v1** API (`actions.summerwind.dev/v1alpha1`), not the newer GitHub ARC v2 (`actions.github.com`). `dockerEnabled: false` means no DinD sidecar — the runner accesses Docker via the host socket. The CD job uses `docker pull` / `docker create` / `docker cp` to extract tool binaries from `FROM scratch` mirror images without running a container.

## Reference File: cicd-sample.yaml

`python-app/template/.github/workflows/cicd-sample.yaml` is **not scaffolded** — it is the canonical working pipeline as deployed on the `christseng89/python-app` repo itself (with hardcoded paths like `python-app/src/**`). It serves as a reference when updating the template. The template version (`${{values.app_name}}-cicd.yaml`) is derived from it with `${{values.*}}` substitutions.

## Adding a New Template

1. Create a new top-level directory (e.g., `node-app/`)
2. Write `template.yaml` with `apiVersion: scaffolder.backstage.io/v1beta3`
3. Create a `template/` skeleton using `${{values.*}}` placeholders; escape all GitHub Actions `${{ }}` expressions with the nunjucks string literal pattern above
4. Register `template.yaml` in your Backstage `app-config.yaml` catalog locations

## Post-Scaffolding Manual Steps

After Backstage creates the repo, two steps are required before CI/CD will work:

**1. Register the self-hosted runner** (Docker Desktop k8s):
```bash
kubectl config use-context docker-desktop
kubectl apply -f runnerdeployment.yaml
```

**2. Set GitHub Actions secrets** (load values from a local `.env` first):
```bash
source .env   # Bash / Git Bash / WSL only
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/<app_name>
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/<app_name>
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/<app_name>
gh secret list --repo christseng89/<app_name>
```

Secrets cannot be embedded in `template.yaml`, so this step must remain manual.
