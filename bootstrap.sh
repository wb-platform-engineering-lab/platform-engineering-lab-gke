#!/bin/bash
# bootstrap.sh — Reinstall all cluster dependencies for a given phase.
# Each phase is cumulative — phase 7 installs everything from phases 3 through 7.
# Safe to re-run (idempotent).
#
# Usage:
#   bash bootstrap.sh --phase 7
#   bash bootstrap.sh --phase 6
#   bash bootstrap.sh --phase 3
#
# Prerequisites:
#   - kubectl configured (gcloud container clusters get-credentials ...)
#   - helm installed
#   - For phase 7+: vault-server-key.json in the repo root

set -euo pipefail

PHASE=""

for arg in "$@"; do
  case $arg in
    --phase) PHASE="$2"; shift ;;
  esac
  shift || true
done

if [ -z "$PHASE" ]; then
  echo "Usage: bash bootstrap.sh --phase <number>"
  echo "  Supported phases: 3, 4, 5, 6, 7"
  exit 1
fi

echo "========================================"
echo " CoverLine — Cluster Bootstrap (Phase $PHASE)"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

add_helm_repos() {
  echo "[repos] Adding Helm repos..."
  helm repo add bitnami              https://charts.bitnami.com/bitnami              2>/dev/null || true
  helm repo add hashicorp            https://helm.releases.hashicorp.com             2>/dev/null || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add grafana              https://grafana.github.io/helm-charts           2>/dev/null || true
  helm repo update
}

install_postgresql_redis() {
  echo ""
  echo "[phase 3] Installing PostgreSQL..."
  helm upgrade --install postgresql bitnami/postgresql \
    --set auth.username=coverline \
    --set auth.password=coverline123 \
    --set auth.database=coverline \
    --set primary.persistence.size=1Gi \
    --wait --timeout 5m

  echo "[phase 3] Installing Redis..."
  helm upgrade --install redis bitnami/redis \
    --set auth.enabled=false \
    --set master.persistence.size=1Gi \
    --wait --timeout 5m

  echo "[phase 3] Installing CoverLine apps..."
  helm upgrade --install coverline          phase-3-helm/charts/backend/  --wait --timeout 3m
  helm upgrade --install coverline-frontend phase-3-helm/charts/frontend/ --wait --timeout 3m

  echo "Phase 3 — done."
}

install_argocd() {
  echo ""
  echo "[phase 5] Installing ArgoCD..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
  echo "Phase 5 — done."
}

install_observability() {
  echo ""
  echo "[phase 6] Installing observability stack (Prometheus, Grafana, Loki)..."
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f phase-6-observability/kube-prometheus-stack-values.yaml \
    --wait --timeout 10m

  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    -f phase-6-observability/loki-values.yaml \
    --wait --timeout 5m

  helm upgrade --install promtail grafana/promtail \
    --namespace monitoring \
    -f phase-6-observability/promtail-values.yaml \
    --wait --timeout 5m

  echo "Phase 6 — done."
}

install_vault() {
  echo ""
  echo "[phase 7] Installing Vault..."

  if [ ! -f vault-server-key.json ]; then
    echo ""
    echo "ERROR: vault-server-key.json not found. Generate it with:"
    echo ""
    echo "  gcloud iam service-accounts keys create vault-server-key.json \\"
    echo "    --iam-account=vault-server@platform-eng-lab-will.iam.gserviceaccount.com \\"
    echo "    --project=platform-eng-lab-will"
    echo ""
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

  echo "Phase 7 — done."
  echo ""
  echo "Next: initialize Vault (run once on a fresh install):"
  echo "  kubectl port-forward -n vault svc/vault 8200:8200 &"
  echo "  export VAULT_ADDR=http://localhost:8200"
  echo "  bash phase-7-vault/vault-init.sh"
}

# ---------------------------------------------------------------------------
# Phase execution — each phase is cumulative
# ---------------------------------------------------------------------------

add_helm_repos

case $PHASE in
  3|4)
    install_postgresql_redis
    ;;
  5)
    install_postgresql_redis
    install_argocd
    ;;
  6)
    install_postgresql_redis
    install_argocd
    install_observability
    ;;
  7)
    install_postgresql_redis
    install_argocd
    install_observability
    install_vault
    ;;
  *)
    echo "Unknown phase: $PHASE. Supported: 3, 4, 5, 6, 7"
    exit 1
    ;;
esac

echo ""
echo "========================================"
echo " Bootstrap complete! (Phase $PHASE)"
echo "========================================"
echo ""
kubectl get pods --all-namespaces | grep -v "Running\|Completed" || true
echo ""
kubectl get pods --all-namespaces | grep "Running" | wc -l | xargs -I{} echo "{} pods running"
