#!/bin/bash
# vault-dynamic-secrets.sh — Configure dynamic PostgreSQL credentials via Vault database engine.
# Vault generates short-lived, unique credentials per request — no static passwords.
# Run after vault-init.sh and vault-policy.sh.
# Prerequisites: PostgreSQL is running, VAULT_ADDR and VAULT_TOKEN are set.

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_ADDR

# PostgreSQL superuser credentials (used once by Vault to create dynamic roles)
PG_HOST="${PG_HOST:-postgresql.default.svc.cluster.local}"
PG_PORT="${PG_PORT:-5432}"
PG_DB="coverline"
PG_ADMIN_USER="postgres"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"  # pass via env, never hardcode

if [[ -z "$PG_ADMIN_PASSWORD" ]]; then
  echo "ERROR: PG_ADMIN_PASSWORD env var is required"
  echo "Usage: PG_ADMIN_PASSWORD=<password> bash vault-dynamic-secrets.sh"
  exit 1
fi

echo "=== Configuring Vault Dynamic PostgreSQL Secrets ==="

# --- 1. Enable database secrets engine ---
echo "[1/4] Enabling database secrets engine..."
vault secrets enable database 2>/dev/null || echo "Already enabled"

# --- 2. Configure PostgreSQL connection ---
echo "[2/4] Configuring PostgreSQL connection..."
vault write database/config/coverline \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="coverline-backend,coverline-readonly" \
  connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=disable" \
  username="$PG_ADMIN_USER" \
  password="$PG_ADMIN_PASSWORD"

echo "PostgreSQL connection configured"

# --- 3. Create dynamic role for the backend (read/write, 1h TTL) ---
echo "[3/4] Creating coverline-backend dynamic role..."
vault write database/roles/coverline-backend \
  db_name="coverline" \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH
      LOGIN
      PASSWORD '{{password}}'
      VALID UNTIL '{{expiration}}';
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";
  " \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# --- 4. Create readonly role for reporting/analytics ---
echo "[4/4] Creating coverline-readonly dynamic role..."
vault write database/roles/coverline-readonly \
  db_name="coverline" \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH
      LOGIN
      PASSWORD '{{password}}'
      VALID UNTIL '{{expiration}}';
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
  " \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="4h"

# --- Update Vault policy to allow dynamic secret access ---
vault policy write coverline-backend - <<'EOF'
# Static secrets (Redis host, app config)
path "secret/data/coverline/backend" {
  capabilities = ["read"]
}

# Dynamic PostgreSQL credentials
path "database/creds/coverline-backend" {
  capabilities = ["read"]
}

# Allow renewing leases
path "sys/leases/renew" {
  capabilities = ["update"]
}

# Allow listing (for debugging)
path "secret/metadata/coverline/*" {
  capabilities = ["list"]
}
EOF

echo ""
echo "=== Dynamic secrets configured ==="
echo ""
echo "Test — generate a credential on demand:"
echo "  vault read database/creds/coverline-backend"
echo ""
echo "Each call returns a unique username/password that expires after 1h."
echo "Vault automatically revokes expired credentials in PostgreSQL."
