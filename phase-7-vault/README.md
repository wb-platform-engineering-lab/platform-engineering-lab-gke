# Phase 7 — Secrets Management (Vault)

---

> **CoverLine — 100,000 members. January.**
>
> CoverLine was preparing for its Series B. As part of due diligence, the investors hired an external security firm to audit the codebase. The audit took three days. The report took one paragraph to deliver its most critical finding:
>
> *"Database credentials for the production PostgreSQL instance were found committed in plaintext in the application's Git history. The credentials appear in 14 commits across 3 branches, including the public-facing repository. These credentials have not been rotated in 11 months."*
>
> The CISO read the report at 8 AM. By 9 AM, the credentials were rotated. By 10 AM, three engineers were in a war room. The database password had been in the repo since the first sprint. Every contractor, every open-source contributor, every person who had ever cloned the repo had it.
>
> The Series B was delayed by six weeks pending a full security remediation.
>
> *"We didn't have a secrets problem,"* the CISO said. *"We had a culture problem. Secrets need to be impossible to commit, not just discouraged."*
>
> The decision: HashiCorp Vault. Credentials never touch the filesystem. Pods get short-lived dynamic credentials that rotate automatically. Git contains no secrets — not even accidentally.

---

## What was built

- HashiCorp Vault in **HA mode** (3 nodes, Raft integrated storage) on GKE
- **GCP KMS Auto Unseal** — Vault unseals itself on restart, no manual key required
- KV v2 secrets engine for static secrets (Redis host, app config)
- **Dynamic PostgreSQL credentials** — Vault generates short-lived unique credentials per pod
- Kubernetes auth — pods authenticate using their ServiceAccount JWT
- Vault Agent injector — secrets mounted as files, never as env vars or in manifests
- **Audit logging** — every secret read logged with timestamp and client identity
- **Root token revoked** — replaced by a scoped admin token after setup
- **GitHub Actions JWT auth** — CI retrieves secrets from Vault via OIDC, zero static secrets in GitHub

## Architecture

```
coverline-backend pod
    ├── init container: vault-agent
    │       └── ServiceAccount JWT → Vault K8s auth → scoped token
    │               ├── reads static config  → /vault/secrets/backend.env
    │               └── reads dynamic creds  → /vault/secrets/db.env (rotates every 1h)
    └── app container: coverline-backend
            └── sources both secret files at startup

GitHub Actions CD pipeline
    └── OIDC JWT token → Vault JWT auth (jwt/github)
            └── reads secret/data/coverline/backend (masked env vars, never logged)

GCP KMS
    └── wraps Vault master key → auto-unseal on pod restart (no human intervention)
```

## Screenshots

### Vault UI — Secrets Engine
![Vault Secrets](screenshots/vault-secrets.png)

### Vault UI — Kubernetes Auth Role
![Vault Auth](screenshots/vault-auth.png)

### Pod — Injected Secret File
![Secret Injected](screenshots/secret-injected.png)

---

## Step 1 — Provision GCP KMS (Auto Unseal)

```bash
cd phase-7-vault/terraform

terraform init
terraform plan
terraform apply
```

This creates:
- A KMS key ring `vault-keyring` and crypto key `vault-unseal-key`
- A `vault` GCP service account with KMS encrypt/decrypt permissions
- Workload Identity binding between the Vault K8s SA and the GCP SA

---

## Step 2 — Install Vault (HA + Raft)

First, create a JSON key for the Vault GCP service account and store it as a Kubernetes secret. Vault uses this to authenticate with GCP KMS for auto-unseal.

> **Note:** GKE Workload Identity is not used here — the GKE metadata proxy does not support the `?scopes=` parameter required by Vault's `gcpckms` plugin.

```bash
# Generate a new JSON key for the vault-server GCP service account
gcloud iam service-accounts keys create vault-server-key.json \
  --iam-account=vault-server@platform-eng-lab-will.iam.gserviceaccount.com \
  --project=platform-eng-lab-will

# Create the namespace and mount the key as a Kubernetes secret
kubectl create namespace vault

kubectl create secret generic vault-kms-credentials \
  --from-file=credentials.json=vault-server-key.json \
  --namespace vault

# Remove the local key file — it's now stored in the cluster
rm vault-server-key.json
```

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm install vault hashicorp/vault \
  --namespace vault \
  -f phase-7-vault/vault-values.yaml

