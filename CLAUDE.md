# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A **Backstage Software Scaffolder template repository**. It is not a runnable application — it contains template definitions that the Backstage scaffolder uses to generate new GitHub repositories. There are no root-level build, lint, or test commands.

## Template Structure

Each template lives in its own directory (e.g., `python-app/`) with this layout:

```
<template-name>/
├── template.yaml           # Backstage template definition (parameters + steps)
└── template/               # Skeleton files copied into the new repo
    ├── .github/workflows/  # Templated CI/CD pipeline
    ├── charts/             # Helm chart (multi-env values files)
    ├── k8s/                # Raw Kubernetes manifests
    ├── src/                # Application source
    ├── catalog-info.yaml      # Backstage catalog registration
    ├── runnerdeployment.yaml  # GitHub Actions self-hosted runner (applied manually to k8s)
    └── README.md              # Post-scaffolding manual steps (uses ${{values.app_name}})
```

## Template Variable Syntax

Backstage scaffolder uses `${{values.<key>}}` (double braces) for variable substitution throughout skeleton files — not the usual Jinja `{{ }}` or shell `${}`. This applies to filenames, directory names, and file contents.

The `template.yaml` maps parameter names to `values.*`:
- User input `component_id` → `values.app_name` (via `id: component_id`)
- User input `environment` → `values.app_env`

## Scaffolding Steps (template.yaml)

The current `python-app` template runs three steps:
1. **`fetch:template`** — copies `./template/` skeleton with variable substitution
2. **`publish:github`** — creates a new GitHub repo under `christseng89` org
3. **`catalog:register`** — registers the new component in the Backstage catalog via `catalog-info.yaml`

## Generated Repo Architecture

Scaffolded repos follow a GitOps pattern:

- **CI** (GitHub Actions): triggers on pushes to `src/**` on `main`; builds Docker image tagged with short commit SHA; pushes to Docker Hub as `christseng89/<app_name>:<sha>`
- **CD** (GitHub Actions → ArgoCD): updates image tag in `charts/<app_name>/values-<env>.yaml` via `yq`; commits the change; triggers ArgoCD sync against `argocd-server.argocd`
- **Helm charts**: multi-environment (`values-dev.yaml`, `values-staging.yaml`, `values-prod.yaml`); ArgoCD config lives in `charts/argocd/values-argo.yaml`
- **Kubernetes**: Nginx ingress at `<app_name>-<env>.test.com`, health probes at `/api/v1/healthz`

## Adding a New Template

1. Create a new top-level directory (e.g., `node-app/`)
2. Write `template.yaml` defining `apiVersion: scaffolder.backstage.io/v1beta3`
3. Create a `template/` skeleton using `${{values.*}}` placeholders
4. Register `template.yaml` in your Backstage `app-config.yaml` catalog locations

## Post-Scaffolding Manual Steps

After Backstage creates the repo, two manual steps are required before CI/CD will work:

**1. Register the self-hosted runner** (Docker Desktop k8s):
```bash
kubectl apply -f runnerdeployment.yaml
```

**2. Set GitHub Actions secrets** (load values from a local `.env` first):
```bash
source .env
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/<app_name>
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/<app_name>
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/<app_name>
gh secret list --repo christseng89/<app_name>
```

Secrets cannot be embedded in `template.yaml`, so this step must remain manual. The `source .env` command is Bash-only; use Git Bash or WSL on Windows.
