# Phase 3 — Secrets Management (Vault)

> **Vault concepts introduced:** KV v2, Dynamic credentials, Kubernetes auth, Vault Agent Injector, JWT auth, GCP KMS auto-unseal | **Builds on:** Phase 2 Kubernetes cluster

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-3-vault/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **KV v2 secrets engine** | Versioned key-value store for static secrets | Replaces hardcoded values in manifests and Git history |
| **Dynamic credentials** | Vault generates short-lived unique DB credentials per pod | No shared password — each pod gets its own username that expires in 1h |
| **Kubernetes auth** | Pods authenticate to Vault using their ServiceAccount JWT | No token or password stored in the pod — the identity comes from Kubernetes itself |
| **Vault Agent Injector** | Kubernetes webhook that injects a vault-agent sidecar at pod creation | App code never calls Vault — it reads a file |
| **JWT auth (GitHub)** | CI authenticates to Vault using GitHub's OIDC token | Zero static secrets in GitHub Actions — no stored `VAULT_TOKEN` |
| **GCP KMS auto-unseal** | Vault unseals itself on restart using a GCP KMS key | No manual key ceremony required after a VM reboot |

---

## The problem

> *CoverLine — 1,000 members. January.*
>
> CoverLine was preparing for its Series B. As part of due diligence, the investors hired an external security firm to audit the codebase. The audit took three days. The report took one paragraph to deliver its most critical finding:
>
> *"Database credentials for the production PostgreSQL instance were found committed in plaintext in the application's Git history. The credentials appear in 14 commits across 3 branches, including the public-facing repository. These credentials have not been rotated in 11 months."*
>
> The CISO read the report at 8 AM. By 9 AM, the credentials were rotated. By 10 AM, three engineers were in a war room. The database password had been in the repo since the first sprint. Every contractor, every open-source contributor, every person who had ever cloned the repo had it.
>
> The Series B was delayed by six weeks pending a full security remediation.
>
> *"We didn't have a secrets problem. We had a culture problem. Secrets need to be impossible to commit, not just discouraged."*

The decision: HashiCorp Vault. Credentials never touch the filesystem. Pods get short-lived dynamic credentials that rotate automatically. Git contains no secrets — not even accidentally.

---

## Architecture

```
GCP Project
│
├── Compute Engine VM  ← Vault server lives here, OUTSIDE GKE
│       └── vault server (systemd, Raft storage)
│               └── GCP KMS auto-unseal
│
├── GKE Cluster
│   ├── vault-agent-injector  (webhook — no Vault server in K8s)
│   │       └── intercepts pod creation → injects vault-agent init container
│   │
│   └── coverline-backend pod
│           ├── init container: vault-agent
│           │       └── ServiceAccount JWT → Vault K8s auth → scoped token
│           │               ├── reads KV secret  → /vault/secrets/backend.env
│           │               └── reads dynamic DB  → /vault/secrets/db.env (1h TTL)
│           └── app container
│                   └── source /vault/secrets/*.env → starts with secrets as env vars
│
└── GitHub Actions CD pipeline
        └── GitHub OIDC token → Vault JWT auth → 15min scoped token
                └── reads secrets → masked env vars → token auto-expires
```

> **Why outside GKE?** If Kubernetes is in crisis, pods can't start without Vault — but if Vault itself runs as a pod, it can't start either. A VM breaks this circular dependency. Vault is always reachable, even during a cluster incident.

---

## Repository structure

