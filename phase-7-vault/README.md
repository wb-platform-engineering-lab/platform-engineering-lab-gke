# Phase 7 — Secrets Management (Vault)

## What was built

- HashiCorp Vault deployed on GKE via Helm (standalone mode)
- KV v2 secrets engine storing CoverLine database and Redis credentials
- Kubernetes auth method — pods authenticate to Vault using their ServiceAccount JWT
- Vault Agent injector — secrets mounted as files into pod filesystem (no env vars in manifests)
- Least-privilege policy: backend can only read `secret/data/coverline/backend`
- Secrets removed from `values.yaml`, ConfigMaps, and environment variables

## Architecture

```
coverline-backend pod
    ├── init container: vault-agent (authenticates + fetches secrets)
    │       └── ServiceAccount JWT → Vault Kubernetes auth → token
    │               └── reads secret/data/coverline/backend
    │                       └── writes /vault/secrets/backend.env
    └── app container: coverline-backend
            └── sources /vault/secrets/backend.env at startup
                    └── DB_PASSWORD, DB_USERNAME, DB_HOST, DB_NAME, REDIS_HOST
```

## Screenshots

### Vault UI — Secrets Engine
![Vault Secrets](screenshots/vault-secrets.png)

### Vault UI — Kubernetes Auth Role
![Vault Auth](screenshots/vault-auth.png)

### Pod — Injected Secret File
![Secret Injected](screenshots/secret-injected.png)

---

## Install Vault

```bash
# Add Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create namespace
kubectl create namespace vault

# Install Vault
helm install vault hashicorp/vault \
  --namespace vault \
  -f phase-7-vault/vault-values.yaml

# Wait for pod to be ready
kubectl get pods -n vault -w
```

---

## Initialize and Configure Vault

```bash
# Port-forward Vault
kubectl port-forward -n vault svc/vault 8200:8200

# In a new terminal — run the init script
export VAULT_ADDR="http://localhost:8200"
bash phase-7-vault/vault-init.sh

# Create policies and Kubernetes roles
bash phase-7-vault/vault-policy.sh
```

---

## Inject Secrets into the Backend Pod

```bash
# Patch the backend deployment to enable Vault Agent injection
kubectl patch deployment coverline-backend \
  --patch-file phase-7-vault/vault-agent-patch.yaml

# Watch the rollout
kubectl rollout status deployment/coverline-backend

# Verify secret was injected
kubectl exec -it deploy/coverline-backend -c coverline-backend \
  -- cat /vault/secrets/backend.env
```

Expected output:
```
export DB_PASSWORD="coverline123"
export DB_USERNAME="coverline"
export DB_HOST="postgresql.default.svc.cluster.local"
export DB_NAME="coverline"
export REDIS_HOST="redis-master.default.svc.cluster.local"
```

---

## Access the Vault UI

```bash
kubectl port-forward -n vault svc/vault 8200:8200
```

Open `http://localhost:8200` — login with the root token from vault-init.sh output.

---

## Verify Kubernetes Auth

```bash
# Check the role was created
export VAULT_ADDR="http://localhost:8200"
vault read auth/kubernetes/role/coverline-backend

# Check the policy
vault policy read coverline-backend

# List secrets
vault kv list secret/coverline/
vault kv get secret/coverline/backend
```

---

## Troubleshooting

### Vault pod stuck in Init state

**Cause:** Vault is not initialized yet.

**Fix:** Initialize manually:
```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json
```

### Vault sealed after pod restart

**Cause:** Vault seals itself on restart — the unseal key is required each time.

**Fix:**
```bash
export VAULT_ADDR="http://localhost:8200"
vault operator unseal <UNSEAL_KEY>
```

> In production, use Vault Auto Unseal with GCP KMS to avoid this manual step.

### `permission denied` when backend reads secret

**Cause:** The ServiceAccount name or namespace doesn't match the Kubernetes role.

**Fix:** Verify the role binding:
```bash
vault read auth/kubernetes/role/coverline-backend
# bound_service_account_names should be "coverline-backend"
# bound_service_account_namespaces should be "default"

kubectl get serviceaccount coverline-backend -n default
```

### Vault Agent init container stuck in `Init:0/1`

**Cause:** The Vault Agent can't reach the Vault server.

**Fix:** Check the Vault service is reachable from the default namespace:
```bash
kubectl run vault-test --rm -it --image=curlimages/curl -- \
  curl http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

---

## Production Considerations

### 1. Use Vault Auto Unseal with GCP KMS
In this lab, Vault must be manually unsealed after every restart. In production, Vault should be configured to auto-unseal using GCP Cloud KMS — the unseal key is stored in GCP and Vault unseals itself automatically on startup, eliminating manual intervention and enabling high availability.

```hcl
seal "gcpckms" {
  project     = "platform-eng-lab-will"
  region      = "global"
  key_ring    = "vault-keyring"
  crypto_key  = "vault-unseal-key"
}
```

### 2. Run Vault in HA mode with integrated storage (Raft)
This lab deploys Vault in standalone mode with a single pod. In production, Vault should run in HA mode with at least 3 nodes using Raft integrated storage — no external storage backend required, built-in replication, and automatic leader election.

### 3. Use dynamic secrets for PostgreSQL
This lab stores static PostgreSQL credentials in Vault. In production, use Vault's PostgreSQL secrets engine to generate short-lived, unique credentials for each pod on demand — credentials expire automatically, no rotation scripts required, and a compromised credential is worthless after TTL.

```bash
vault secrets enable database
vault write database/config/coverline \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgresql:5432/coverline" \
  allowed_roles="coverline-backend"

vault write database/roles/coverline-backend \
  db_name=coverline \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
  default_ttl="1h" \
  max_ttl="24h"
```

### 4. Rotate the root token immediately after setup
In this lab, the root token is used for all Vault operations. In production, the root token should be revoked immediately after initial setup and replaced with a limited admin token with a short TTL. The root token should only be regenerated for break-glass emergency access.

### 5. Audit logging
In this lab, no audit log is configured. In production, every Vault read and write should be logged to a persistent audit backend (file or syslog). Vault audit logs are critical for compliance (who accessed which secret, when) and incident investigation.

```bash
vault audit enable file file_path=/vault/logs/audit.log
```

### 6. Integrate Vault with the CI/CD pipeline
In this lab, Vault is only used for pod secret injection. In production, GitHub Actions should also authenticate to Vault using Workload Identity (OIDC) to retrieve secrets for the CI/CD pipeline — eliminating `GCP_SA_KEY` and database credentials from GitHub Secrets entirely.
