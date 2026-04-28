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
#   - For phase 7: vault-server-key.json in the repo root

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
  echo "  Supported phases: 3, 4, 5, 5b, 6, 7, 8, 9, 10, 11"
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
  helm repo add jetstack             https://charts.jetstack.io                      2>/dev/null || true
  helm repo add apache-airflow       https://airflow.apache.org                      2>/dev/null || true
  helm repo update
}

install_cert_manager() {
  echo ""
  echo "[cert-manager] Installing cert-manager..."
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --set installCRDs=true \
    --wait --timeout 5m
  echo "cert-manager ready."
}

install_postgresql_redis() {
  echo ""
  echo "[phase 3] Installing PostgreSQL..."
  # Use standard (HDD) storage class — SSD quota is consumed by GKE node boot disks
  helm upgrade --install postgresql bitnami/postgresql \
    --set auth.username=coverline \
    --set auth.password=coverline123 \
    --set auth.database=coverline \
    --set primary.persistence.size=1Gi \
    --set global.storageClass=standard \
    --wait --timeout 10m

  echo "[phase 3] Installing Redis..."
  helm upgrade --install redis bitnami/redis \
    --set auth.enabled=false \
    --set master.persistence.size=1Gi \
    --set global.storageClass=standard \
    --set replica.replicaCount=1 \
    --wait --timeout 10m

  echo "[phase 3] Installing CoverLine apps..."
  helm upgrade --install coverline          phase-4-helm/charts/backend/  --wait --timeout 3m
  helm upgrade --install coverline-frontend phase-4-helm/charts/frontend/ --wait --timeout 3m

  echo "Phase 4 — done."
}

install_argocd() {
  echo ""
  echo "[phase 5] Installing ArgoCD..."
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
  echo "Phase 6 — done."
}

install_argo_rollouts() {
  echo ""
  echo "[phase 5b] Installing Argo Rollouts..."
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
  kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
  echo "Phase 6b — Argo Rollouts ready."
  echo ""
  echo "Next steps:"
  echo "  1. Install the kubectl plugin:  brew install argoproj/tap/kubectl-argo-rollouts"
  echo "  2. Delete the existing Deployment and apply the Rollout:"
  echo "       kubectl delete deployment coverline-backend"
  echo "       kubectl apply -f phase-6b-progressive-delivery/rollout.yaml"
  echo "  3. Apply the AnalysisTemplate:"
  echo "       kubectl apply -f phase-6b-progressive-delivery/analysis-template.yaml"
}

install_observability() {
  echo ""
  echo "[phase 6] Installing observability stack (Prometheus, Grafana, Loki)..."
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f phase-7-observability/kube-prometheus-stack-values.yaml \
    --wait --timeout 10m

  helm upgrade --install loki grafana/loki \
    --namespace monitoring \
    -f phase-7-observability/loki-values.yaml \
    --wait --timeout 5m

  helm upgrade --install promtail grafana/promtail \
    --namespace monitoring \
    -f phase-7-observability/promtail-values.yaml \
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
    -f phase-3-vault/vault-values.yaml \
    --wait --timeout 5m

  echo "Phase 3 — done."
  echo ""
  echo "Next: initialize Vault (run once on a fresh install):"
  echo "  kubectl port-forward -n vault svc/vault 8200:8200 &"
  echo "  export VAULT_ADDR=http://localhost:8200"
  echo "  bash phase-3-vault/vault-init.sh"
}

