# Phase 1 — Infrastructure as Code (Terraform + GKE)

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/incident-animation.html) · [📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/quiz.html)

---

> **CoverLine — 50 members. Two months after the seed round.**
>
> The CTO spun up a server manually on GCP. Clicked through the console. Picked a region. Chose a machine type. Installed Docker. Wrote down the IP address on a sticky note.
>
> Three weeks later, he needed to create a staging environment. He couldn't remember exactly what he'd clicked. The two environments drifted immediately. A bug that only reproduced in production took two days to diagnose because staging was missing a firewall rule that had been added manually and never documented.
>
> *"If this server dies tonight,"* a colleague asked, *"how long to rebuild it?"*
>
> The CTO paused. *"A day. Maybe two."*
>
> *"That's not acceptable."*
>
> The decision: infrastructure as code. Every resource defined in Terraform. The entire platform reproducible from a single `terraform apply`.

---

## What we build

| Resource | Details |
|---|---|
| **VPC** | Private subnet with secondary ranges for pods and services |
| **Cloud NAT + Router** | Private nodes reach the internet without public IPs |
| **GKE cluster** | Spot nodes, autoscaling 1–3, private cluster |
| **Remote state** | Terraform state stored in GCS |

---

## Prerequisites

```bash
# Authenticate to GCP
gcloud auth login
gcloud auth application-default login

# Set your project
gcloud config set project platform-eng-lab-will
```

---

## Deploy

```bash
cd phase-1-terraform

# Fill in your project ID and region
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan
terraform apply
```

Connect kubectl after apply:

```bash
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will

kubectl get nodes
```

---

## Teardown

```bash
terraform destroy
```

> **Cost reminder:** A running GKE cluster costs ~$5–20/day. Always destroy when done.

---

## Nightly Auto-Destroy (GitHub Actions)

The workflow at `.github/workflows/auto-destroy.yml` destroys the cluster each night to prevent idle spend. One-time setup:

### 1. Create a service account key

```bash
# List service accounts
gcloud iam service-accounts list --project platform-eng-lab-will

# Generate a key
gcloud iam service-accounts keys create key.json --iam-account=<SA_EMAIL>
```

### 2. Add GitHub secrets

**Settings → Secrets and variables → Actions → Secrets:**

| Secret | Value |
|---|---|
| `GCP_SA_KEY` | Full contents of `key.json` |
| `GCP_PROJECT_ID` | `platform-eng-lab-will` |

Then delete the key locally:

```bash
rm key.json
```

### 3. Add GitHub variable

**Settings → Secrets and variables → Actions → Variables:**

| Variable | Value |
|---|---|
| `AUTO_DESTROY_ENABLED` | `true` |

Set to `false` to pause nightly destruction during multi-day sessions.

### 4. Test the workflow

Go to **Actions → Auto-Destroy GCP Resources → Run workflow**, type `DESTROY`, and run. Check the Summary tab for the destruction report.

---

## Node Pool Design

| Decision | Config | Why |
|---|---|---|
| Remove default node pool | `remove_default_node_pool = true` | Full control over machine type and lifecycle |
| Spot instances | `spot = true` | 60–70% cheaper; acceptable for lab/dev |
| Autoscaling | `min = 1`, `max = 3` | Scale with workload, not fixed capacity |
| Private nodes | `enable_private_nodes = true` | No public IPs on nodes — reduces attack surface |
| Standard disk | `disk_type = "pd-standard"` | Avoids SSD quota limits on free tier accounts |
| 50GB disk | `disk_size_gb = 50` | Default 100GB is wasteful for a lab |

Secondary IP ranges are required for VPC-native clusters (preferred over routes-based):

```hcl
secondary_ip_range {
  range_name    = "pods"
  ip_cidr_range = "10.1.0.0/16"   # up to 65,536 pod IPs
}
secondary_ip_range {
  range_name    = "services"
  ip_cidr_range = "10.2.0.0/20"   # up to 4,096 service IPs
}
```

---

## Troubleshooting

### `could not find default credentials`

**Symptom:** `terraform init` fails with `dialing: google: could not find default credentials`.

**Cause:** Terraform uses Application Default Credentials (ADC), which are separate from `gcloud auth login`.

**Fix:**
```bash
gcloud auth application-default login
```

---

### `Quota 'SSD_TOTAL_GB' exceeded`

**Symptom:** `terraform apply` fails during GKE node pool creation.

**Cause:** GKE defaults to `pd-ssd` for node disks. Free tier accounts have a 250GB SSD quota per region.

**Fix:** Set `disk_type = "pd-standard"` on the node pool:

```hcl
node_config {
  disk_type    = "pd-standard"
  disk_size_gb = 50
}
```

---

### `Cannot destroy cluster because deletion_protection is set to true`

**Symptom:** `terraform destroy` fails when trying to delete the cluster.

**Cause:** Recent versions of the Google Terraform provider enable `deletion_protection = true` by default.

**Fix:** Disable it on the existing cluster, then destroy:

```bash
gcloud container clusters update platform-eng-lab-will-gke \
  --region us-central1 --no-deletion-protection

terraform destroy
```

---

### `executable gke-gcloud-auth-plugin not found`

**Symptom:** `kubectl` commands fail with `gke-gcloud-auth-plugin not found`.

**Cause:** When gcloud is installed via Homebrew, plugin binaries are not on the default `$PATH`.

**Fix:**
```bash
export PATH=$PATH:/opt/homebrew/share/google-cloud-sdk/bin
echo 'export PATH=$PATH:/opt/homebrew/share/google-cloud-sdk/bin' >> ~/.zshrc
```

---

### `TLS handshake timeout` on kubectl

**Symptom:** `kubectl get nodes` fails with `net/http: TLS handshake timeout`.

**Cause:** The cluster no longer exists — the nightly auto-destroy workflow deleted it.

**Fix:**
```bash
cd phase-1-terraform && terraform apply -auto-approve
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
```

---

### Auto-destroy reports "Found 0 resources" but resources exist

**Symptom:** The nightly workflow skips destruction even though the cluster is running.

**Cause:** The jq query was checking `.values.root_module.resources` but all resources live in child modules (`module.gke`, `module.networking`). The root module has no direct resources.

**Fix:** The query was updated to traverse child modules recursively:

```bash
# Before (broken — only checks root module)
terraform show -json | jq '.values.root_module.resources | length'

# After (fixed — checks root + all child modules)
terraform show -json | jq '[.values.root_module | .. | objects | .resources? // empty | .[]] | length'
```

---

## Production Considerations

| Topic | Lab | Production |
|---|---|---|
| Environments | Single GCP project | Separate project per env (dev/staging/prod) |
| State locking | GCS bucket (locking is automatic) | Same — GCS locking is built-in, no extra config |
| Module versioning | Local `./modules/gke` | Versioned in Terraform Registry or Git tags |
| Node type | Spot instances | Mix: spot for stateless, on-demand for stateful |
| Deletion protection | `false` (easier teardown) | `true` always |
| Binary Authorization | Disabled | Enabled — only signed images allowed to run |

→ **Next: [Phase 2 — Kubernetes](../phase-2-kubernetes/README.md)**
