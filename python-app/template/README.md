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

### 1. Clone the repo and start developing

```bash
git clone https://github.com/christseng89/${{values.app_name}}.git
cd ${{values.app_name}}
```

Make changes to `src/`. To test locally before pushing:

```bash
# Build and run locally
docker build -t ${{values.app_name}}:local .
docker run -p 5000:5000 ${{values.app_name}}:local

# Optional — tag and push manually to Docker Hub for ad-hoc testing
docker tag ${{values.app_name}}:local christseng89/${{values.app_name}}:local
docker push christseng89/${{values.app_name}}:local
```

> `docker build/push` and `helm install/upgrade` are **not** required manually
> in the normal GitOps flow — `cicd.yaml` builds and pushes the image, and
> ArgoCD applies the Helm chart automatically.

### 2. Deploy to Dev — push source changes

```bash
git add src/
git commit -m "your change"
git push origin main
```

```
cicd.yaml triggers automatically
  → builds christseng89/${{values.app_name}}:<sha>   (docker build + push)
  → writes <sha> into values-dev.yaml               (helm values update)
  → ArgoCD creates/syncs ${{values.app_name}}-dev   (helm install/upgrade)
  → accessible at ${{values.app_name}}-dev.test.com
```

### 3. Promote to Staging — edit values-staging.yaml

Find the image tag to promote from Docker Hub or from `values-dev.yaml`:

```bash
# See what is currently running in dev
grep tag charts/${{values.app_name}}/values-dev.yaml
```

Edit `charts/${{values.app_name}}/values-staging.yaml`:

```yaml
image:
  tag: a1b2c3    ← replace with the tag tested in dev
```

```bash
git add charts/${{values.app_name}}/values-staging.yaml
git commit -m "promote staging to a1b2c3"
git push origin main
```

```
cd.yaml triggers automatically
  → ArgoCD creates/syncs ${{values.app_name}}-staging   (helm install/upgrade)
  → accessible at ${{values.app_name}}-staging.test.com
```

### 4. Promote to Prod — edit values-prod.yaml

Edit `charts/${{values.app_name}}/values-prod.yaml`:

```yaml
image:
  tag: a1b2c3    ← replace with the tag validated in staging
```

```bash
git add charts/${{values.app_name}}/values-prod.yaml
git commit -m "promote prod to a1b2c3"
git push origin main
```

```
cd.yaml triggers automatically
  → ArgoCD creates/syncs ${{values.app_name}}-prod   (helm install/upgrade)
  → accessible at ${{values.app_name}}-prod.test.com
```

> The image tag is the first 6 characters of the Git commit SHA (e.g. `a1b2c3`).
> Git history on `values-staging.yaml` and `values-prod.yaml` is the full audit
> trail of who promoted what version and when.
