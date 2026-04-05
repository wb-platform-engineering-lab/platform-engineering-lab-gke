#!/bin/bash
# vault-init.sh — Initialize Vault, configure Kubernetes auth, store CoverLine secrets,
#                 enable audit logging, and revoke the root token.
# Run once after Vault is deployed.
# Prerequisites: kubectl port-forward is running on localhost:8200

set -euo pipefail

VAULT_ADDR="http://localhost:8200"
export VAULT_ADDR

echo "=== Vault Init ==="

# --- 1. Initialize Vault ---
echo "[1/8] Initializing Vault..."
INIT_OUTPUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

# With GCP KMS auto-unseal, the unseal_keys_b64 are recovery keys (not unseal keys)
echo ""
echo "Recovery key : $UNSEAL_KEY"
echo "Root token   : $ROOT_TOKEN"
echo ""
echo "IMPORTANT: Save the recovery key securely. Store it in GCP Secret Manager."
echo ""

# --- 2. Login with root token ---
echo "[2/8] Logging in with root token..."
vault login "$ROOT_TOKEN"

# --- 3. Enable KV v2 secrets engine ---
echo "[3/8] Enabling KV v2 secrets engine..."
vault secrets enable -path=secret kv-v2

# --- 4. Store CoverLine secrets ---
echo "[4/8] Writing CoverLine secrets..."
vault kv put secret/coverline/backend \
  db_password="coverline123" \
  db_username="coverline" \
  db_host="postgresql.default.svc.cluster.local" \
  db_name="coverline" \
  redis_host="redis-master.default.svc.cluster.local"

echo "Secrets written to secret/coverline/backend"

# --- 5. Enable Kubernetes auth ---
echo "[5/8] Enabling Kubernetes auth..."
vault auth enable kubernetes

KUBE_HOST=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.server}')

KUBE_CA=$(kubectl config view --raw --minify --flatten \
  -o jsonpath='{.clusters[].cluster.certificate-authority-data}' | base64 --decode)

vault write auth/kubernetes/config \
  kubernetes_host="$KUBE_HOST" \
  kubernetes_ca_cert="$KUBE_CA"

# --- 6. Enable GitHub Actions JWT auth (for CI/CD OIDC) ---
echo "[6/8] Enabling GitHub Actions JWT auth..."
vault auth enable -path=jwt/github jwt

vault write auth/jwt/github/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"

echo "GitHub JWT auth enabled at auth/jwt/github"

# --- 7. Enable audit logging ---
echo "[7/8] Enabling audit logging..."
vault audit enable file file_path=/vault/logs/audit.log

echo "Audit log enabled at /vault/logs/audit.log"

# --- 8. Create admin token and revoke root token ---
echo "[8/8] Creating admin token and revoking root token..."

# Create a reusable admin policy
vault policy write vault-admin - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

# Create a periodic admin token (renewable, 8h TTL)
ADMIN_TOKEN=$(vault token create \
  -policy=vault-admin \
  -period=8h \
  -format=json | jq -r '.auth.client_token')

echo ""
echo "Admin token: $ADMIN_TOKEN"
echo "Save this token — it replaces the root token for day-to-day operations."
echo ""

# Revoke root token
vault token revoke "$ROOT_TOKEN"
echo "Root token revoked."

echo ""
echo "=== Vault initialized successfully ==="
echo "Next step: run vault-policy.sh to create app policies and roles"
echo "           run vault-dynamic-secrets.sh to configure dynamic PostgreSQL credentials"
