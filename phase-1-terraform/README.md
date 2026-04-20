# Phase 1 — Infrastructure as Code (Terraform + GKE)

> **GCP services introduced:** VPC, Cloud NAT, GKE, GCS | **Daily cost:** ~$5–10/day (dev, spot nodes)

[▶ Watch the incident animation](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/incident-animation.html) · [📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/quiz.html)

---

## GCP services introduced

| Service | What it does | Why we need it |
|---|---|---|
| **VPC** | Isolated private network | GKE nodes live inside a VPC — nothing is reachable without one |
| **Cloud NAT** | Outbound internet for private nodes | Nodes have no public IPs; NAT lets them pull images and reach external APIs |
| **GKE** | Managed Kubernetes cluster | Runs all platform workloads across phases 2–12 |
| **GCS** | Object storage | Stores Terraform state — versioned, shared across the team |

---

## The problem

> *CoverLine — 50 members. Two months after the seed round.*
>
> The CTO spun up a server manually on GCP. Clicked through the console. Picked a region. Chose a machine type. Installed Docker. Wrote down the IP address on a sticky note.
>
> Three weeks later, he needed a staging environment. He couldn't remember what he'd clicked. The two environments drifted immediately — a bug that only reproduced in production took two days to diagnose because staging was missing a firewall rule added manually and never documented.
>
> *"If this server dies tonight, how long to rebuild it?"*
> *"A day. Maybe two."*
> *"That's not acceptable."*

The decision: infrastructure as code. Every resource defined in Terraform. The entire platform reproducible from a single `terraform apply`.

---

## Architecture

```
GCP Project: platform-eng-lab-will
│
└── VPC (10.10.0.0/16)
    └── Private subnet (us-central1)
        ├── Secondary range: pods     (10.20.0.0/16)
        └── Secondary range: services (10.30.0.0/20)
            │
            ├── Cloud Router + NAT   ← outbound internet for nodes
            ├── Internal firewall    ← allow all internal 10.0.0.0/8 traffic
            └── GKE cluster
                └── Node pool (e2-standard-2, spot, autoscaling 1–3)
```

Nodes have no public IPs. All outbound traffic routes through Cloud NAT. The GKE control plane is accessible externally (`enable_private_endpoint = false`) but node traffic stays private.

---

## Repository structure

```
phase-1-terraform/
├── envs/
│   ├── dev/          ← this lab (e2-standard-2, spot, max 1 node)
│   ├── staging/      ← (e2-standard-2, spot, max 3 nodes)
│   └── prod/         ← (e2-standard-4, on-demand, max 5 nodes)
└── modules/
    ├── gke/          ← GKE cluster + node pool
    └── networking/   ← VPC, subnet, Cloud NAT, firewall
```

Each environment has its own `backend.tf` (isolated remote state in GCS) and `.tfvars` (separate sizing and CIDR ranges). Deploying to dev cannot affect prod state.

---

## Prerequisites

```bash
# Authenticate to GCP (two separate credentials — both are required)
gcloud auth login                       # for gcloud CLI commands
gcloud auth application-default login  # for Terraform's Google provider

# Set your project
gcloud config set project platform-eng-lab-will
```

> **Why two auth commands?** `gcloud auth login` authenticates the CLI. Terraform uses Application Default Credentials (ADC) — a separate credential set. Both must be active.

---

## Architecture Decision Records

- `docs/decisions/adr-001-terraform-over-deployment-manager.md` — Why Terraform over GCP Deployment Manager for infrastructure provisioning
- `docs/decisions/adr-002-gcs-remote-state.md` — Why GCS backend with per-environment prefixes over local state
- `docs/decisions/adr-003-vpc-native-over-routes-based.md` — Why VPC-native GKE networking over routes-based mode
- `docs/decisions/adr-004-spot-nodes-dev.md` — Why spot instances in dev/staging despite preemption risk
- `docs/decisions/adr-005-workload-identity-over-sa-keys.md` — Why Workload Identity over mounted service account JSON keys

---

## Challenge 1 — Create the GCS bucket for Terraform state

This is the one step you do manually. Terraform cannot store its own state before the bucket exists.

### Step 1: Create the bucket

```bash
gsutil mb -p platform-eng-lab-will -l us-central1 \
  gs://platform-eng-lab-will-tfstate
```

### Step 2: Enable versioning

Versioning lets you recover from accidental state corruption or a failed `terraform apply`:

```bash
gsutil versioning set on gs://platform-eng-lab-will-tfstate
```

### Step 3: Verify

```bash
gsutil ls -b gs://platform-eng-lab-will-tfstate
gsutil versioning get gs://platform-eng-lab-will-tfstate
```