```
phase-3-vault/
├── terraform/
│   ├── vm.tf           ← e2-medium VM, firewall rules, service account
│   ├── kms.tf          ← KMS keyring + crypto key for auto-unseal
│   └── snapshots.tf    ← GCS bucket + SA for Raft snapshot CronJob
├── ansible/
│   ├── playbooks/
│   │   └── vault-install.yml      ← installs binary, writes config, starts systemd
│   ├── templates/
│   │   ├── vault.hcl.j2           ← Vault config (listener, storage, seal)
│   │   └── vault.service.j2       ← systemd unit file
│   └── inventory/
│       └── hosts.yml              ← VM address via IAP tunnel
├── vault-init.sh                  ← initializes Vault, enables engines, revokes root token
├── vault-policy.sh                ← creates policies + K8s and JWT auth roles
├── vault-dynamic-secrets.sh       ← configures PostgreSQL dynamic credentials
├── vault-agent-injector-values.yaml ← Helm values (injector only, points to VM)
├── vault-monitoring.yaml          ← PrometheusRules + Grafana dashboard
└── vault-snapshot-cronjob.yaml    ← daily Raft snapshots to GCS
```

---

## Prerequisites

- Phase 2 Kubernetes setup complete (`kubectl` configured, nginx Ingress installed)
- Phase 4 PostgreSQL deployed (`helm install postgresql ...`) *(required for dynamic DB credentials — complete Phase 4 first)*
- Phase 7 Prometheus running in the `monitoring` namespace *(required for vault-monitoring — complete Phase 7 first)*
- Terraform and Ansible installed locally:

```bash
terraform -version   # >= 1.7
ansible --version    # >= 2.14
pip3 install ansible
```

---

## Architecture Decision Records

- `docs/decisions/adr-027-vault-on-vm-not-k8s.md` — Why Vault runs on a Compute Engine VM outside GKE rather than as a pod
- `docs/decisions/adr-028-dynamic-over-static-db-creds.md` — Why dynamic PostgreSQL credentials over a shared static password
- `docs/decisions/adr-029-agent-injector-over-csi.md` — Why Vault Agent Injector over the Secrets Store CSI Driver for secret delivery
- `docs/decisions/adr-030-kms-auto-unseal.md` — Why GCP KMS auto-unseal over manual Shamir key ceremony for a lab environment

---

## Challenge 1 — Provision the Vault infrastructure (Terraform)

This creates the GCP KMS key for auto-unseal and the Compute Engine VM that will run Vault.

### Step 1: Apply the Terraform module

```bash
cd phase-3-vault/terraform
terraform init
terraform plan
terraform apply
```

Resources created:
- KMS keyring `vault-keyring` + crypto key `vault-unseal-key`
- Service account `vault-server` with KMS encrypt/decrypt permissions
- `e2-medium` VM in `us-central1-b` on the project VPC (`pd-standard` disk)
- Firewall rule: port 8200 from GKE subnet, SSH + 8200 via IAP only

### Step 2: Capture the VM address

```bash
export VAULT_IP=$(terraform output -raw vault_internal_ip)
export VAULT_ADDR=$(terraform output -raw vault_addr)
echo "Vault VM: $VAULT_IP — Address: $VAULT_ADDR"
```

> The VM has no public IP. All access is via IAP tunnel or from within the VPC.

---

## Challenge 2 — Install Vault on the VM (Ansible)

### Step 1: Upload your SSH public key to OS Login (once)

```bash
gcloud compute os-login ssh-keys add \
  --key-file=/Users/will/.ssh/vault.pub \
  --project=platform-eng-lab-will

export ANSIBLE_USER=$(gcloud compute os-login describe-profile \
  --format='value(posixAccounts[0].username)')
```

### Step 2: Run the install playbook

```bash
ansible-playbook \
  -i phase-3-vault/ansible/inventory/hosts.yml \
  phase-3-vault/ansible/playbooks/vault-install.yml \
  -e "ansible_user=$ANSIBLE_USER" \
  --private-key=/Users/will/.ssh/vault
```

The playbook connects via IAP tunnel (no public IP required). It installs the Vault binary, writes `vault.hcl` from a Jinja2 template, creates the systemd unit, and starts the service. It is idempotent — safe to re-run.

### Step 3: Verify Vault is running

```bash
gcloud compute ssh vault-server \
  --zone=us-central1-b \
  --project=platform-eng-lab-will \
  --tunnel-through-iap \
  -- "curl -s http://localhost:8200/v1/sys/health"
```

