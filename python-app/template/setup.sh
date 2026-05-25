#!/usr/bin/env bash
# Post-scaffolding setup script for ${{values.app_name}}.
# Run from the repo root after cloning: bash setup.sh
# Requires: .env file, kubectl (docker-desktop context), gh CLI authenticated.
#
# Usage:
#   bash setup.sh                        # run all steps
#   bash setup.sh --skip-mirror          # skip step 4 (mirrors already exist on Docker Hub)
#   bash setup.sh --skip-cicd            # skip step 6 (trigger workflow manually later)
#   bash setup.sh --skip-mirror --skip-cicd

set -euo pipefail

REPO="christseng89/${{values.app_name}}"
SKIP_MIRROR=false
SKIP_CICD=false

for arg in "$@"; do
  case "$arg" in
    --skip-mirror) SKIP_MIRROR=true ;;
    --skip-cicd)   SKIP_CICD=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  cat >&2 <<EOF
Error: .env file not found.
Create one in the repo root with:

  DOCKERHUB_USERNAME=your-username
  DOCKERHUB_TOKEN=your-token
  ARGOCD_PASSWORD=your-argocd-admin-password
  GITHUB_PAT=your-github-personal-access-token

Optional (defaults shown):
  ARGOCD_VERSION=v3.4.2
  YQ_VERSION=v4.44.3
  KUBECTL_VERSION=v1.36.1
EOF
  exit 1
fi
# shellcheck source=/dev/null
source .env

# Validate required variables
for var in DOCKERHUB_USERNAME DOCKERHUB_TOKEN ARGOCD_PASSWORD GITHUB_PAT; do
  if [ -z "${!var:-}" ]; then
    echo "Error: $var is not set in .env" >&2
    exit 1
  fi
done

# Apply defaults for optional version variables
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.2}"
YQ_VERSION="${YQ_VERSION:-v4.44.3}"
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.1}"

# ---------------------------------------------------------------------------
# Check gh authentication
# ---------------------------------------------------------------------------
if ! gh auth status &>/dev/null; then
  echo "Error: gh CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1 — Register self-hosted runner
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 1: Register self-hosted runner ==="
kubectl config use-context docker-desktop
kubectl create namespace "${{values.app_name}}"
kubectl apply -f runnerdeployment.yaml
kubectl apply -f k8s/runner-rbac.yaml
echo "Runner registered in namespace ${{values.app_name}}."

# ---------------------------------------------------------------------------
# Step 2 — Set GitHub Actions secrets
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Set GitHub Actions secrets ==="
gh secret set DOCKERHUB_USERNAME --body "$DOCKERHUB_USERNAME" --repo "$REPO"
gh secret set DOCKERHUB_TOKEN    --body "$DOCKERHUB_TOKEN"    --repo "$REPO"
gh secret set ARGOCD_PASSWORD    --body "$ARGOCD_PASSWORD"    --repo "$REPO"
gh secret set GH_PAT             --body "$GITHUB_PAT"         --repo "$REPO"
echo "Secrets set:"
gh secret list --repo "$REPO"

# ---------------------------------------------------------------------------
# Step 3 — Set GitHub Actions variables
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Set GitHub Actions variables ==="
gh variable set ARGOCD_VERSION  --body "$ARGOCD_VERSION"  --repo "$REPO"
gh variable set YQ_VERSION      --body "$YQ_VERSION"      --repo "$REPO"
gh variable set KUBECTL_VERSION --body "$KUBECTL_VERSION" --repo "$REPO"
echo "Variables set:"
gh variable list --repo "$REPO"

# ---------------------------------------------------------------------------
# Step 4 — Mirror CLI binaries to Docker Hub
# ---------------------------------------------------------------------------
echo ""
if [ "$SKIP_MIRROR" = true ]; then
  echo "=== Step 4: Skipped (--skip-mirror) ==="
  echo "Ensure christseng89/argocd-bin:${ARGOCD_VERSION}, yq-bin:${YQ_VERSION},"
  echo "and kubectl-bin:${KUBECTL_VERSION} already exist on Docker Hub."
else
  echo "=== Step 4: Trigger mirror-cli-binaries workflow ==="
  gh workflow run mirror-cli-binaries.yaml --repo "$REPO"
  sleep 3
  RUN_ID=$(gh run list --workflow=mirror-cli-binaries.yaml --repo "$REPO" \
    --limit 1 --json databaseId --jq '.[0].databaseId')
  echo "Watching run $RUN_ID (Ctrl-C to detach, workflow continues in background)..."
  gh run watch "$RUN_ID" --repo "$REPO"
fi

# ---------------------------------------------------------------------------
# Step 5 — Add hosts entry (requires Windows Administrator — run manually)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Add Windows hosts entry (manual — requires Administrator) ==="
echo "Open PowerShell as Administrator and run:"
echo ""
echo "  Add-Content C:\\Windows\\System32\\drivers\\etc\\hosts \"127.0.0.1 ${{values.app_name}}-dev.test.com\""
echo ""
echo "Skip if the entry already exists."

# ---------------------------------------------------------------------------
# Step 6 — Trigger the CI/CD workflow
# ---------------------------------------------------------------------------
echo ""
if [ "$SKIP_CICD" = true ]; then
  echo "=== Step 6: Skipped (--skip-cicd) ==="
  echo "Trigger manually at: https://github.com/$REPO/actions"
else
  echo "=== Step 6: Trigger ${{values.app_name}}-cicd workflow ==="
  gh workflow run "${{values.app_name}}-cicd.yaml" --repo "$REPO"
  sleep 3
  CICD_RUN_ID=$(gh run list --workflow="${{values.app_name}}-cicd.yaml" --repo "$REPO" \
    --limit 1 --json databaseId --jq '.[0].databaseId')
  echo "Watching run $CICD_RUN_ID (Ctrl-C to detach, workflow continues in background)..."
  gh run watch "$CICD_RUN_ID" --repo "$REPO"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Setup complete ==="
echo ""
echo "Verify your deployment:"
echo "  ArgoCD dashboard : http://argocd.test.com:9080/"
echo "  App (dev)        : http://${{values.app_name}}-dev.test.com:9080/"
echo ""
echo "Workflow runs: https://github.com/$REPO/actions"
