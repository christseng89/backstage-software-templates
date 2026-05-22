# ${{values.app_name}}

After this repo is scaffolded, two manual steps are required before CI/CD will work.

## Post-Scaffolding Steps

### 1. Register the Self-Hosted Runner

Apply the runner deployment to your local Docker Desktop Kubernetes cluster:

```bash
kubectl config use-context docker-desktop
kubectl apply -f runnerdeployment.yaml
```

### 2. Set GitHub Actions Secrets

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