install_backstage() {
  echo ""
  echo "[phase 11] Installing Backstage IDP..."
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f -

  # Backstage references this secret via extraEnvVarsSecrets — the pod will not
  # schedule if the secret is missing. Create a placeholder so the install
  # succeeds, then remind the user to update it with a real token.
  if ! kubectl get secret backstage-github-token -n backstage &>/dev/null; then
    kubectl create secret generic backstage-github-token \
      --namespace backstage \
      --from-literal=GITHUB_TOKEN=placeholder
    echo ""
    echo "NOTE: Created placeholder 'backstage-github-token' secret."
    echo "  Update it with a real GitHub PAT so Backstage can read the catalog:"
    echo "    kubectl create secret generic backstage-github-token \\"
    echo "      --namespace backstage \\"
    echo "      --from-literal=GITHUB_TOKEN=<your-pat> \\"
    echo "      --dry-run=client -o yaml | kubectl apply -f -"
    echo "  Then restart Backstage:  kubectl rollout restart deploy/backstage -n backstage"
    echo ""
  fi

  # Remove any partially-created PostgreSQL secret from a previous failed install.
  # The Bitnami subchart errors if the secret exists but lacks the expected keys.
  kubectl delete secret backstage-postgresql -n backstage 2>/dev/null || true

  helm repo add backstage https://backstage.github.io/charts 2>/dev/null || true
  helm repo update backstage

  # Pass the PostgreSQL password explicitly so the Bitnami subchart does not
  # attempt to read a partially-created secret from a previous failed install.
  # --wait is intentionally omitted: Backstage pulls a large image and its
  # PostgreSQL subchart adds startup time that exceeds reliable timeout budgets
  # on e2-medium nodes. Verify readiness manually after bootstrap completes.
  helm upgrade --install backstage backstage/backstage \
    --namespace backstage \
    --values phase-11-capstone/backstage/values.yaml \
    --set postgresql.auth.password=backstage-local-dev-only

  echo ""
  echo "Backstage install submitted (async — image pull takes 3–5 min on e2-medium)."
  echo "  Watch progress:  kubectl get pods -n backstage -w"
  echo "  Access portal:   kubectl port-forward -n backstage svc/backstage 7007:7007"
}

