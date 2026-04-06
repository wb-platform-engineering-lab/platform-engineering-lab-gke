#!/bin/bash
# bootstrap.sh — Reinstall all cluster dependencies on a fresh GKE cluster.
# Safe to re-run (idempotent). Run from the repo root.
#
# Prerequisites:
#   - kubectl configured (gcloud container clusters get-credentials ...)
#   - helm installed
#   - vault-server-key.json present in the repo root (GCP SA JSON key)
#
# Usage:
#   bash bootstrap.sh
#   bash bootstrap.sh --skip-vault     # skip Vault if already installed
#   bash bootstrap.sh --skip-argocd   # skip ArgoCD if already installed

set -euo pipefail

SKIP_VAULT=false
SKIP_ARGOCD=false

for arg in "$@"; do
  case $arg in
    --skip-vault)   SKIP_VAULT=true ;;
    --skip-argocd)  SKIP_ARGOCD=true ;;
  esac
done

echo "========================================"
echo " CoverLine — Cluster Bootstrap"
echo "========================================"
echo ""

# --- 1. Helm repos ---
echo "[1/6] Adding Helm repos..."
helm repo add bitnami   https://charts.bitnami.com/bitnami   2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com  2>/dev/null || true
helm repo update

# --- 2. PostgreSQL ---
echo ""
echo "[2/6] Installing PostgreSQL..."
helm upgrade --install postgresql bitnami/postgresql \
  --set auth.username=coverline \
  --set auth.password=coverline123 \
  --set auth.database=coverline \
  --set primary.persistence.size=1Gi \
  --wait --timeout 5m

echo "PostgreSQL ready."

# --- 3. Redis ---
echo ""
echo "[3/6] Installing Redis..."
helm upgrade --install redis bitnami/redis \
  --set auth.enabled=false \
  --set master.persistence.size=1Gi \
  --wait --timeout 5m

echo "Redis ready."

# --- 4. ArgoCD ---
if [ "$SKIP_ARGOCD" = false ]; then
  echo ""
  echo "[4/6] Installing ArgoCD..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
  echo "ArgoCD ready."
else
  echo ""
  echo "[4/6] Skipping ArgoCD."
fi

# --- 5. Vault ---
if [ "$SKIP_VAULT" = false ]; then
  echo ""
  echo "[5/6] Installing Vault..."

  if [ ! -f vault-server-key.json ]; then
    echo "ERROR: vault-server-key.json not found in repo root."
    echo "Generate it with:"
    echo "  gcloud iam service-accounts keys create vault-server-key.json \\"
    echo "    --iam-account=vault-server@platform-eng-lab-will.iam.gserviceaccount.com \\"
    echo "    --project=platform-eng-lab-will"
    exit 1
  fi

  kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic vault-kms-credentials \
    --from-file=credentials.json=vault-server-key.json \
    --namespace vault \
    --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install vault hashicorp/vault \
    --namespace vault \
    -f phase-7-vault/vault-values.yaml \
    --wait --timeout 5m

  echo "Vault ready."
  echo ""
  echo "Next: initialize Vault with:"
  echo "  kubectl port-forward -n vault svc/vault 8200:8200 &"
  echo "  export VAULT_ADDR=http://localhost:8200"
  echo "  bash phase-7-vault/vault-init.sh"
else
  echo ""
  echo "[5/6] Skipping Vault."
fi

# --- 6. CoverLine apps ---
echo ""
echo "[6/6] Installing CoverLine apps..."
helm upgrade --install coverline          phase-3-helm/charts/backend/  --wait --timeout 3m
helm upgrade --install coverline-frontend phase-3-helm/charts/frontend/ --wait --timeout 3m

echo ""
echo "========================================"
echo " Bootstrap complete!"
echo "========================================"
echo ""
kubectl get pods
