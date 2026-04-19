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

## Repository structure

```
phase-1-terraform/
├── envs/
│   ├── dev/          ← deploy here for the lab (e2-standard-2, spot, max 1 node)
│   ├── staging/      ← staging config (e2-standard-2, max 3 nodes)
│   └── prod/         ← production config (e2-standard-4, on-demand, max 5 nodes)
└── modules/
    ├── gke/          ← GKE cluster + node pool
    └── networking/   ← VPC, subnet, Cloud NAT, firewall
```

Each environment has its own `backend.tf` (isolated remote state) and `.tfvars` (separate sizing and CIDR ranges). Deploying dev cannot affect prod state.

---

## Deploy

All commands run from the environment directory, not the root.

```bash
cd phase-1-terraform/envs/dev

terraform init
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

Connect kubectl after apply:

```bash
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will

kubectl get nodes
```

### Environment differences

| | dev | staging | prod |
|---|---|---|---|
| Machine type | `e2-standard-2` | `e2-standard-2` | `e2-standard-4` |
| Spot instances | yes | yes | no |
| Max nodes | 1 | 3 | 5 |
| Cluster name | `*-dev-gke` | `*-staging-gke` | `*-prod-gke` |

---

## Teardown

```bash
cd phase-1-terraform/envs/dev
terraform destroy -var-file=dev.tfvars
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

## Production Considerations

### 1. One GCP project per environment

This lab runs everything in a single project. In production, each environment — dev, staging, prod — should be a separate GCP project. This gives you:

- **Blast radius isolation:** a misconfigured `terraform destroy` in dev cannot touch prod resources.
- **Separate IAM boundaries:** developers can have broad access in dev with no access to prod.
- **Independent billing:** cost attribution per environment is clean and auditable.

The `envs/` structure in this repo is already designed for this — each environment's `backend.tf` points to a different GCS bucket and each `.tfvars` can target a different `project_id`.

---

### 2. Version and publish Terraform modules

This lab references modules locally (`../../modules/gke`). In production, modules should be versioned and pinned:

```hcl
# Lab — works but unreproducible across teams
module "gke" {
  source = "../../modules/gke"
}

# Production — pinned to a specific release
module "gke" {
  source = "git::https://github.com/your-org/terraform-modules.git//gke?ref=v2.1.0"
}
```

Without versioning, a module change merged by one engineer silently affects every other engineer's next `terraform apply`. With tags, you opt in to upgrades deliberately.

---

### 3. Enforce state locking and remote backends

GCS provides native state locking — two concurrent `terraform apply` runs cannot corrupt state. This lab already uses GCS, so locking is in place. What teams often miss in production:

- **Never use local state** — it can't be shared and gets lost when a laptop dies.
- **Separate state per environment** — one corrupted state file should not block all environments.
- **Restrict bucket access** — the GCS state bucket should only be writable by the CI/CD service account, not every developer.

```hcl
backend "gcs" {
  bucket = "platform-eng-lab-will-tfstate-prod"
  prefix = "gke"
}
```

---

### 4. Replace spot nodes with a mixed node pool strategy

Spot (preemptible) nodes are reclaimed by GCP with 30 seconds notice. This is fine for the lab but unacceptable for workloads that can't tolerate interruption. Production clusters should use a mixed strategy:

| Node pool | Type | For |
|---|---|---|
| `pool-spot` | Spot, autoscaling | Stateless apps, batch jobs, CI runners |
| `pool-standard` | On-demand, min 2 | System components, databases, anything with a PodDisruptionBudget |

This keeps costs low while guaranteeing capacity for critical workloads.

---

### 5. Enable deletion protection and drift detection

Two settings that prevent the most common production accidents:

**Deletion protection** — prevents the cluster from being destroyed via Terraform or the console without an explicit override:

```hcl
resource "google_container_cluster" "main" {
  deletion_protection = true  # lab sets this to false for easy teardown
}
```

**Drift detection** — in CI, run `terraform plan` on a schedule (e.g. nightly) and alert if the plan is non-empty. Any diff means someone made a manual change to production infrastructure. This is the audit mechanism that makes IaC meaningful.

---

### 6. Enable Binary Authorization

By default, any container image can run on the cluster — including images from untrusted registries or with known CVEs. Binary Authorization enforces that only images signed by a trusted CI pipeline are allowed to deploy:

```hcl
resource "google_container_cluster" "main" {
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }
}
```

Combined with image signing in CI (covered in Phase 10b), this closes the supply chain gap: an attacker who compromises a registry cannot run arbitrary code on the cluster because unsigned images are rejected at admission.

---

### 7. Use Workload Identity instead of service account keys

This lab provisions a GKE cluster but doesn't address how pods authenticate to GCP services. The naive approach — mounting a service account JSON key as a Kubernetes secret — creates long-lived credentials that can be extracted from the cluster.

Workload Identity (covered in Phase 9) maps a Kubernetes service account to a GCP service account without any key file. The credential is ephemeral, scoped to the pod, and automatically rotated. In production, no GCP service account key should ever exist as a Kubernetes secret.

→ **Next: [Phase 2 — Kubernetes](../phase-2-kubernetes/README.md)**