Expected: `{"initialized":false,"sealed":true,...}` — not yet initialized. This is correct.

---

## Challenge 3 — Deploy the Vault Agent Injector to GKE

The Vault **server** runs on the VM. The Vault **Agent Injector** runs in GKE as a Kubernetes webhook — it intercepts pod creation and injects the vault-agent sidecar that fetches secrets from the VM.

### Step 1: Add the HashiCorp Helm repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault
```

### Step 2: Install the injector (pointing at the VM)

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f phase-3-vault/vault-agent-injector-values.yaml \
  --set injector.externalVaultAddr=http://${VAULT_IP}:8200
```

### Step 3: Verify only the injector is running (no vault server pod)

```bash
kubectl get pods -n vault
```

Expected:
```
NAME                             READY   STATUS
vault-agent-injector-xxx         1/1     Running
vault-agent-injector-yyy         1/1     Running
```

No `vault-0` pod — the server is on the VM, not in the cluster.

---

## Challenge 4 — Initialize Vault

Vault must be initialized once. This generates the recovery key and enables auto-unseal via KMS.

### Step 1: Open an IAP tunnel to the VM

In a **separate terminal**, start the tunnel and leave it running:

```bash
gcloud compute start-iap-tunnel vault-server 8200 \
  --local-host-port=localhost:8200 \
  --zone=us-central1-b \
  --project=platform-eng-lab-will
```

### Step 2: Run the init script

```bash
export VAULT_ADDR=http://localhost:8200
bash phase-3-vault/vault-init.sh
```

The script:
1. Initializes Vault → outputs recovery key and root token
2. Enables KV v2 secrets engine at `secret/`
3. Writes CoverLine static secrets (DB host, DB name, Redis host)
4. Enables Kubernetes auth (pointing at the GKE cluster API)
5. Enables GitHub Actions JWT auth at `auth/jwt/github`
6. Enables audit logging to file and stdout
7. Creates a scoped admin token (8h TTL)
8. **Revokes the root token**

### Step 3: Save the recovery key immediately

```bash
echo -n "<RECOVERY_KEY>" | gcloud secrets create vault-recovery-key \
  --data-file=- --project=platform-eng-lab-will
```

> If the recovery key is lost and the admin token expires, Vault cannot be recovered without wiping and re-initializing. Save it now.

---

## Challenge 5 — Create policies and auth roles

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN="<ADMIN_TOKEN_FROM_STEP_4>"

bash phase-3-vault/vault-policy.sh
```

This creates:

| Resource | What it does |
|---|---|
| Policy `coverline-backend` | Read static KV secrets + generate dynamic DB credentials |
| Kubernetes role `coverline-backend` | Binds the pod ServiceAccount to the policy (TTL: 1h) |
| Policy `github-ci` | Read secrets + generate read-only DB credentials for tests |
| JWT role `github-ci` | Bound to this repo + `main` branch, TTL: 15min |

### Verify the Kubernetes role

```bash
vault read auth/kubernetes/role/coverline-backend
```

---

## Challenge 6 — Configure dynamic PostgreSQL credentials

Vault generates a unique username and password per request, valid for 1 hour. When the lease expires, Vault revokes the credentials in PostgreSQL automatically.

### Step 1: Expose PostgreSQL via NodePort (Vault VM cannot resolve K8s DNS)

```bash
kubectl expose service postgresql \
  --name=postgresql-nodeport \
  --type=NodePort \
  --port=5432

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc postgresql-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
echo "PostgreSQL reachable at $NODE_IP:$NODE_PORT"
```

### Step 2: Configure the database secrets engine

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN="<ADMIN_TOKEN>"

PG_ADMIN_PASSWORD=$(kubectl get secret postgresql \
  -o jsonpath='{.data.postgres-password}' | base64 --decode)

PG_HOST=$NODE_IP PG_PORT=$NODE_PORT \
  PG_ADMIN_PASSWORD="$PG_ADMIN_PASSWORD" \
  bash phase-3-vault/vault-dynamic-secrets.sh
```

