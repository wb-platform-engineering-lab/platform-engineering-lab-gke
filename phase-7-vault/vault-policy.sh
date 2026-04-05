#!/bin/bash
# vault-policy.sh — Create Vault policies and Kubernetes roles for CoverLine
# Run after vault-init.sh

set -euo pipefail

VAULT_ADDR="http://localhost:8200"
export VAULT_ADDR

echo "=== Creating Vault policies and Kubernetes roles ==="

# --- 1. Create policy: coverline-backend ---
echo "[1/3] Creating coverline-backend policy..."
vault policy write coverline-backend - <<EOF
# Allow the backend to read its secrets
path "secret/data/coverline/backend" {
  capabilities = ["read"]
}

# Allow listing available secrets (for debugging)
path "secret/metadata/coverline/*" {
  capabilities = ["list"]
}
EOF

echo "Policy coverline-backend created"

# --- 2. Create Kubernetes role ---
echo "[2/3] Creating Kubernetes auth role..."
vault write auth/kubernetes/role/coverline-backend \
  bound_service_account_names=coverline-backend \
  bound_service_account_namespaces=default \
  policies=coverline-backend \
  ttl=1h

echo "Role coverline-backend created"

# --- 3. Create ServiceAccount in Kubernetes ---
echo "[3/3] Creating ServiceAccount in Kubernetes..."
kubectl create serviceaccount coverline-backend --namespace default \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Policies and roles configured ==="
echo "Next step: apply vault-agent-patch.yaml to inject secrets into the backend pod"