kubectl get pods -n vault -w
```

All 3 Vault nodes (`vault-0`, `vault-1`, `vault-2`) will start automatically. With GCP KMS configured, they unseal themselves — no manual unseal step required.

Verify HA cluster status:
```bash
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

---

## Step 3 — Initialize Vault

```bash
kubectl port-forward -n vault svc/vault 8200:8200

export VAULT_ADDR="http://localhost:8200"
bash phase-7-vault/vault-init.sh
```

This script:
1. Initializes Vault (outputs recovery key + root token)
2. Enables KV v2 secrets engine
3. Writes CoverLine static secrets
4. Enables Kubernetes auth
5. Enables GitHub Actions JWT auth
6. Enables audit logging at `/vault/logs/audit.log`
7. Creates a scoped admin token (8h TTL)
8. **Revokes the root token**

Save the recovery key in GCP Secret Manager:
```bash
echo -n "<RECOVERY_KEY>" | gcloud secrets create vault-recovery-key \
  --data-file=- --project=platform-eng-lab-will
```

---

## Step 4 — Create Policies and Auth Roles

```bash
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="<ADMIN_TOKEN_FROM_STEP_3>"

bash phase-7-vault/vault-policy.sh
```

This creates:
- Policy `coverline-backend` — read static secrets + generate dynamic DB credentials
- Kubernetes role `coverline-backend` — binds the pod ServiceAccount to the policy
- Policy `github-ci` — read secrets + generate readonly DB credentials for tests
- JWT role `github-ci` — bound to `wb-platform-engineering-lab/platform-engineering-lab-gke`, branch `main`, TTL 15min

---

## Step 5 — Configure Dynamic PostgreSQL Credentials

```bash
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="<ADMIN_TOKEN>"

PG_ADMIN_PASSWORD=$(kubectl get secret postgresql \
  -o jsonpath='{.data.postgres-password}' | base64 --decode)

PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD" bash phase-7-vault/vault-dynamic-secrets.sh
```

Test — generate a credential on demand:
```bash
vault read database/creds/coverline-backend
```

Output:
```
Key                Value
---                -----
lease_id           database/creds/coverline-backend/abc123
lease_duration     1h
lease_renewable    true
password           A1a-xyz789...   ← unique, expires in 1h, then auto-revoked in PostgreSQL
username           v-k8s-coverli-xyz
```

Each pod gets its own credentials. Vault revokes them automatically in PostgreSQL when the TTL expires.

---

## Step 6 — Inject Secrets into the Backend Pod

```bash
kubectl patch deployment coverline-backend \
  --patch-file phase-7-vault/vault-agent-patch.yaml

kubectl rollout status deployment/coverline-backend

# Verify static secrets
kubectl exec -it deploy/coverline-backend -c coverline-backend \
  -- cat /vault/secrets/backend.env

# Verify dynamic DB credentials
kubectl exec -it deploy/coverline-backend -c coverline-backend \
  -- cat /vault/secrets/db.env
```

---

## Step 7 — Verify GitHub Actions JWT Auth

The CD pipeline (`cd.yml`) now authenticates to Vault using OIDC JWT instead of static secrets.

On the next push to `main`, the workflow:
1. Exchanges its GitHub OIDC token for a Vault token (TTL: 15min)
2. Reads `secret/data/coverline/backend` — values exposed as masked env vars
3. Vault token expires automatically — no cleanup needed

Check the audit log to confirm:
```bash
kubectl exec -n vault vault-0 -- cat /vault/logs/audit.log | jq .
```

---

## Step 8 — Access the Vault UI

```bash
kubectl port-forward -n vault svc/vault 8200:8200
```

Open `http://localhost:8200` — login with the admin token from Step 3.

---

## Production Hardening

### Monitoring