### Step 3: Test — generate a credential on demand

```bash
vault read database/creds/coverline-backend
```

Expected:
```
Key                Value
lease_id           database/creds/coverline-backend/abc123
lease_duration     1h
lease_renewable    true
username           v-k8s-coverli-xyz
password           A1a-xyz789...
```

Every call returns different credentials. Each username exists in PostgreSQL only for the duration of the lease.

---

## Challenge 7 — Verify secret injection in backend pods

### Step 1: Restart the backend to trigger vault-agent injection

```bash
kubectl rollout restart deployment/coverline-backend
kubectl rollout status deployment/coverline-backend
```

The Vault Agent Injector intercepts the pod creation and adds an init container. The init container authenticates to Vault using the pod's ServiceAccount JWT and writes secrets to `/vault/secrets/`.

### Step 2: Verify the injected secret files

```bash
# Static config (DB host, DB name, Redis host)
kubectl exec deploy/coverline-backend -c backend \
  -- cat /vault/secrets/backend.env

# Dynamic DB credentials (unique per pod, expires 1h)
kubectl exec deploy/coverline-backend -c backend \
  -- cat /vault/secrets/db.env
```

### Step 3: Verify the app is reading from Vault

```bash
kubectl port-forward svc/coverline-backend 5000:5000 &
curl http://localhost:5000/health
curl http://localhost:5000/claims
```

If `/claims` returns data, the backend is successfully connecting to PostgreSQL using Vault-issued dynamic credentials.

---

## Challenge 8 — Verify GitHub Actions JWT auth

The CD pipeline authenticates to Vault using GitHub's OIDC token — no stored `VAULT_TOKEN` in GitHub secrets.

### Step 1: Trigger a CD pipeline run

Push any change to `phase-4-helm/app/` on `main`. In the workflow run, the `Authenticate to Vault` step exchanges the GitHub OIDC token for a 15-minute Vault token and reads secrets as masked environment variables.

### Step 2: Verify in the Vault audit log

```bash
gcloud compute ssh vault-server \
  --zone=us-central1-b \
  --tunnel-through-iap \
  -- "sudo tail -50 /var/log/vault/vault.log | jq 'select(.auth.display_name | test(\"github\"))'"
```

Each CD run creates a new audit entry with the GitHub actor, repository, and branch — a complete access log.

---

## Challenge 9 — Enable Vault monitoring and snapshots

### Step 1: Apply PrometheusRules and Grafana dashboard

```bash
kubectl apply -f phase-3-vault/vault-monitoring.yaml
```

Key alerts:

| Alert | Condition | Severity |
|---|---|---|
| `VaultSealed` | Any node sealed > 1min | Critical |
| `VaultDown` | No metrics for 2min | Critical |
| `VaultHighErrorRate` | Error rate > 5% | Warning |
| `VaultLeaseCountHigh` | Active leases > 10,000 | Warning |

### Step 2: Deploy the daily snapshot CronJob

```bash
kubectl apply -f phase-3-vault/vault-snapshot-cronjob.yaml
```

### Step 3: Test a manual snapshot

```bash
kubectl create job vault-snapshot-test \
  --from=cronjob/vault-snapshot -n vault
kubectl logs -n vault -l job-name=vault-snapshot-test -f
```

Expected: snapshot uploaded to `gs://platform-eng-lab-will-vault-snapshots/`.

---

## Teardown