Expected output:
```
gs://platform-eng-lab-will-tfstate/
gs://platform-eng-lab-will-tfstate: Enabled
```

---

## Challenge 2 — Initialise Terraform and review the backend configuration

### Step 1: Review `backend.tf`

```hcl
# envs/dev/backend.tf
terraform {
  backend "gcs" {
    bucket = "platform-eng-lab-will-tfstate"
    prefix = "dev/terraform/state"
  }
}
```

Each environment writes to a different prefix in the same bucket — isolated state, no risk of cross-environment corruption.

### Step 2: Review `providers.tf`

```hcl
# envs/dev/providers.tf
terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

### Step 3: Initialise

```bash
cd phase-1-terraform/envs/dev
terraform init
```

Expected output:
```
Terraform has been successfully initialized!
Backend configuration changed! Terraform will use the GCS backend.
```

---

## Challenge 3 — Review and apply the networking module

The networking module provisions the VPC, subnet, Cloud Router, and NAT gateway.

### Step 1: Review the module

```hcl
# modules/networking/main.tf (key resources)

resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false   # we manage subnets explicitly
}

resource "google_compute_subnetwork" "private" {
  name             = var.subnetwork_name
  ip_cidr_range    = var.subnetwork_cidr
  region           = var.region
  network          = google_compute_network.vpc.id
  private_ip_google_access = true   # allows private nodes to reach Google APIs

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_ip_cidr_range   # 10.20.0.0/16 — up to 65,536 pod IPs
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_ip_cidr_range  # 10.30.0.0/20 — up to 4,096 service IPs
  }
}

resource "google_compute_router_nat" "nat" {
  name                               = var.nat_name
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
```

> **Why secondary IP ranges?** GKE VPC-native clusters assign pod IPs directly from the VPC. Without dedicated secondary ranges, pod IPs would conflict with node IPs. Each range must be large enough for the maximum expected pod count — a cluster you can't expand is a problem you'll hit at the worst time.

### Step 2: Review `dev.tfvars`

```hcl
project_id  = "platform-eng-lab-will"
region      = "us-central1"
environment = "dev"

node_count     = 1
min_node_count = 1
max_node_count = 1
machine_type   = "e2-standard-2"

subnetwork_cidr        = "10.10.0.0/16"
pods_ip_cidr_range     = "10.20.0.0/16"
services_ip_cidr_range = "10.30.0.0/20"
```

### Step 3: Plan

```bash
terraform plan -var-file=dev.tfvars
```

You should see these networking resources planned for creation:

```
+ google_compute_network.vpc
+ google_compute_subnetwork.private
+ google_compute_firewall.allow_internal
+ google_compute_router.router
+ google_compute_router_nat.nat
```

---

## Challenge 4 — Review and apply the GKE module

### Step 1: Review the module

```hcl
# modules/gke/main.tf (key decisions)

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region

  remove_default_node_pool = true   # we define our own node pool
  initial_node_count       = 1

  deletion_protection = false       # set to true in production

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true   # nodes have no public IPs
    enable_private_endpoint = false  # control plane is reachable externally
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name    = "${var.cluster_name}-np"
  cluster = google_container_cluster.primary.name

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"   # avoids SSD quota limits on free-tier accounts
    spot         = true            # 60–70% cheaper; GCP can reclaim with 30s notice

    workload_metadata_config {
      mode = "GKE_METADATA"        # required for Workload Identity
    }
  }

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }
}
```

| Decision | Config | Why |
|---|---|---|
| Remove default node pool | `remove_default_node_pool = true` | Full control over machine type and lifecycle |
| Spot instances | `spot = true` | 60–70% cheaper; acceptable for lab/dev |
| Autoscaling | `min = 1, max = 1` (dev) | Scale with workload demand |
| Private nodes | `enable_private_nodes = true` | No public IPs — reduces attack surface |
| Standard disk | `disk_type = "pd-standard"` | Avoids SSD quota exhaustion on free-tier accounts |
| Workload Identity | `GKE_METADATA` mode | Pods authenticate to GCP without service account key files |

### Step 2: Apply

```bash
terraform apply -var-file=dev.tfvars
```

GKE cluster creation takes 5–10 minutes. Expected output:

```
Apply complete! Resources: 7 added, 0 changed, 0 destroyed.
```

---

## Challenge 5 — Connect kubectl and verify the cluster

### Step 1: Fetch credentials

```bash
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will
```

### Step 2: Verify nodes are ready

```bash
kubectl get nodes -o wide
```

Expected output:
```
NAME                                STATUS   ROLES    AGE   VERSION
gke-platform-eng-lab-...-np-xxxx   Ready    <none>   2m    v1.28.x
```

### Step 3: Verify the cluster context

```bash
kubectl config current-context
```

Expected: `gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-dev-gke`

### Step 4: Verify the VPC and subnet via gcloud

```bash
# Confirm the VPC exists
gcloud compute networks list --filter="name~platform-eng-lab"