install_airflow() {
  echo ""
  echo "[phase 9] Installing Apache Airflow..."
  kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

  # Generate Fernet key if the secret doesn't already exist
  if ! kubectl get secret airflow-fernet-key -n airflow &>/dev/null; then
    FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
    kubectl create secret generic airflow-fernet-key \
      --namespace airflow \
      --from-literal=fernet-key="$FERNET_KEY"
    echo "[phase 9] Fernet key secret created."
  else
    echo "[phase 9] Fernet key secret already exists — skipping."
  fi

  helm upgrade --install airflow apache-airflow/airflow \
    --namespace airflow \
    --values phase-9-data-platform/airflow/values.yaml \
    --version "1.13.*" \
    --wait --timeout 10m

  echo "Phase 9 — Airflow ready."
  echo ""
  echo "Next steps:"
  echo "  Access the UI:  kubectl port-forward -n airflow svc/airflow-webserver 8080:8080"
  echo "  Login:          http://localhost:8080  (admin / admin)"
  echo ""
  echo "  Complete Workload Identity setup (Step 2 of README):"
  echo "    gcloud iam service-accounts create airflow-worker --project platform-eng-lab-will"
  echo "    # then follow phase-9-data-platform/README.md Step 2"
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
  5b)
    install_observability
    install_postgresql_redis
    install_argocd
    install_argo_rollouts
    ;;
  6)
    install_observability
    install_postgresql_redis
    install_argocd
    ;;
  7)
    install_observability
    install_postgresql_redis
    install_argocd
    install_cert_manager
    install_vault
    ;;
  8)
    install_observability
    install_postgresql_redis
    install_argocd

    echo ""
    echo "[phase 8] Configuring backend — disabling Vault injection, setting env vars directly..."
    kubectl annotate deployment coverline-backend \
      vault.hashicorp.com/agent-inject=false --overwrite
    # Inject DB and Redis env vars directly
    kubectl set env deployment/coverline-backend \
      DB_HOST=postgresql \
      DB_NAME=coverline \
      DB_USER=coverline \
      DB_PASSWORD=coverline123 \
      REDIS_HOST=redis-master
    kubectl rollout status deployment/coverline-backend --timeout=3m

    echo ""
    echo "[phase 8] HPA, PDB and Cluster Autoscaler require no additional installs."
    echo "  Apply manifests manually:"
    echo "    kubectl apply -f phase-8-advanced-k8s/hpa.yaml"
    echo "    kubectl apply -f phase-8-advanced-k8s/pdb.yaml"
    echo "  Verify metrics API (required for HPA):"
    echo "    kubectl get apiservice v1beta1.metrics.k8s.io"
    echo "  Run load test:"
    echo "    brew install k6  # if not already installed"
    echo "    kubectl port-forward svc/coverline-backend 5000:5000 &"
    echo "    k6 run phase-8-advanced-k8s/load-test.js"
    echo ""
    echo "Phase 8 — done."
    ;;
  9)
    install_observability
    install_postgresql_redis
    install_argocd

    echo ""
    echo "[phase 9] Configuring backend — disabling Vault injection, setting env vars directly..."
    kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || true
    kubectl annotate deployment coverline-backend \
      vault.hashicorp.com/agent-inject=false --overwrite
    kubectl set env deployment/coverline-backend \
      DB_HOST=postgresql \
      DB_NAME=coverline \
      DB_USER=coverline \
      DB_PASSWORD=coverline123 \
      REDIS_HOST=redis-master
    kubectl rollout status deployment/coverline-backend --timeout=3m

    install_airflow
    ;;
  10)
    install_observability
    install_postgresql_redis
    install_argocd

    echo ""
    echo "[phase 10] Configuring backend — disabling Vault injection, setting env vars directly..."
    # Remove lingering Vault webhook if present (installed in a previous phase 7 run)
    kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || true
    kubectl annotate deployment coverline-backend \
      vault.hashicorp.com/agent-inject=false --overwrite
    # Inject DB and Redis env vars directly
    kubectl set env deployment/coverline-backend \
      DB_HOST=postgresql \
      DB_NAME=coverline \
      DB_USER=coverline \
      DB_PASSWORD=coverline123 \
      REDIS_HOST=redis-master
    kubectl rollout status deployment/coverline-backend --timeout=3m

    echo ""
    echo "[phase 10] Apply security manifests manually:"
    echo "    kubectl apply -f phase-10-security/rbac.yaml"
    echo "    kubectl apply -f phase-10-security/network-policies.yaml"
    echo ""
    echo "[phase 10] Pod security (Step 3) requires the updated Docker image."
    echo "  Build it first by pushing a change to a feature branch (triggers CI)."
    echo "  Then apply:"
    echo "    helm upgrade coverline phase-4-helm/charts/backend/ \\"
    echo "      -f phase-10-security/security-context-values.yaml"
    echo ""
    echo "Phase 10 — done."
    ;;
  11)
    install_observability
    install_postgresql_redis
    install_argocd

    echo ""
    echo "[phase 11] Configuring backend — disabling Vault injection, setting env vars directly..."
    kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || true
    kubectl annotate deployment coverline-backend \
      vault.hashicorp.com/agent-inject=false --overwrite
    kubectl set env deployment/coverline-backend \
      DB_HOST=postgresql \
      DB_NAME=coverline \
      DB_USER=coverline \
      DB_PASSWORD=coverline123 \
      REDIS_HOST=redis-master
    kubectl rollout status deployment/coverline-backend --timeout=3m

    install_backstage

    echo ""
    echo "[phase 11] Applying ArgoCD ApplicationSets..."
    kubectl apply -n argocd -f phase-11-capstone/argocd/applicationset.yaml
    kubectl apply -n argocd -f phase-11-capstone/argocd/security-baseline-appset.yaml

    echo ""
    echo "[phase 11] Applying Grafana platform-overview dashboard..."
    kubectl apply -n monitoring -f phase-11-capstone/grafana/platform-overview-dashboard.yaml

    echo ""
    echo "Phase 11 — done."
    echo ""
    echo "Next steps:"
    echo "  Access Backstage:  kubectl port-forward -n backstage svc/backstage 7007:7007"
    echo "  Access ArgoCD:     kubectl port-forward -n argocd svc/argocd-server 8080:443"
    echo "  ArgoCD password:   kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
    echo "  See phase-11-capstone/README.md for multi-environment Terraform and promotion pipeline steps."
    ;;
  *)
    echo "Unknown phase: $PHASE. Supported: 3, 4, 5, 5b, 6, 7, 8, 9, 10, 11"
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