```bash
helm uninstall vault -n vault
kubectl delete namespace vault

cd phase-3-vault/terraform
terraform destroy
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| e2-medium Vault VM | ~$0.67 |
| GCP KMS key operations | ~$0.01 |
| GCS snapshot bucket | ~$0.01 |
| **Phase 3 additional cost** | **~$0.69/day** |

> The Vault VM is the first recurring GCP cost added since Phase 1. Destroy it when not in use: `terraform destroy -target=google_compute_instance.vault_server`.

---

## Vault concept: static vs. dynamic secrets

A static secret is a password that never changes — created once, shared everywhere, valid forever. A static password in Git is a problem. A static password rotated every 90 days is a smaller problem. A static password that five pods share is five breach opportunities.

Dynamic secrets eliminate the category entirely. Vault generates a unique credential for each request:

```
Pod starts → vault-agent requests /database/creds/coverline-backend
    └── Vault creates PostgreSQL user v-k8s-coverli-xyz with TTL 1h
            └── Pod uses the credential
                    └── 1h later: Vault revokes it → user deleted in PostgreSQL
```

If a credential leaks, it is valid for at most 1 hour. There is no shared password to rotate. If a pod is compromised, only that pod's credential is at risk — not every other pod's.

---

## Reference: adding Vault to a new application

Every new application needs three things:

**1. A Vault policy** — what the app can read:
```bash
vault policy write my-app - <<'EOF'
path "secret/data/my-app/*" { capabilities = ["read"] }
path "database/creds/my-app" { capabilities = ["read"] }
EOF
```

**2. A Kubernetes auth role** — which ServiceAccount maps to the policy:
```bash
vault write auth/kubernetes/role/my-app \
  bound_service_account_names=my-app \
  bound_service_account_namespaces=default \
  policies=my-app \
  ttl=1h
```

**3. Vault annotations in the Helm chart's `values.yaml`**:
```yaml
vault:
  enabled: true
  role: "my-app"
  secrets:
    - name: backend.env
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

Source the files at container startup in the Helm chart:
```yaml
command: ["/bin/sh", "-c", "source /vault/secrets/backend.env && source /vault/secrets/db.env && python app.py"]
```

---

## Production considerations

### 1. Run Vault on dedicated VMs, not in Kubernetes
The most critical gap between this lab and production. Stripe, Cloudflare, and GitHub run Vault on dedicated VMs completely outside Kubernetes. If the cluster is in crisis, Vault must still be reachable. For a managed alternative, HCP Vault eliminates the operational burden entirely.

### 2. Use Shamir's Secret Sharing for the recovery key
GCP Secret Manager alone is not sufficient. Split the recovery key across 5 keyholders, require 3 to reconstruct (`-recovery-shares=5 -recovery-threshold=3`). Store copies in Secret Manager + encrypted USB + a printed copy held by the CISO. No single person should be able to unseal Vault alone.

### 3. Replace the 8h admin token with interactive auth
The admin token in this lab is a lab convenience. In production, admin access requires a human to authenticate interactively (LDAP, OIDC, or userpass with MFA) — not via a stored token.

### 4. Separate Vault clusters per environment
Run completely separate Vault clusters for dev/staging and production — not separate paths within one cluster. A misconfigured dev policy can never touch production secrets.

### 5. Use HSM for auto-unseal in regulated environments
GCP KMS is software-based. For ISO 27001, SOC 2 Type II, or PCI-DSS compliance, an HSM-backed unseal is often required — the key material never leaves a tamper-resistant physical device.

### 6. Never call the Vault API directly from app code
Always use the Vault Agent sidecar. The agent handles token renewal, secret rotation, and retry logic. The app reads a file — it never holds a Vault token. Direct API calls from app code create tight coupling and require every developer to understand Vault's token lifecycle.

---

## Outcome

Database credentials no longer exist in Git, environment variables, or pod manifests. Each backend pod gets a unique PostgreSQL username that expires in 1 hour and is automatically revoked. The CI pipeline reads secrets without storing any Vault token in GitHub. The entire secret lifecycle — issuance, rotation, revocation, and audit — is managed by Vault.

---

[Back to main README](../README.md) | [Next: Phase 4 — Helm & Microservices](../phase-4-helm/README.md)
