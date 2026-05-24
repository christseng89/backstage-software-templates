# ${{values.app_name}}

This repo was scaffolded from the `python-app` Backstage template. Four manual steps
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
├── setup.sh                               ← automates post-scaffolding steps 1–4
└── mkdocs.yaml + docs/                    ← TechDocs source
```

---

## Post-Scaffolding Steps

> **TL;DR — run the setup script** (requires `.env` in the repo root and `gh` authenticated):
> ```bash
> bash setup.sh              # runs all four steps
> bash setup.sh --skip-mirror  # skip step 4 if Docker Hub mirrors already exist
> ```
> The manual steps below document what the script does.

### Step 1 — Register the Self-Hosted Runner

Apply the runner deployment and RBAC to your local Docker Desktop Kubernetes cluster:

```bash
kubectl config use-context docker-desktop
kubectl apply -f k8s/runner-rbac.yaml
kubectl apply -f runnerdeployment.yaml
```

> `runner-rbac.yaml` creates the `${{values.app_name}}` namespace, grants the ARC
> runner read access to pods and deployments, and must be applied first so the
> namespace exists before the runner deployment is created.

### Step 2 — Set GitHub Actions Secrets

Load your secrets from a local `.env` file and push them to this repo:

```bash
source .env
gh auth login
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/${{values.app_name}}
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/${{values.app_name}}
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/${{values.app_name}}
gh secret set GH_PAT             --body $GITHUB_PAT         --repo christseng89/${{values.app_name}}

gh secret list --repo christseng89/${{values.app_name}}
```

> `source .env` is Bash-only — run these commands in Git Bash or WSL on Windows.

```env
DOCKERHUB_USERNAME=your-username
DOCKERHUB_TOKEN=your-token
ARGOCD_PASSWORD=your-argocd-admin-password
GITHUB_PAT=your-github-personal-access-token
```

> `GH_PAT` is used by the CD jobs to register the repository in ArgoCD so it can
> pull from GitHub. Create a PAT with `repo` scope at GitHub → Settings → Developer settings → Personal access tokens.

### Step 3 — Set GitHub Actions Variables

Set the tool versions as repository variables (used by all three workflows):

```bash
gh variable set ARGOCD_VERSION  --body "v3.4.2"  --repo christseng89/${{values.app_name}}
gh variable set YQ_VERSION      --body "v4.44.3" --repo christseng89/${{values.app_name}}
gh variable set KUBECTL_VERSION --body "v1.36.1" --repo christseng89/${{values.app_name}}

gh variable list --repo christseng89/${{values.app_name}}
```

> Variables (not secrets) are used for versions so `mirror-cli-binaries.yaml` can
> update them automatically when you pass a version override as a workflow input.

### Step 4 — Mirror CLI Binaries to Docker Hub

Run once to push `argocd`, `yq`, and `kubectl` binaries to Docker Hub before the
first CD run. Skip if the mirrors already exist from a previous repo on the same versions.

```
GitHub → ${{values.app_name}} → Actions → mirror-cli-binaries → Run workflow
  argocd_version:  (leave blank to use ARGOCD_VERSION variable)
  yq_version:      (leave blank to use YQ_VERSION variable)
  kubectl_version: (leave blank to use KUBECTL_VERSION variable)
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

> You do not run `docker build/push` or `helm install/upgrade` manually in the
> normal GitOps flow. `cicd.yaml` handles the Docker build and push; ArgoCD
> runs `helm upgrade --install` against Docker Desktop's k8s automatically
> as part of every `app sync`.

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
  → accessible at ${{values.app_name}}-dev.test.com:9080
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
  → accessible at ${{values.app_name}}-staging.test.com:9080
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
  → accessible at ${{values.app_name}}-prod.test.com:9080
```

> The image tag is the first 6 characters of the Git commit SHA (e.g. `a1b2c3`).
> Git history on `values-staging.yaml` and `values-prod.yaml` is the full audit
> trail of who promoted what version and when.
