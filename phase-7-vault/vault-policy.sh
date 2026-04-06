#!/bin/bash
# vault-policy.sh — Create Vault policies and auth roles for CoverLine pods and GitHub Actions.
# Run after vault-init.sh.

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_ADDR

GITHUB_REPO="wb-platform-engineering-lab/platform-engineering-lab-gke"

echo "=== Creating Vault policies and auth roles ==="

# --- 1. Policy: coverline-backend (pods) ---
echo "[1/4] Creating coverline-backend policy..."
vault policy write coverline-backend - <<'EOF'
# Static secrets (Redis host, app config)
path "secret/data/coverline/backend" {
  capabilities = ["read"]
}

# Dynamic PostgreSQL credentials (populated by vault-dynamic-secrets.sh)
path "database/creds/coverline-backend" {
  capabilities = ["read"]
}

# Allow renewing leases
path "sys/leases/renew" {
  capabilities = ["update"]
}

path "secret/metadata/coverline/*" {
  capabilities = ["list"]
}
EOF

# --- 2. Kubernetes auth role: coverline-backend ---
echo "[2/4] Creating Kubernetes auth role for backend pods..."
vault write auth/kubernetes/role/coverline-backend \
  bound_service_account_names=coverline-backend \
  bound_service_account_namespaces=default \
  policies=coverline-backend \
  ttl=1h

# Create the ServiceAccount in Kubernetes
kubectl create serviceaccount coverline-backend --namespace default \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Kubernetes role coverline-backend created"

# --- 3. Policy: github-ci (GitHub Actions) ---
echo "[3/4] Creating github-ci policy..."
vault policy write github-ci - <<'EOF'
# Allow CI to read backend secrets for smoke tests / deployment verification
path "secret/data/coverline/backend" {
  capabilities = ["read"]
}

# Allow CI to generate readonly DB credentials for integration tests
path "database/creds/coverline-readonly" {
  capabilities = ["read"]
}
EOF

# --- 4. JWT auth role: github-ci ---
echo "[4/4] Creating GitHub Actions JWT auth role..."
vault write auth/jwt/github/role/github-ci - <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["https://github.com/${GITHUB_REPO}"],
  "user_claim": "actor",
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${GITHUB_REPO}",
    "ref": "refs/heads/main"
  },
  "policies": ["github-ci"],
  "ttl": "15m"
}
EOF

echo ""
echo "=== Policies and roles configured ==="
echo ""
echo "Roles created:"
echo "  - Kubernetes: coverline-backend (for pods in namespace default)"
echo "  - JWT:        github-ci (for GitHub Actions on branch main)"
echo ""
echo "Next step: run vault-dynamic-secrets.sh to configure dynamic PostgreSQL credentials"
