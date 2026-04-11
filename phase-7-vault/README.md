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

- HashiCorp Vault on a **dedicated Compute Engine VM** (outside GKE — avoids circular dependency)
- Provisioned with **Terraform** (VM, firewall, KMS), configured with **Ansible** (binary, systemd, vault.hcl)
- **GCP KMS Auto Unseal** — Vault unseals itself on restart, no manual key required
- KV v2 secrets engine for static secrets (Redis host, app config)
- **Dynamic PostgreSQL credentials** — Vault generates short-lived unique credentials per pod
- Kubernetes auth — pods authenticate using their ServiceAccount JWT
- **Vault Agent Injector** deployed in K8s (webhook only — points to the external VM)
- Secrets mounted as files and sourced at pod startup — never in manifests or env vars
- **Audit logging** — every secret read logged with timestamp and client identity
- **Root token revoked** — replaced by a scoped admin token after setup
- **GitHub Actions JWT auth** — CI retrieves secrets from Vault via OIDC, zero static secrets in GitHub

## Architecture

```
GCP Project
├── GKE Cluster
│   ├── coverline-backend pod
│   │       ├── init container: vault-agent
│   │       │       └── ServiceAccount JWT → Vault K8s auth → scoped token
│   │       │               ├── reads static config  → /vault/secrets/backend.env
│   │       │               └── reads dynamic creds  → /vault/secrets/db.env (rotates 1h)
│   │       └── app container
│   │               └── source /vault/secrets/*.env → starts with secrets as env vars
│   │
│   └── vault-agent-injector (webhook — no Vault server in K8s)
│           └── intercepts pod creation → injects vault-agent sidecar
│
├── Compute Engine VM  ← Vault server lives here, outside GKE
│       └── vault server (systemd)
│               ├── Raft storage (local disk)
│               └── GCP KMS auto-unseal
│
└── GitHub Actions CD pipeline
        └── OIDC JWT token → Vault JWT auth (jwt/github)
                └── reads secret/data/coverline/backend → masked env vars
```

> **Why outside GKE?** If Kubernetes is restarting, pods can't start without Vault — but Vault itself is a pod. Running Vault on a VM breaks this circular dependency. Vault is always reachable, even during a cluster incident.

## Screenshots

### Vault UI — Secrets Engine
![Vault Secrets](screenshots/vault-secrets.png)

### Vault UI — Kubernetes Auth Role
![Vault Auth](screenshots/vault-auth.png)

### Pod — Injected Secret File
![Secret Injected](screenshots/secret-injected.png)

---

## Step 1 — Provision Infrastructure (Terraform)

This step creates the KMS key for auto-unseal, the Vault service account, and the Compute Engine VM.

```bash
cd phase-7-vault/terraform
terraform init
terraform plan
terraform apply
```

This creates:
- KMS key ring `vault-keyring` + crypto key `vault-unseal-key`
- GCP service account `vault-server` with KMS encrypt/decrypt permissions
- `e2-medium` Compute Engine VM (`vault-server`) in `us-central1-b`
- Firewall rules: port 8200 from GKE subnet, SSH via IAP only

Capture the VM IP for the next steps:
```bash
export VAULT_IP=$(terraform output -raw vault_internal_ip)
export VAULT_ADDR=$(terraform output -raw vault_addr)
echo "Vault VM: $VAULT_IP"
echo "Vault address: $VAULT_ADDR"
```

---

## Step 2 — Install Vault on the VM (Ansible)

Install Ansible if not already installed:
```bash
pip3 install ansible
```

Run the install playbook — it installs the Vault binary, writes `vault.hcl`, and starts the systemd service:
```bash
ansible-playbook \
  -i phase-7-vault/ansible/inventory/hosts.yml \
  phase-7-vault/ansible/playbooks/vault-install.yml
```

The playbook connects via IAP tunnel (no public IP required). It is idempotent — safe to re-run.

Verify Vault is running:
```bash
curl http://$VAULT_IP:8200/v1/sys/health
```

Expected response: `{"initialized":false,"sealed":true,...}` — not yet initialized, which is correct.

---

## Step 3 — Deploy Vault Agent Injector to K8s

