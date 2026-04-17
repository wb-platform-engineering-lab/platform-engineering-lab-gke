# Phase 10c — Backup & Disaster Recovery

## Business Context

> **CoverLine — 1,000,000 covered members, enterprise SLA**
>
> A major corporate client — a 12,000-employee company — signs a master services agreement with a contractual **RTO of 4 hours** and **RPO of 1 hour** for claims data. Legal flags that CoverLine has no tested DR plan. The engineering team has backups in theory but has never restored from them. A tabletop exercise reveals that a full cluster loss would take 2–3 days to recover from manually.
>
> **Goal:** Implement and test a DR strategy that meets the contractual SLA.

---

## Objective

Design, implement, and test a backup and disaster recovery strategy for all stateful components of the CoverLine platform:

- PostgreSQL (claims database)
- Kubernetes workloads and PVCs (via Velero)
- Vault secrets engine
- Terraform state (GCS versioning — already in place)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    GKE Cluster (coverline)                   │
│                                                              │
│  ┌─────────────┐   ┌──────────────────┐   ┌─────────────┐  │
│  │  PostgreSQL  │   │   coverline NS    │   │    Vault    │  │
│  │  (StatefulS) │   │  (all workloads)  │   │ (StatefulS) │  │
│  └──────┬──────┘   └────────┬─────────┘   └──────┬──────┘  │
│         │                   │                      │         │
│  CronJob│pg_dump        Velero│Schedule       CronJob│raft   │
└─────────┼───────────────────┼──────────────────────┼────────┘
          │                   │                      │
          ▼                   ▼                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    GCS Buckets                               │
│                                                              │
│  coverline-pg-backups/     coverline-velero-backups/         │
│  └── YYYY/MM/DD/           └── <namespace>-<timestamp>/      │
│      └── coverline.dump        └── manifests + PVC data      │
│                                                              │
│  coverline-vault-snapshots/                                  │
│  └── vault-<timestamp>.snap                                  │
└─────────────────────────────────────────────────────────────┘
```

### Backup Schedule

| Component | Tool | Schedule | Retention | Target RPO |
|---|---|---|---|---|
| PostgreSQL | `pg_dump` CronJob | Every hour | 7 days | 1 hour |
| Kubernetes NS | Velero | Daily at 02:00 UTC | 30 days | 24 hours |
| Vault | `vault operator raft snapshot` CronJob | Every hour | 7 days | 1 hour |
| Terraform state | GCS versioning | On every `apply` | Indefinite (versioned) | N/A |

---

## Prerequisites

- Phase 7 (Vault) running on cluster
- Phase 6 (Prometheus/Grafana) running on cluster
- `gcloud` CLI authenticated with `roles/storage.admin` on the project
- `helm` and `kubectl` configured for the dev cluster

---

## Step 1 — GCS Backup Buckets

Create three versioned GCS buckets with lifecycle policies.

```bash
PROJECT_ID="platform-eng-lab-will"
REGION="us-central1"

# PostgreSQL backups — 7-day retention
gsutil mb -p $PROJECT_ID -l $REGION gs://coverline-pg-backups-$PROJECT_ID
gsutil versioning set on gs://coverline-pg-backups-$PROJECT_ID
gsutil lifecycle set bucket-lifecycle-7d.json gs://coverline-pg-backups-$PROJECT_ID

# Velero backups — 30-day retention
gsutil mb -p $PROJECT_ID -l $REGION gs://coverline-velero-backups-$PROJECT_ID
gsutil versioning set on gs://coverline-velero-backups-$PROJECT_ID

# Vault snapshots — 7-day retention
gsutil mb -p $PROJECT_ID -l $REGION gs://coverline-vault-snapshots-$PROJECT_ID
gsutil versioning set on gs://coverline-vault-snapshots-$PROJECT_ID
```

`bucket-lifecycle-7d.json`:
```json
{
  "lifecycle": {
    "rule": [{
      "action": { "type": "Delete" },
      "condition": { "age": 7 }
    }]
  }
}
```

---

## Step 2 — PostgreSQL Backup CronJob

Deploy a CronJob that runs `pg_dump` hourly and uploads to GCS. A Prometheus alert fires if the job fails.

### Service Account

```bash
# Create a GCP service account for backup jobs
gcloud iam service-accounts create coverline-backup-sa \
  --display-name "CoverLine backup service account"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:coverline-backup-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

# Workload Identity binding
gcloud iam service-accounts add-iam-policy-binding \
  coverline-backup-sa@$PROJECT_ID.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT_ID.svc.id.goog[coverline/pg-backup-sa]"
```

### Kubernetes CronJob Manifest

`manifests/pg-backup-cronjob.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pg-backup-sa
  namespace: coverline
  annotations:
    iam.gke.io/workload-identity: "platform-eng-lab-will/coverline-backup-sa@platform-eng-lab-will.iam.gserviceaccount.com"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-backup
  namespace: coverline
