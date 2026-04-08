# Phase 1 — Cloud & Terraform (GCP)

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/incident-animation.html) · [📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/quiz.html)

---

> **CoverLine — 50 members. Two months later.**
>
> The demo went well. The investors signed. CoverLine had 50 early members, a seed round, and a deadline to onboard their first corporate client — 200 employees of a mid-size logistics company — in six weeks.
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

## What was built

- VPC with a private subnet, secondary ranges for pods and services
- Cloud Router + NAT so private nodes can reach the internet without public IPs
- GKE cluster with a managed node pool using spot instances and autoscaling
- Remote Terraform state stored in GCS

## How to deploy

```bash
# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars

terraform init
terraform plan
terraform apply
```

## Configure kubectl

```bash
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 \
  --project platform-eng-lab-will

kubectl get nodes
```

## Teardown

```bash
terraform destroy
```

> **Cost reminder:** Always destroy when done. A running GKE cluster costs ~$5–20/day.

---

## GitHub Actions — Auto-Destroy Setup

The nightly auto-destroy workflow (`.github/workflows/auto-destroy.yml`) requires two secrets and one variable configured in GitHub.

### 1. Create a service account key

```bash
# Find your service account
gcloud iam service-accounts list --project platform-eng-lab-will

# Generate a key
gcloud iam service-accounts keys create key.json \
  --iam-account=<SA_EMAIL>
```

### 2. Add GitHub secrets

Go to **Settings → Secrets and variables → Actions → Secrets**:

| Secret | Value |
|---|---|
| `GCP_SA_KEY` | Full contents of `key.json` |
| `GCP_PROJECT_ID` | `platform-eng-lab-will` |

Delete `key.json` locally after adding it to GitHub:
```bash
rm key.json
```

### 3. Add GitHub variable

Go to **Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
|---|---|
| `AUTO_DESTROY_ENABLED` | `true` |

Set to `false` to pause nightly destruction during multi-day sessions.

### 4. Test the workflow

Go to **Actions → Auto-Destroy GCP Resources → Run workflow**, type `DESTROY`, and run. Check the Summary tab for the destruction report.

---

## Troubleshooting

### 1. `Quota 'SSD_TOTAL_GB' exceeded`
**Symptom:** `terraform apply` fails during GKE node pool creation with SSD quota error.

**Cause:** GKE uses SSD (`pd-ssd`) by default for node disks, including the temporary bootstrap node pool. Free tier GCP accounts have a 250GB SSD quota per region.

**Fix:** Set `disk_type = "pd-standard"` on both the cluster's `node_config` (bootstrap pool) and the managed node pool:
```hcl
node_config {
  disk_type    = "pd-standard"
  disk_size_gb = 50
}
```

---

### 2. `Cannot destroy cluster because deletion_protection is set to true`
**Symptom:** `terraform apply` or `terraform destroy` fails when trying to recreate the cluster.

**Cause:** Recent versions of the Google Terraform provider enable `deletion_protection = true` by default on GKE clusters.

**Fix:** Add `deletion_protection = false` to the cluster resource, then disable it on the existing cluster via gcloud before re-applying:
```bash
gcloud container clusters update <CLUSTER_NAME> --region <REGION> --no-deletion-protection
```

---

### 3. `executable gke-gcloud-auth-plugin not found`
**Symptom:** `kubectl` commands fail with `gke-gcloud-auth-plugin not found` even after installing via `gcloud components install`.

**Cause:** When gcloud is installed via Homebrew, the components are installed to a path not on the default `$PATH`.

**Fix:** Add the Homebrew gcloud bin directory to your PATH:
```bash
export PATH=$PATH:/opt/homebrew/share/google-cloud-sdk/bin
# Make permanent
echo 'export PATH=$PATH:/opt/homebrew/share/google-cloud-sdk/bin' >> ~/.zshrc
```

---

### 6. Auto-destroy reports "Found 0 resources" but resources exist

**Symptom:** The nightly auto-destroy workflow runs but skips destruction with "No resources found in Terraform state" even though the GKE cluster and VPC are running.

**Cause:** The original jq query checked `.values.root_module.resources` but all resources in this project live in **child modules** (`module.gke`, `module.networking`, `module.bigquery`). The root module has no direct resources, so the count was always 0.

**Fix:** The query was updated to traverse all child modules recursively:
```bash
# Before (broken — only checks root module)
terraform show -json | jq '.values.root_module.resources | length'

# After (fixed — checks root + all child modules)
terraform show -json | jq '[.values.root_module | .. | objects | .resources? // empty | .[]] | length'
```

---

### 5. `TLS handshake timeout` when running kubectl

