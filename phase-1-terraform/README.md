# Phase 1 — Cloud & Terraform (GCP)

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
