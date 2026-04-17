# DR Recovery Runbook — CoverLine Platform

**Owner:** Platform Engineering  
**SLA:** RTO 4 hours / RPO 1 hour (contractual, enterprise client MSA)  
**Last tested:** _not yet run — complete drill as part of Phase 10c Step 6_

---

## How to Use This Runbook

1. Identify which scenario matches your incident (table below)
2. Jump to the relevant section
3. Follow steps in order — each step has a validation command
4. Record actual recovery time in the **Drill History** section at the bottom

| Scenario | Jump to |
|---|---|
| PostgreSQL table/data loss | [§1 PostgreSQL Data Loss](#1-postgresql-data-loss) |
| PostgreSQL pod crash | [§2 PostgreSQL Pod Crash](#2-postgresql-pod-crash) |
| Full namespace deleted or corrupted | [§3 Namespace Loss (Velero)](#3-namespace-loss-velero) |
| Full cluster loss | [§4 Full Cluster Loss](#4-full-cluster-loss) |
| Vault data loss | [§5 Vault Loss](#5-vault-loss) |
| Terraform state corrupted | [§6 Terraform State Corruption](#6-terraform-state-corruption) |

---

## 1. PostgreSQL Data Loss

**Trigger:** Table dropped, data corrupted, accidental DELETE/TRUNCATE  
**Target RTO:** 30 minutes | **Target RPO:** 1 hour

### Prerequisites

- GCS access: `gsutil ls gs://coverline-pg-backups-platform-eng-lab-will/`
- `kubectl` access to the `coverline` namespace

### Steps

**1.1 — Identify the latest clean backup**

```bash
gsutil ls -l gs://coverline-pg-backups-platform-eng-lab-will/ \
  | sort -k2 | tail -10
```

Note the timestamp of the last backup before the incident.

**1.2 — Download the dump**

```bash
gsutil cp gs://coverline-pg-backups-platform-eng-lab-will/<YYYY/MM/DD/HHMMSS>.dump \
  /tmp/restore.dump
```

**1.3 — Copy into the PostgreSQL pod**

```bash
kubectl cp /tmp/restore.dump coverline/coverline-postgresql-0:/tmp/restore.dump
```

**1.4 — Restore**

```bash
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  pg_restore -U postgres -d coverline --clean --if-exists /tmp/restore.dump
```

**1.5 — Validate**

```bash
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "\dt"

kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "SELECT COUNT(*) FROM claims;"
```

**1.6 — Restart application pods to reconnect**

```bash
kubectl rollout restart deployment/coverline-backend -n coverline
kubectl rollout status deployment/coverline-backend -n coverline
```

---

## 2. PostgreSQL Pod Crash

**Trigger:** Pod `coverline-postgresql-0` is crash-looping or deleted  
**Target RTO:** 5 minutes | **Target RPO:** 0 (PVC survives pod deletion)

### Steps

**2.1 — Check pod status**

```bash
kubectl get pod coverline-postgresql-0 -n coverline
kubectl describe pod coverline-postgresql-0 -n coverline
```

**2.2 — Check PVC is intact**

```bash
kubectl get pvc -n coverline
# data-coverline-postgresql-0 should be Bound
```

**2.3 — Delete and let StatefulSet recreate**

```bash
kubectl delete pod coverline-postgresql-0 -n coverline
# StatefulSet controller will recreate it automatically
kubectl rollout status statefulset/coverline-postgresql -n coverline
```

**2.4 — Validate**

```bash
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "SELECT COUNT(*) FROM claims;"
```

> No data restore needed — PVC persists independently of the pod.

---

## 3. Namespace Loss (Velero)

**Trigger:** `coverline` namespace accidentally deleted, or namespace-level corruption  
**Target RTO:** 45 minutes | **Target RPO:** 24 hours (daily Velero backup)

### Prerequisites

- Velero CLI installed: `velero version`
- Velero server running: `kubectl get pods -n velero`

### Steps

**3.1 — List available backups**

```bash
velero backup get
# Look for the most recent coverline-daily-* backup
```

**3.2 — Describe the backup to confirm it's usable**

```bash
velero backup describe coverline-daily-<TIMESTAMP> --details
# Status should be: Completed
# Phase-1-items should include coverline namespace resources
```

**3.3 — Restore**

```bash
velero restore create coverline-restore-$(date +%Y%m%d%H%M) \
  --from-backup coverline-daily-<TIMESTAMP> \
  --include-namespaces coverline \
  --wait
```

**3.4 — Validate**

```bash
kubectl get pods -n coverline
# All pods should reach Running state within 3-5 minutes

kubectl get pvc -n coverline
# All PVCs should be Bound

# Application health check
kubectl port-forward svc/coverline-frontend 3000:3000 -n coverline &
curl http://localhost:3000/health
```

**3.5 — Check data integrity**

```bash
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "SELECT COUNT(*) FROM claims;"
```

> **Note:** If Velero backup is more than 1 hour old and the RPO requirement is 1 hour, also apply the latest `pg_dump` from GCS on top of the restored database (follow §1 from step 1.1).

---

## 4. Full Cluster Loss

**Trigger:** GKE cluster deleted, zone outage, or unrecoverable cluster state  
**Target RTO:** 2–3 hours | **Target RPO:** 1 hour

### Steps

**4.1 — Reprovision the cluster (Terraform)**

```bash
cd phase-1-terraform/envs/dev
terraform init
terraform apply -var-file=dev.tfvars -auto-approve
```

Expected time: ~15 minutes.

**4.2 — Get credentials**

```bash
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will
kubectl get nodes
```

**4.3 — Bootstrap core platform components**

```bash
# From repo root
bash bootstrap.sh
```

Or manually:
```bash
# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=5m

# Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace

# Vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --namespace vault --create-namespace \
  --set server.ha.enabled=false
```

**4.4 — Restore Vault from snapshot**

```bash
# Find latest snapshot
gsutil ls -l gs://coverline-vault-snapshots-platform-eng-lab-will/ \
  | sort -k2 | tail -5

gsutil cp gs://coverline-vault-snapshots-platform-eng-lab-will/<latest>.snap \
  /tmp/vault.snap

# Wait for Vault to be running
kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=3m

# Restore snapshot
kubectl cp /tmp/vault.snap vault/vault-0:/tmp/vault.snap
kubectl exec -it vault-0 -n vault -- \
  vault operator raft snapshot restore /tmp/vault.snap
```

**4.5 — Deploy application via ArgoCD / Helm**

```bash
# Apply the ArgoCD ApplicationSet
kubectl apply -f phase-5-gitops/applicationset.yaml

# Or deploy directly
helm upgrade --install coverline phase-3-helm/coverline \
  -n coverline --create-namespace \
  -f phase-3-helm/coverline/values-dev.yaml
```

**4.6 — Restore PostgreSQL data**

Follow §1 (PostgreSQL Data Loss) from step 1.1 onwards to apply the latest `pg_dump`.

**4.7 — Validate end-to-end**

```bash
kubectl get pods -n coverline
kubectl get pods -n monitoring
kubectl get pods -n vault

kubectl port-forward svc/coverline-frontend 3000:3000 -n coverline &
curl http://localhost:3000/health
```

---

## 5. Vault Loss

**Trigger:** Vault StatefulSet or PVC lost; Vault in a sealed state that cannot be recovered  
**Target RTO:** 20 minutes | **Target RPO:** 1 hour

### Steps

**5.1 — Check Vault status**

```bash
kubectl exec -it vault-0 -n vault -- vault status
```

**5.2 — If only sealed (PVC intact) — unseal**

```bash
kubectl exec -it vault-0 -n vault -- vault operator unseal <unseal-key-1>
kubectl exec -it vault-0 -n vault -- vault operator unseal <unseal-key-2>
kubectl exec -it vault-0 -n vault -- vault operator unseal <unseal-key-3>
```

**5.3 — If PVC is lost — restore from snapshot**

```bash
# Find latest snapshot
gsutil ls -l gs://coverline-vault-snapshots-platform-eng-lab-will/ \
  | sort -k2 | tail -5

gsutil cp gs://coverline-vault-snapshots-platform-eng-lab-will/<latest>.snap /tmp/vault.snap

kubectl cp /tmp/vault.snap vault/vault-0:/tmp/vault.snap
kubectl exec -it vault-0 -n vault -- \
  vault operator raft snapshot restore /tmp/vault.snap
```

**5.4 — Validate**

```bash
kubectl exec -it vault-0 -n vault -- vault status
# Sealed: false
# HA Mode: active

# Verify secrets are accessible
kubectl exec -it vault-0 -n vault -- vault kv list secret/coverline/
```

---

## 6. Terraform State Corruption

**Trigger:** `terraform.tfstate` in GCS is corrupt or accidentally deleted  
**Target RTO:** 10 minutes | **Target RPO:** 0 (GCS versioning)

### Steps

**6.1 — List available versions**

```bash
gsutil ls -a gs://platform-eng-lab-will-tfstate/phase-1/dev/
# -a flag shows all versions including non-current
```

**6.2 — Restore the previous version**

```bash
# Get the generation ID of the last good version
gsutil ls -la gs://platform-eng-lab-will-tfstate/phase-1/dev/terraform.tfstate \
  | tail -5

# Restore by copying a specific generation
gsutil cp \
  gs://platform-eng-lab-will-tfstate/phase-1/dev/terraform.tfstate#<GENERATION_ID> \
  gs://platform-eng-lab-will-tfstate/phase-1/dev/terraform.tfstate
```

**6.3 — Validate**

```bash
cd phase-1-terraform/envs/dev
terraform init
terraform plan -var-file=dev.tfvars
# Should show no changes if state matches real infrastructure
```

---

## Drill History

Record every DR drill here.

| Date | Scenario | Actual RTO | Target RTO | Pass/Fail | Notes |
|---|---|---|---|---|---|
| _Not yet run_ | | | | | |

---

## Contacts

| Role | Contact |
|---|---|
| Platform on-call | See PagerDuty rotation |
| GCP Project Owner | `platform-eng-lab-will` project |
| Vault unseal keys | Stored in 1Password — "CoverLine Vault Unseal Keys" |