Vault exposes Prometheus metrics at `/v1/sys/metrics`. The `vault-monitoring.yaml` manifest deploys:
- **PrometheusRules** — alerts for sealed nodes, high error rate, lease count, Raft leader loss
- **Grafana dashboard** — loaded automatically via ConfigMap label

```bash
kubectl apply -f phase-7-vault/vault-monitoring.yaml
```

Key alerts:

| Alert | Condition | Severity |
|-------|-----------|----------|
| VaultSealed | Any node sealed > 1min | Critical |
| VaultDown | No metrics for 2min | Critical |
| VaultRaftNoLeader | Raft leader contact > 1s | Critical |
| VaultHighErrorRate | Error rate > 5% | Warning |
| VaultLeaseCountHigh | Active leases > 10,000 | Warning |

---

### Audit Logs → Loki

`vault-init.sh` enables two audit devices:
- **File** — `/vault/logs/audit.log` (persistent, for compliance)
- **Stdout** — picked up by Promtail and shipped to Loki automatically

Query all secret reads in Grafana:
```
{namespace="vault"} | json | type="response" | path=~".*secret.*"
```

Query all failed logins:
```
{namespace="vault"} | json | type="response" | error != ""
```

---

### Raft Snapshots → GCS

Daily snapshots are taken by a CronJob and uploaded to GCS for disaster recovery.

**Provision GCS bucket (once):**
```bash
cd phase-7-vault/terraform
terraform apply -target=google_storage_bucket.vault_snapshots \
                -target=google_service_account.vault_snapshot \
                -target=google_storage_bucket_iam_member.vault_snapshot
```

**Deploy the CronJob:**
```bash
kubectl apply -f phase-7-vault/vault-snapshot-cronjob.yaml
```

**Test a snapshot manually:**
```bash
kubectl create job vault-snapshot-test \
  --from=cronjob/vault-snapshot -n vault
kubectl logs -n vault -l job-name=vault-snapshot-test -f
```

**Restore from snapshot:**
```bash
# Download latest snapshot from GCS
gsutil cp $(gsutil ls gs://platform-eng-lab-will-vault-snapshots/ | sort | tail -1) /tmp/vault.snap

# Restore (Vault must be initialised and unsealed)
vault operator raft snapshot restore /tmp/vault.snap
```

---

### TLS

By default Vault runs with TLS disabled (`tls_disable = 1`) for lab convenience. To enable TLS with cert-manager:

**1. Install cert-manager** (included in `bootstrap.sh --phase 7`):
```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --set installCRDs=true
```

**2. Create the Certificate:**
```bash
kubectl apply -f phase-7-vault/vault-tls.yaml
# Wait for certificate to be issued
kubectl get certificate -n vault vault-server-tls
```

**3. Upgrade Vault with TLS values:**
```bash
helm upgrade vault hashicorp/vault -n vault \
  -f phase-7-vault/vault-values.yaml \
  -f phase-7-vault/vault-tls-values.yaml
```

**4. Update your local env:**
```bash
export VAULT_ADDR=https://localhost:8200
export VAULT_CACERT=/path/to/ca.crt  # from vault-ca-secret
kubectl get secret vault-ca-secret -n vault \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/vault-ca.crt
export VAULT_CACERT=/tmp/vault-ca.crt
```

---

## Adding Vault Secret Injection to a New App

Every new application needs 3 things to get secrets from Vault:

### 1. Vault policy — what secrets the app can read

```bash
vault policy write my-app - <<'EOF'
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
path "database/creds/my-app" {
  capabilities = ["read"]
}
EOF
```

### 2. Kubernetes auth role — which ServiceAccount can use the policy

```bash
vault write auth/kubernetes/role/my-app \
  bound_service_account_names=my-app \
  bound_service_account_namespaces=default \
  policies=my-app \
  ttl=1h
```

### 3. Helm values — Vault annotations baked into the chart

Add a `vault` block to the app's `values.yaml`:

```yaml
vault:
  enabled: true
  role: "my-app"
  secrets:
    - name: config.env
      path: secret/data/my-app/config
      template: |
        {{- with secret "secret/data/my-app/config" -}}
        export API_KEY="{{ .Data.data.api_key }}"
        {{- end }}
    - name: db.env
      path: database/creds/my-app
      template: |
        {{- with secret "database/creds/my-app" -}}
        export DB_USERNAME="{{ .Data.username }}"
        export DB_PASSWORD="{{ .Data.password }}"
        {{- end }}
```