The Vault **server** runs on the VM. The Vault **Agent Injector** (a Kubernetes webhook) still runs in GKE — it intercepts pod creation and injects the vault-agent sidecar that fetches secrets from the VM.

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault

helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f phase-7-vault/vault-agent-injector-values.yaml \
  --set injector.externalVaultAddr=http://${VAULT_IP}:8200
```

Verify the injector is running (no vault-0/1/2 pods — only the injector):
```bash
kubectl get pods -n vault
```

Expected:
```
NAME                                    READY   STATUS
vault-agent-injector-xxx-yyy            1/1     Running
vault-agent-injector-xxx-zzz            1/1     Running
```

---

## Step 4 — Initialize Vault

```bash
export VAULT_ADDR=http://${VAULT_IP}:8200
bash phase-7-vault/vault-init.sh
```

This script:
1. Initializes Vault (outputs recovery key + root token)
2. Enables KV v2 secrets engine
3. Writes CoverLine static secrets
4. Enables Kubernetes auth (pointing at the GKE cluster)
5. Enables GitHub Actions JWT auth
6. Enables audit logging
7. Creates a scoped admin token (8h TTL)
8. **Revokes the root token**

**Save the recovery key immediately:**
```bash
echo -n "<RECOVERY_KEY>" | gcloud secrets create vault-recovery-key \
  --data-file=- --project=platform-eng-lab-will
```

---

## Step 5 — Create Policies and Auth Roles

```bash
export VAULT_ADDR=http://${VAULT_IP}:8200
export VAULT_TOKEN="<ADMIN_TOKEN_FROM_STEP_4>"

bash phase-7-vault/vault-policy.sh
```

This creates:
- Policy `coverline-backend` — read static secrets + generate dynamic DB credentials
- Kubernetes role `coverline-backend` — binds the pod ServiceAccount to the policy
- Policy `github-ci` — read secrets + generate readonly DB credentials for tests
- JWT role `github-ci` — bound to `wb-platform-engineering-lab/platform-engineering-lab-gke`, branch `main`, TTL 15min

---

## Step 6 — Configure Dynamic PostgreSQL Credentials

```bash
export VAULT_ADDR=http://${VAULT_IP}:8200
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
password           A1a-xyz789...   ← unique, expires in 1h, auto-revoked in PostgreSQL
username           v-k8s-coverli-xyz
```

---

## Step 7 — Verify Secret Injection in Backend Pods

Restart the backend to trigger vault-agent injection:
```bash
kubectl rollout restart deployment/coverline-backend
kubectl rollout status deployment/coverline-backend
```

Verify secrets were injected:
```bash
# Static secrets (Redis, DB config)
kubectl exec deploy/coverline-backend -c backend -- cat /vault/secrets/backend.env

# Dynamic DB credentials (unique per pod, rotates every 1h)
kubectl exec deploy/coverline-backend -c backend -- cat /vault/secrets/db.env
```

Verify the endpoint works end-to-end:
```bash
kubectl port-forward svc/coverline-backend 5000:5000 &
curl http://localhost:5000/claims
```

---

## Step 8 — Verify GitHub Actions JWT Auth

The CD pipeline (`cd.yml`) authenticates to Vault using OIDC JWT — no static secrets in GitHub.

On the next push to `main`, the workflow:
1. Exchanges its GitHub OIDC token for a Vault token (TTL: 15min)
2. Reads `secret/data/coverline/backend` — values exposed as masked env vars
3. Vault token expires automatically — no cleanup needed

Check the audit log on the VM to confirm:
```bash
gcloud compute ssh vault-server --zone=us-central1-b \
  --tunnel-through-iap -- sudo journalctl -u vault -f
```

---

## Step 9 — Access the Vault UI

Open an IAP tunnel to the VM:
```bash
gcloud compute start-iap-tunnel vault-server 8200 \
  --local-host-port=localhost:8200 \
  --zone=us-central1-b \
  --project=platform-eng-lab-will
```

Open `http://localhost:8200` — login with the admin token from Step 4.

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

### Audit Logs

`vault-init.sh` enables a file audit device on the VM at `/var/log/vault/vault.log`.

