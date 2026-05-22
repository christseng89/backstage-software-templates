# ${{values.app_name}}

After this repo is scaffolded, three manual steps are required before CI/CD will work.

## Post-Scaffolding Steps

### 1. Register the Self-Hosted Runner

Apply the runner deployment to your local Docker Desktop Kubernetes cluster:

```bash
kubectl config use-context docker-desktop
kubectl apply -f runnerdeployment.yaml
```

### 2. Pre-configure ArgoCD Apps (one-time)

Three ArgoCD apps must exist before the first CD run. Each points to this repo
with a different values file and target namespace:

| ArgoCD app | Namespace | Values file |
|---|---|---|
| `${{values.app_name}}-dev` | `dev` | `charts/${{values.app_name}}/values-dev.yaml` |
| `${{values.app_name}}-staging` | `staging` | `charts/${{values.app_name}}/values-staging.yaml` |
| `${{values.app_name}}-prod` | `prod` | `charts/${{values.app_name}}/values-prod.yaml` |

**Pipeline behaviour after setup:**
- Push to `main` (via `src/**` change) → auto-deploys to **dev** (`${{values.app_name}}-dev.test.com`)
- Promote to staging: edit `values-staging.yaml`, set `image.tag`, commit → auto-deploys to `${{values.app_name}}-staging.test.com`
- Promote to prod: edit `values-prod.yaml`, set `image.tag`, commit → auto-deploys to `${{values.app_name}}-prod.test.com`

### 3. Set GitHub Actions Secrets

Load your secrets from a local `.env` file and push them to this repo:

```bash
source .env
gh secret set DOCKERHUB_USERNAME --body $DOCKERHUB_USERNAME --repo christseng89/${{values.app_name}}
gh secret set DOCKERHUB_TOKEN    --body $DOCKERHUB_TOKEN    --repo christseng89/${{values.app_name}}
gh secret set ARGOCD_PASSWORD    --body $ARGOCD_PASSWORD    --repo christseng89/${{values.app_name}}
gh secret list --repo christseng89/${{values.app_name}}
```

> `source .env` is Bash-only — run these commands in Git Bash or WSL on Windows.

### Expected `.env` format

```env
DOCKERHUB_USERNAME=your-username
DOCKERHUB_TOKEN=your-token
ARGOCD_PASSWORD=your-argocd-password
```