spec:
  schedule: "0 * * * *"   # every hour
  concurrencyPolicy: Forbid
  failedJobsHistoryLimit: 3
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: pg-backup-sa
          restartPolicy: OnFailure
          containers:
            - name: pg-backup
              image: google/cloud-sdk:slim
              env:
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: coverline-db-secret
                      key: postgres-password
                - name: BACKUP_BUCKET
                  value: "gs://coverline-pg-backups-platform-eng-lab-will"
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  apt-get install -y --no-install-recommends postgresql-client 2>/dev/null
                  TIMESTAMP=$(date +%Y/%m/%d/%H%M%S)
                  DUMP_FILE="/tmp/coverline-${TIMESTAMP}.dump"
                  pg_dump \
                    -h coverline-postgresql \
                    -U postgres \
                    -d coverline \
                    -Fc \
                    -f "$DUMP_FILE"
                  gsutil cp "$DUMP_FILE" "${BACKUP_BUCKET}/${TIMESTAMP}.dump"
                  echo "Backup complete: ${BACKUP_BUCKET}/${TIMESTAMP}.dump"
              resources:
                requests:
                  cpu: 100m
                  memory: 256Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
```

### Prometheus Alert

`manifests/pg-backup-alert.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pg-backup-alerts
  namespace: coverline
spec:
  groups:
    - name: backup
      rules:
        - alert: PostgresBackupFailed
          expr: |
            kube_job_status_failed{job_name=~"pg-backup-.*", namespace="coverline"} > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "PostgreSQL backup job failed"
            description: "The hourly pg_dump CronJob has failed. RPO target is at risk."
```

Apply and verify:
```bash
kubectl apply -f manifests/pg-backup-cronjob.yaml
kubectl apply -f manifests/pg-backup-alert.yaml

# Trigger a manual run to verify
kubectl create job --from=cronjob/pg-backup pg-backup-manual -n coverline
kubectl logs -l job-name=pg-backup-manual -n coverline --follow
```

---

## Step 3 — Velero (Kubernetes Workload Backup)

Velero backs up the entire `coverline` namespace including PVCs.

### Install Velero

```bash
# Create GCS bucket SA for Velero
gcloud iam service-accounts create velero-sa \
  --display-name "Velero backup service account"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:velero-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:velero-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.storageAdmin"

# Download SA key for Velero (Workload Identity doesn't support Velero's GCS plugin well)
gcloud iam service-accounts keys create /tmp/velero-key.json \
  --iam-account velero-sa@$PROJECT_ID.iam.gserviceaccount.com

# Install Velero with GCS plugin
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.provider=gcp \
  --set configuration.backupStorageLocation.bucket=coverline-velero-backups-$PROJECT_ID \
  --set configuration.backupStorageLocation.config.serviceAccount=velero-sa@$PROJECT_ID.iam.gserviceaccount.com \
  --set-file credentials.secretContents.cloud=/tmp/velero-key.json \
  --set initContainers[0].name=velero-plugin-for-gcp \
  --set initContainers[0].image=velero/velero-plugin-for-gcp:v1.9.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins \
  --set snapshotsEnabled=true
```

### Scheduled Backup

```bash
# Daily backup of the coverline namespace at 02:00 UTC, retain 30 days
velero schedule create coverline-daily \
  --schedule="0 2 * * *" \
  --include-namespaces coverline \
  --ttl 720h \
  --snapshot-volumes=true
```

### Verify Backup Status

```bash
velero schedule get
velero backup get
velero backup describe <backup-name> --details
```

---

## Step 4 — Vault Snapshot CronJob

```yaml
# manifests/vault-snapshot-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-snapshot
  namespace: vault
spec:
  schedule: "0 * * * *"   # every hour
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: pg-backup-sa   # reuse same GCS-capable SA
          restartPolicy: OnFailure
          containers:
            - name: vault-snapshot
              image: hashicorp/vault:1.15
              env:
                - name: VAULT_ADDR
                  value: "http://vault.vault.svc.cluster.local:8200"
                - name: VAULT_TOKEN
                  valueFrom:
                    secretKeyRef:
                      name: vault-snapshot-token
                      key: token
                - name: SNAPSHOT_BUCKET
                  value: "gs://coverline-vault-snapshots-platform-eng-lab-will"
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
                  SNAP_FILE="/tmp/vault-${TIMESTAMP}.snap"
                  vault operator raft snapshot save "$SNAP_FILE"
                  # gsutil is not in vault image — use curl to upload
                  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
                  curl -s -H "Authorization: Bearer $TOKEN" \
                    -X POST \
                    --data-binary "@$SNAP_FILE" \
                    "https://storage.googleapis.com/upload/storage/v1/b/${SNAPSHOT_BUCKET#gs://}/o?uploadType=media&name=vault-${TIMESTAMP}.snap"
                  echo "Vault snapshot saved: vault-${TIMESTAMP}.snap"
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
```

> **Note:** For production, use a separate sidecar with `google/cloud-sdk` to perform the GCS upload, or use Workload Identity with a proper RBAC token. The example above is simplified for lab purposes.

---

## Step 5 — DR Runbook

The full DR runbook lives at [`docs/runbooks/dr-recovery.md`](docs/runbooks/dr-recovery.md).

Summary of scenarios covered:

| Scenario | Estimated RTO | RPO (max data loss) |
|---|---|---|
| PostgreSQL data loss (table drop / corruption) | 30 min | 1 hour |
| PostgreSQL pod crash (PVC intact) | 5 min | 0 (PVC survives) |
| Full namespace deletion | 45 min | 24 hours (Velero daily) |
| Full cluster loss | 2–3 hours | 1 hour (pg_dump + Vault) |
| Vault loss | 20 min | 1 hour (raft snapshot) |
| Terraform state corruption | 10 min | 0 (GCS versioning) |

**Contractual SLA check:** RTO 4h / RPO 1h — all scenarios above are within contract.

---

## Step 6 — Challenge: Restore Drill

Run a timed DR drill before marking this phase complete.

### PostgreSQL Restore Test

```bash
# 1. Record the current state
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "SELECT COUNT(*) FROM claims;"