View logs directly on the VM:
```bash
gcloud compute ssh vault-server --zone=us-central1-b --tunnel-through-iap \
  -- sudo tail -f /var/log/vault/vault.log | jq .
```

To ship logs to Loki (via Promtail on the VM), install and configure Promtail as a systemd service on the Vault VM pointing at your Loki endpoint. Query in Grafana:
```
{host="vault-server"} | json | type="response" | path=~".*secret.*"
```

Query all failed logins:
```
{host="vault-server"} | json | type="response" | error != ""
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

## Production Best Practices

What companies like Stripe, Cloudflare, and GitHub actually do — and how it differs from this lab.

---

### 1. Run Vault Outside Kubernetes (Most Important)

This is the most critical gap between this lab and production. **Stripe, Cloudflare, GitHub, and HashiCorp itself run Vault on dedicated VMs completely outside Kubernetes.**

The reason is a circular dependency: if Kubernetes is in crisis, you can't start Vault (which runs as a pod) to get secrets to recover Kubernetes pods. Vault must be reachable even when the cluster is down.

```
This lab:                       Production reality:
──────────────────────          ──────────────────────────────────────
GKE cluster                     GKE cluster       Vault cluster (VMs)
  ├── vault-0 pod                  ├── app pods ←── 5–7 nodes, 3 zones
  ├── vault-1 pod                  ├── infra pods   dedicated VMs
  └── app pods                     └── ...          always reachable
        ↑ circular dependency             ↑ independent lifecycle
```

**Options in order of preference for production:**

| Option | Used by | Operational cost |
|--------|---------|-----------------|
| Dedicated VMs outside K8s (5–7 nodes, 3 zones) | Stripe, GitHub | High |
| **HCP Vault** (HashiCorp managed) | Mid-size companies | Zero |
| Dedicated node pool in K8s with fixed size | Startups | Medium |

For this lab, a dedicated node pool is the pragmatic choice. For a real production system at CoverLine's scale, dedicated VMs or HCP Vault is the standard.

**Dedicated node pool (minimum viable isolation):**

```hcl
# Terraform — fixed-size node pool, never autoscaled
node_pool {
  name = "vault-pool"
  node_config {
    machine_type = "e2-standard-2"
    taint {
      key    = "workload"
      value  = "vault"
      effect = "NO_SCHEDULE"
    }
  }
  initial_node_count = 3
  autoscaling { min_node_count = 3; max_node_count = 3 }
}
```

```yaml
# vault-values.yaml — schedule only on the vault pool
server:
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "vault"
      effect: "NoSchedule"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: workload
                operator: In
                values: ["vault"]
```

---

### 2. Recovery Key: Shamir's Secret Sharing + Physical Backup

GCP Secret Manager alone is not sufficient. What major companies actually do:

- **Shamir's Secret Sharing** — split the key across 5 keyholders, require 3 to reconstruct. Built into Vault's `operator init`:
  ```bash
  vault operator init -recovery-shares=5 -recovery-threshold=3
  ```
- **Multiple storage locations** — GCP Secret Manager + encrypted USB in a physical safe + a printed copy held by the CISO
- **No single person can unseal Vault alone** — this is a security requirement, not just a best practice
- **Quarterly recovery drills** — actually test key reconstruction with the keyholders

The GCP Secret Manager approach in this lab is a starting point, not the end state.

---

### 3. Use HSM for Auto-Unseal, Not KMS (High Security)

This lab uses GCP KMS for auto-unseal. Large companies in regulated industries (finance, healthcare) use **Hardware Security Modules (HSMs)**:

- HSMs are tamper-resistant physical devices — the key material never leaves the hardware
- GCP KMS is software-based — the key material is protected by Google's infrastructure, not a physical device
- For ISO 27001, SOC 2 Type II, and PCI-DSS compliance, HSMs are often required

For most companies, GCP KMS is sufficient. For banks, insurers (like CoverLine at scale), and healthcare platforms, an HSM-backed unseal is expected.

---

### 4. Never Use Long-Lived Tokens for Automation

The 8h admin token in this lab is a lab convenience. In production:

- **Never use the root token** after initial setup — not in scripts, not in CI/CD, not stored anywhere
- **AppRole** for machine-to-machine auth (CI/CD pipelines, scripts): short-lived tokens with tight policies
- **Kubernetes auth** for pods: already used in this lab — the right approach
- **GitHub OIDC** for CI/CD: already used in this lab — the right approach
- Admin access should require a human to authenticate interactively, not via a stored token

```bash
# What NOT to do — long-lived token stored in Secret Manager
vault token create -policy=vault-admin -period=720h  # ❌

