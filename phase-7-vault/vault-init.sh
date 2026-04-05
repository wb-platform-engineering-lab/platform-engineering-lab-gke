#!/bin/bash
# vault-init.sh — Initialize Vault, configure Kubernetes auth, and store CoverLine secrets
# Run this once after Vault is deployed and unsealed.
# Prerequisites: kubectl port-forward is running on localhost:8200

set -euo pipefail

VAULT_ADDR="http://localhost:8200"
export VAULT_ADDR

echo "=== Vault Init ==="

# --- 1. Initialize Vault ---
echo "[1/6] Initializing Vault..."
INIT_OUTPUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo "Unseal key: $UNSEAL_KEY"
echo "Root token: $ROOT_TOKEN"
echo ""
echo "IMPORTANT: Save these values securely. They will not be shown again."
echo ""

# --- 2. Unseal Vault ---
echo "[2/6] Unsealing Vault..."
vault operator unseal "$UNSEAL_KEY"

# --- 3. Login ---
echo "[3/6] Logging in..."
vault login "$ROOT_TOKEN"

# --- 4. Enable KV secrets engine ---
echo "[4/6] Enabling KV v2 secrets engine..."
vault secrets enable -path=secret kv-v2

# --- 5. Store CoverLine secrets ---
echo "[5/6] Writing CoverLine secrets..."
vault kv put secret/coverline/backend \
  db_password="coverline123" \
  db_username="coverline" \
  db_host="postgresql.default.svc.cluster.local" \
  db_name="coverline" \
  redis_host="redis-master.default.svc.cluster.local"

echo "Secrets written to secret/coverline/backend"

# --- 6. Enable Kubernetes auth ---
echo "[6/6] Enabling Kubernetes auth..."
vault auth enable kubernetes

KUBE_HOST=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.server}')

KUBE_CA=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)

vault write auth/kubernetes/config \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA"

echo ""
echo "=== Vault initialized successfully ==="
echo "Next step: run vault-policy.sh to create policies and roles"