# Confirm secondary ranges are set correctly
gcloud compute networks subnets describe platform-eng-lab-will-dev-subnet \
  --region us-central1 \
  --format="table(secondaryIpRanges[].rangeName, secondaryIpRanges[].ipCidrRange)"
```

Expected:
```
RANGE_NAME  IP_CIDR_RANGE
pods        10.20.0.0/16
services    10.30.0.0/20
```

---

## Challenge 6 — Set up nightly auto-destroy (GitHub Actions)

The workflow at `.github/workflows/auto-destroy.yml` destroys the cluster each night to prevent idle spend.

### Step 1: Create a service account key

```bash
gcloud iam service-accounts list --project platform-eng-lab-will

gcloud iam service-accounts keys create key.json \
  --iam-account=<SA_EMAIL>
```

### Step 2: Add GitHub secrets

**Settings → Secrets and variables → Actions → Secrets:**

| Secret | Value |
|---|---|
| `GCP_SA_KEY` | Full contents of `key.json` |
| `GCP_PROJECT_ID` | `platform-eng-lab-will` |

Delete the key locally immediately after:

```bash
rm key.json
```

### Step 3: Add GitHub variable

**Settings → Secrets and variables → Actions → Variables:**

| Variable | Value |
|---|---|
| `AUTO_DESTROY_ENABLED` | `true` |

Set to `false` to pause nightly destruction during multi-day sessions.

### Step 4: Test the workflow

Go to **Actions → Auto-Destroy GCP Resources → Run workflow**, type `DESTROY`, and run.

---

## Teardown

```bash
cd phase-1-terraform/envs/dev
terraform destroy -var-file=dev.tfvars
```

> **Cost reminder:** Always destroy when done. A running GKE cluster costs ~$5–10/day.

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster management fee | $0.10 |
| 1× e2-standard-2 spot node | ~$0.50 |
| Cloud NAT | ~$0.05 |
| GCS state bucket | ~$0.01 |
| **Total** | **~$0.66/day** |

> Spot nodes can be reclaimed by GCP. If the node is replaced, the cost resets. Estimate $1–2/day with node churn factored in.

---

## GCP concept: VPC-native clusters

GKE supports two networking modes: **routes-based** and **VPC-native**. This lab uses VPC-native (the recommended mode), where pods get IPs directly from the VPC subnet's secondary ranges. This means:

- Pod IPs are routable within the VPC without custom routes
- No risk of route table limits as the cluster scales
- Network policies work correctly
- Required for Workload Identity and Private Google Access

---

## Production considerations

### 1. One GCP project per environment
Separate projects give you blast radius isolation, independent IAM boundaries, and clean billing. The `envs/` structure is already designed for this — each `backend.tf` and `.tfvars` can target a different `project_id`.

### 2. Version Terraform modules
This lab uses local module paths (`../../modules/gke`). In production, pin modules to a specific Git tag so a change in the module doesn't silently affect every engineer's next apply:
```hcl
source = "git::https://github.com/your-org/terraform-modules.git//gke?ref=v2.1.0"
```

### 3. Separate state per environment with restricted bucket access
The GCS bucket should be writable only by the CI/CD service account — not every developer. A developer with write access to the state bucket can corrupt or delete it, which is effectively the same as deleting the infrastructure.

### 4. Mixed node pools in production
Spot nodes are reclaimed with 30 seconds notice. Production clusters should run a spot pool for stateless workloads and a standard on-demand pool (minimum 2 nodes) for system components, databases, and anything with a `PodDisruptionBudget`.

### 5. Enable deletion protection and drift detection
Set `deletion_protection = true` in production. Run `terraform plan` in CI on a schedule — a non-empty plan means someone made a manual change to production infrastructure outside of Terraform. That's the audit mechanism that makes IaC meaningful.

### 6. Workload Identity over service account keys
This lab enables Workload Identity at the cluster level. In subsequent phases, pods authenticate to GCP services (BigQuery, GCS, Secret Manager) using Workload Identity — no JSON key files mounted as Kubernetes secrets. This is covered in Phase 9.

---

## Outcome

A private GKE cluster running in a VPC-native network, Terraform state in GCS, and three isolated environments (dev / staging / prod) each with independent state. Any team member can recreate the entire environment from scratch with `terraform apply`.

---

[Back to main README](../README.md) | [Next: Phase 2 — Kubernetes](../phase-2-kubernetes/README.md)