# What to do — require human MFA for admin operations
vault login -method=userpass username=admin  # ✅ or LDAP/OIDC
```

---

### 5. Source Vault Secret Files in the App Startup Command

Vault Agent injects secrets as files (`/vault/secrets/*.env`). The app must source them before starting. This must be baked into the Helm chart — not applied as a manual patch:

```yaml
# deployment.yaml in your Helm chart
containers:
  - name: backend
    command:
      - /bin/sh
      - -c
      - source /vault/secrets/backend.env && source /vault/secrets/db.env && python app.py
```

If missing, the app starts before secrets are available and fails with `KeyError`.

---

### 6. Separate Vault Clusters Per Environment

Large companies run completely separate Vault clusters for dev, staging, and production — not namespaces or paths within one cluster:

```
vault-dev.internal     → dev/staging secrets, loose policies
vault-prod.internal    → production only, strict policies, HSM-backed, audited
```

This prevents a misconfigured dev policy from ever touching production secrets, and limits blast radius if a dev token is compromised.

---

### 7. Never Call the Vault API Directly From App Code

Do not have app code call the Vault HTTP API. Use the Vault Agent sidecar exclusively:

- The Agent handles token renewal, secret rotation, and retry logic
- The app reads a file — it never holds a Vault token
- If Vault is unreachable, the Agent retries without crashing the app

Direct API calls from app code create tight coupling and require every developer to understand Vault's token lifecycle.

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

### Vault VM not unsealing after restart

**Cause:** GCP KMS key not yet created, or the VM service account doesn't have KMS permissions.

**Fix:** Verify KMS setup and check Vault logs on the VM:
```bash
terraform -chdir=phase-7-vault/terraform output
gcloud compute ssh vault-server --zone=us-central1-b --tunnel-through-iap \
  -- sudo journalctl -u vault --no-pager | grep -i "seal\|kms\|error"
```

### `permission denied` when backend reads secret

**Cause:** ServiceAccount name or namespace mismatch with the Kubernetes role.

**Fix:**
```bash
export VAULT_ADDR=http://${VAULT_IP}:8200
vault read auth/kubernetes/role/coverline-backend
kubectl get serviceaccount coverline-backend -n default
```

### Backend pod gets `KeyError: 'REDIS_HOST'` even though vault-agent is running

**Cause:** Vault Agent writes secrets to files (`/vault/secrets/backend.env`) but the app reads `os.environ`. The files must be sourced at container startup.

**Fix:** Bake the source command into the Helm chart's container command:
```yaml
command: ["/bin/sh", "-c", "source /vault/secrets/backend.env && source /vault/secrets/db.env && python app.py"]
```

Verify the file contains expected values:
```bash
kubectl exec deployment/coverline-backend -c backend -- cat /vault/secrets/backend.env
```

If `REDIS_HOST` shows `<no value>`, the secret key name in Vault doesn't match the template. Check:
```bash
vault kv get secret/coverline/backend
```

### Lost admin token / recovery key

**Cause:** Admin token expired (8h TTL) and recovery key was not saved.

**Recovery options:**
1. If recovery key was saved to GCP Secret Manager: `gcloud secrets versions access latest --secret=vault-recovery-key --project=<PROJECT>`
2. Then generate a new root token: `vault operator generate-root` using the recovery key
3. If recovery key is lost — wipe Vault (delete Helm release + all PVCs) and re-run `vault-init.sh`

**Prevention:** Always save the recovery key immediately after `vault-init.sh`:
```bash
echo -n "<RECOVERY_KEY>" | gcloud secrets create vault-recovery-key \
  --data-file=- --project=platform-eng-lab-will
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
