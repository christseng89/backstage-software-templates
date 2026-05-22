# ${{values.app_name}}

This repo was scaffolded from the `python-app` Backstage template. Three manual steps
are required before CI/CD will work. ArgoCD apps are created automatically on the
first successful pipeline run.

---

## What Was Created

```
christseng89/${{values.app_name}}/
├── .github/workflows/
│   ├── ${{values.app_name}}-cicd.yaml    ← CI + deploy to dev (auto on src/ push)
│   ├── ${{values.app_name}}-cd.yaml      ← promote staging/prod (auto on values file change)
│   └── mirror-cli-binaries.yaml          ← mirror tool binaries to Docker Hub (manual)
├── charts/${{values.app_name}}/
│   ├── values.yaml                        ← base Helm defaults
│   ├── values-dev.yaml                    ← image.tag written by cicd.yaml automatically
│   ├── values-staging.yaml                ← set image.tag here to promote to staging
│   ├── values-prod.yaml                   ← set image.tag here to promote to prod
│   └── templates/                         ← Deployment, Service, Ingress
├── src/                                   ← application source code
├── Dockerfile
├── catalog-info.yaml                      ← Backstage component registration
├── runnerdeployment.yaml                  ← ARC self-hosted runner spec
└── mkdocs.yaml + docs/                    ← TechDocs source
```

---

## Post-Scaffolding Steps

### Step 1 — Register the Self-Hosted Runner

Apply the runner deployment to your local Docker Desktop Kubernetes cluster:

```bash
kubectl config use-context docker-desktop
kubectl apply -f runnerdeployment.yaml
```

### Step 2 — Mirror CLI Binaries to Docker Hub

Run once to push `argocd` and `yq` binaries to Docker Hub before the first CD run.
Skip if the mirrors already exist from a previous repo on the same versions.

```
GitHub → ${{values.app_name}} → Actions → mirror-cli-binaries → Run workflow
  argocd_version: v3.4.2
  yq_version:     v4.44.3
```

### Step 3 — Set GitHub Actions Secrets

Load your secrets from a local `.env` file and push them to this repo:

```bash
source .env
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/${{values.app_name}}
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/${{values.app_name}}
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/${{values.app_name}}
gh secret list --repo christseng89/${{values.app_name}}
```

> `source .env` is Bash-only — run these commands in Git Bash or WSL on Windows.

```env
DOCKERHUB_USERNAME=your-username
DOCKERHUB_TOKEN=your-token
ARGOCD_PASSWORD=your-argocd-admin-password
```

---

## Normal Workflow After Setup

### Dev — automatic on every source push

```
Push any change under src/ to main
  → cicd.yaml builds christseng89/${{values.app_name}}:<sha>
  → writes <sha> into values-dev.yaml
  → ArgoCD syncs ${{values.app_name}}-dev
  → accessible at ${{values.app_name}}-dev.test.com
```

### Staging — promote by editing values-staging.yaml

```yaml
# charts/${{values.app_name}}/values-staging.yaml
image:
  tag: a1b2c3    ← set to the image tag tested in dev, then commit to main
```

```
Commit values-staging.yaml
  → cd.yaml triggers automatically
  → ArgoCD syncs ${{values.app_name}}-staging
  → accessible at ${{values.app_name}}-staging.test.com
```

### Prod — promote by editing values-prod.yaml

```yaml
# charts/${{values.app_name}}/values-prod.yaml
image:
  tag: a1b2c3    ← set to the image tag validated in staging, then commit to main
```

```
Commit values-prod.yaml
  → cd.yaml triggers automatically
  → ArgoCD syncs ${{values.app_name}}-prod
  → accessible at ${{values.app_name}}-prod.test.com
```

> The image tag is the first 6 characters of the Git commit SHA (e.g. `a1b2c3`).
> Find available tags on Docker Hub under `christseng89/${{values.app_name}}`,
> or read `values-dev.yaml` to see what is currently running in dev.