The chart's `deployment.yaml` reads this block and renders the Vault Agent annotations automatically. The app's `ServiceAccount` is created by the chart — its name must match the Kubernetes auth role above.

Secrets are available at `/vault/secrets/<name>` inside the pod. Source them at startup:

```bash
source /vault/secrets/config.env
source /vault/secrets/db.env
```

### Summary

| Step | Who does it | When |
|------|------------|------|
| Create policy + K8s role | Platform/ops team | Once per app |
| Add `vault:` block to values.yaml | App team | In the Helm chart |
| `helm install` | App team / ArgoCD | On every deploy |

---

## Adding Vault Secrets to a GitHub Actions Workflow

The CD pipeline authenticates to Vault using GitHub's OIDC token — no static secrets stored in GitHub.

### 1. Create a Vault policy for CI

```bash
vault policy write my-app-ci - <<'EOF'
path "secret/data/my-app/*" {
  capabilities = ["read"]
}
EOF
```

### 2. Create a JWT role bound to the repository

```bash
echo '{
  "role_type": "jwt",
  "bound_audiences": ["https://github.com/YOUR_ORG/YOUR_REPO"],
  "user_claim": "actor",
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "YOUR_ORG/YOUR_REPO",
    "ref": "refs/heads/main"
  },
  "policies": ["my-app-ci"],
  "ttl": "15m"
}' > /tmp/my-app-ci-role.json

vault write auth/jwt/github/role/my-app-ci @/tmp/my-app-ci-role.json
```

### 3. Add the vault-action step to the workflow

```yaml
jobs:
  deploy:
    permissions:
      id-token: write   # required for OIDC JWT

    steps:
      - name: Retrieve secrets from Vault
        uses: hashicorp/vault-action@v3
        with:
          url: http://vault.vault.svc.cluster.local:8200
          method: jwt
          path: jwt/github
          role: my-app-ci
          secrets: |
            secret/data/my-app/config api_key | API_KEY ;
            secret/data/my-app/config db_host | DB_HOST
```

Secrets are exposed as masked environment variables for the rest of the job — they never appear in logs and are never stored in GitHub.

### How it works

```
GitHub Actions runner
    └── OIDC JWT token (bound to repo + branch)
            └── Vault JWT auth (auth/jwt/github)
                    └── 15min scoped token
                            └── reads secrets → masked env vars
                                    └── token auto-expires, nothing to revoke
```

### Summary

| Step | Who does it | When |
|------|------------|------|
| Create policy + JWT role | Platform/ops team | Once per app |
| Add `vault-action` step to workflow | App team | In the workflow file |
| `permissions: id-token: write` | App team | Required on the job |

---

## Troubleshooting

### Vault pods not unsealing after restart

**Cause:** GCP KMS key not yet created or `vault-kms-credentials` secret missing/wrong.

**Fix:** Verify KMS setup and credentials:
```bash
terraform -chdir=phase-7-vault/terraform output
kubectl get secret vault-kms-credentials -n vault
kubectl logs -n vault vault-0 | grep -i seal
```

### `permission denied` when backend reads secret

**Cause:** ServiceAccount name or namespace mismatch with the Kubernetes role.

**Fix:**
```bash
vault read auth/kubernetes/role/coverline-backend
kubectl get serviceaccount coverline-backend -n default
```

### Vault Agent init container stuck in `Init:0/1`

**Cause:** Vault Agent can't reach the Vault service.

**Fix:**
```bash
kubectl run vault-test --rm -it --image=curlimages/curl -- \
  curl http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### GitHub Actions — `vault-action` auth fails

**Cause:** JWT role bound claims don't match the workflow's token claims.

**Fix:** Check the token claims match the role:
```bash
vault read auth/jwt/github/role/github-ci
# bound_claims should match repository and ref from the workflow
```


---

[📝 Take the Phase 7 quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-7-vault/quiz.html)