# 2. Simulate data loss — drop the claims table
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "DROP TABLE claims CASCADE;"

# --- START TIMER ---

# 3. Find the latest backup
gsutil ls -l gs://coverline-pg-backups-platform-eng-lab-will/ | sort -k2 | tail -5

# 4. Download the latest dump
gsutil cp gs://coverline-pg-backups-platform-eng-lab-will/<latest>.dump /tmp/restore.dump

# 5. Copy into the pod and restore
kubectl cp /tmp/restore.dump coverline/coverline-postgresql-0:/tmp/restore.dump
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  pg_restore -U postgres -d coverline --clean /tmp/restore.dump

# 6. Verify
kubectl exec -it coverline-postgresql-0 -n coverline -- \
  psql -U postgres -d coverline -c "SELECT COUNT(*) FROM claims;"

# --- STOP TIMER — record actual RTO ---
```

### Velero Namespace Restore Test

```bash
# 1. Delete the namespace (simulate cluster loss of app)
kubectl delete namespace coverline

# --- START TIMER ---

# 2. Restore from latest Velero backup
velero restore create --from-schedule coverline-daily --wait

# 3. Verify all pods are Running
kubectl get pods -n coverline

# 4. Verify app is responding
kubectl port-forward svc/coverline-frontend 3000:3000 -n coverline &
curl http://localhost:3000/health

# --- STOP TIMER ---
```

Record results in `docs/runbooks/dr-recovery.md` under **Drill History**.

---

## Step 7 — ADR

Write `docs/decisions/adr-025-velero-backup.md` covering:

- Why Velero over manual `kubectl` exports
- Why Velero over GCP-native [Backup for GKE](https://cloud.google.com/kubernetes-engine/docs/add-on/backup-for-gke/concepts/backup-for-gke)
- Trade-offs: cost, complexity, GKE version compatibility

Key decision points:
- GCP Backup for GKE is simpler but costs ~$0.10/GB/month per protected resource — at lab scale this is negligible, but Velero is portable across clouds
- Velero supports namespace-level granularity; GCP Backup for GKE works at the cluster level
- At 1M+ members, multi-cloud optionality is worth the operational overhead of self-managed Velero

---

## Verification Checklist

Before marking Phase 10c complete, confirm:

- [ ] `pg-backup` CronJob runs hourly and uploads dumps to GCS
- [ ] PrometheusRule alert fires when the CronJob fails (test by forcing a failure)
- [ ] Velero daily schedule is active: `velero schedule get`
- [ ] Vault snapshot CronJob runs hourly
- [ ] PostgreSQL restore drill completed — actual RTO recorded < 4 hours
- [ ] Velero namespace restore drill completed
- [ ] `docs/runbooks/dr-recovery.md` committed and reviewed
- [ ] `adr-025-velero-backup.md` committed

---

## Cost Estimate

| Resource | Cost |
|---|---|
| 3 GCS buckets (backup data ~5 GB/month) | ~$0.10/month |
| GKE cluster (same as other phases) | ~$7–10/day |
| Velero + backup SA | No additional cost |
| **Total** | Negligible on top of cluster cost |

---

## Key Files

```
phase-10c-backup-dr/
├── README.md                          # This file
├── manifests/
│   ├── pg-backup-cronjob.yaml         # Hourly pg_dump CronJob
│   ├── pg-backup-alert.yaml           # PrometheusRule for backup failure
│   └── vault-snapshot-cronjob.yaml    # Hourly Vault raft snapshot CronJob
└── docs/
    └── runbooks/
        └── dr-recovery.md             # Step-by-step DR runbook with drill history
```

---

## ADRs

- [`adr-025-velero-backup.md`](../docs/decisions/adr-025-velero-backup.md) — Velero vs GCP-native Backup for GKE vs manual exports

---

## Related Phases

- **Phase 7 (Vault)** — Vault is a stateful component; its raft snapshots are part of this DR strategy
- **Phase 6 (Observability)** — Prometheus alerts on backup job failure require the Phase 6 stack to be running
- **Phase 1 (Terraform)** — GCS backend for state is already versioned; no additional work needed