**Symptom:** `kubectl get nodes` fails with `net/http: TLS handshake timeout` after the plugin is found.

**Cause:** The GKE cluster no longer exists — the nightly auto-destroy workflow deleted it.

**Fix:** Reprovision the cluster and reconnect kubectl:
```bash
cd phase-1-terraform && terraform apply -auto-approve
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
```

---

### 4. `could not find default credentials`
**Symptom:** `terraform init` fails with `storage.NewClient() failed: dialing: google: could not find default credentials`.

**Cause:** Terraform uses Application Default Credentials (ADC) to authenticate with GCP. These are separate from `gcloud auth login`.

**Fix:**
```bash
gcloud auth application-default login
```

---

## GKE Node Pool Design — Best Practices

### 1. Use spot (preemptible) nodes for non-production
Spot nodes cost 60–70% less than regular nodes. GCP can reclaim them with 30 seconds notice, so they are suitable for dev/staging but not for production workloads that can't tolerate interruption.

```hcl
node_config {
  spot = true  # enabled in this phase
}
```

### 2. Always separate the default node pool
GKE creates a default node pool automatically. We remove it and manage our own so we have full control over machine type, size, and lifecycle.

```hcl
remove_default_node_pool = true
initial_node_count       = 1
```

### 3. Enable autoscaling
Let the cluster scale nodes up and down based on actual workload demand instead of running fixed capacity.

```hcl
autoscaling {
  min_node_count = 1
  max_node_count = 3
}
```

### 4. Use private nodes
Nodes should not have public IP addresses. All outbound traffic routes through Cloud NAT. This reduces the attack surface significantly.

```hcl
private_cluster_config {
  enable_private_nodes = true
}
```

### 5. Right-size machine types
| Use case | Recommended type | vCPU | RAM |
|---|---|---|---|
| Dev / lab | `e2-standard-2` | 2 | 8GB |
| General production | `e2-standard-4` | 4 | 16GB |
| Memory-intensive | `n2-highmem-4` | 4 | 32GB |
| CPU-intensive | `c2-standard-4` | 4 | 16GB |

This lab uses `e2-standard-2` to minimize cost.

### 6. Use secondary IP ranges for pods and services
Assigning dedicated CIDR ranges to pods and services avoids IP conflicts and is required for VPC-native clusters (recommended over routes-based).

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

### 7. Use multiple node pools for different workloads (advanced)
In production, use separate node pools for different workload types — for example, a spot pool for stateless apps and an on-demand pool for stateful workloads like databases.

```
node-pool-spot     → stateless apps, batch jobs
node-pool-standard → stateful workloads, system components
```

### 8. Set resource limits on nodes
Always set `disk_size_gb` explicitly. The default (100GB) is often more than needed for a lab and adds cost.

```hcl
disk_size_gb = 50  # used in this phase
```

---

## Production Considerations

### 1. Separate environments with Terraform workspaces
In this lab, everything runs in a single GCP project. In production, each environment (dev, staging, prod) should have its own GCP project and isolated Terraform state. Terraform workspaces or separate directories per environment prevent a `terraform apply` in dev from impacting prod.

```hcl
# Recommended pattern in production
terraform workspace new prod
terraform workspace new staging
```

### 2. Enable state locking
This lab uses a GCS bucket for remote state but without explicit locking. In production with multiple engineers, two simultaneous `terraform apply` runs can corrupt the state. GCS natively supports locking via object locks — always enable it.

```hcl
backend "gcs" {
  bucket = "my-tfstate"
  prefix = "prod"
  # GCS locking is automatic — no extra config needed
}
```

### 3. Version Terraform modules
In this lab, modules are referenced locally (`./modules/gke`). In production, modules should be versioned and published to a registry (Terraform Registry or Git with tags) to guarantee reproducibility across environments.

```hcl
module "gke" {
  source  = "git::https://github.com/org/terraform-modules.git//gke?ref=v1.2.0"
}
```

### 4. Replace spot nodes with on-demand in production
Spot (preemptible) nodes are reclaimed by GCP with 30 seconds notice. Ideal for labs and batch workloads, but unacceptable for critical production services. Use a mix: spot for stateless workers, on-demand for system components and databases.

### 5. Enable Binary Authorization
In production, only signed and approved images should be allowed to run on the cluster. Binary Authorization on GKE enforces this policy and prevents deployment of unverified images or images from unapproved registries.

### 6. Remove `deletion_protection = false`
This lab disables deletion protection to make `terraform destroy` easier. In production, `deletion_protection = true` should always be enabled on the GKE cluster to prevent accidental infrastructure destruction.
