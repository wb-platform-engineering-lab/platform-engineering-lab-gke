# Phase 1 Quiz — Cloud & Terraform (GCP)

10 questions. Answer before expanding the solution.

---

**Q1.** Your colleague runs `terraform apply` at the same time as you on the same environment. What prevents the state file from getting corrupted, and is it configured by default with a GCS backend?

<details>
<summary>Answer</summary>

GCS supports **state locking** natively via object locks — when one `terraform apply` runs, it acquires a lock on the state file and any concurrent `apply` waits or fails. With the GCS backend, locking is automatic with no extra configuration needed.

</details>

---

**Q2.** CoverLine's staging environment drifted from production because a firewall rule was added manually in the GCP console and never documented. How does Terraform prevent this, and what command would reveal the drift if it happened anyway?

<details>
<summary>Answer</summary>

Terraform prevents drift by being the single source of truth — any resource not defined in `.tf` files shouldn't exist. If someone makes a manual change, `terraform plan` will detect the drift and show what it would change to bring the real state back in line with the declared state.

</details>

---

**Q3.** You need to create a dev environment that is isolated from production — separate state, separate resources, same Terraform code. What are two ways to achieve this?

<details>
<summary>Answer</summary>

1. **Terraform workspaces** — `terraform workspace new dev` creates an isolated state file while reusing the same configuration. Environment-specific values are passed via `terraform.workspace` conditions or separate `.tfvars` files.
2. **Separate directories / separate GCP projects** — each environment lives in its own directory with its own `backend.tf` pointing to a different GCS bucket prefix (or different project entirely). This is the stricter approach used in most production setups because workspaces still share the same backend bucket.

</details>

---

**Q4.** Why does this lab use `remove_default_node_pool = true` and create a separate managed node pool, rather than using the default pool GKE creates?

<details>
<summary>Answer</summary>

GKE creates a default node pool automatically with settings you can't fully control at creation time. Removing it and defining a managed node pool explicitly gives full control over machine type, disk type, spot vs on-demand, autoscaling bounds, and labels. It also makes the infrastructure fully reproducible — the default pool's config would otherwise be partially implicit.

</details>

---

**Q5.** Your GKE nodes have no public IP addresses. How do they pull container images from the internet (e.g., Docker Hub) if they can't be reached from outside?

<details>
<summary>Answer</summary>

**Cloud NAT** (Network Address Translation). Outbound traffic from private nodes is routed through a Cloud Router + Cloud NAT gateway, which gives nodes internet access for outbound connections (pulling images, calling APIs) without assigning them a public IP. Inbound connections from the internet are still blocked.

</details>

---

**Q6.** You set `spot = true` on the node pool. A claim submission is being processed when GCP reclaims a spot node. What happens to the pod running on that node, and what should be configured to minimise impact?

<details>
<summary>Answer</summary>

The pod is terminated with 30 seconds notice. Kubernetes reschedules it on another available node. To minimise impact:
- Set a **PodDisruptionBudget** so at least one replica stays available during evictions
- Run **multiple replicas** so one eviction doesn't take down the service
- Use spot nodes only for **stateless** workloads — stateful workloads (databases) should run on on-demand nodes

</details>

---

**Q7.** You run `terraform apply` and get: `Error: storage.NewClient() failed: google: could not find default credentials`. What is the cause and fix?

<details>
<summary>Answer</summary>

Terraform uses **Application Default Credentials (ADC)** to authenticate with GCP — separate from the credentials set by `gcloud auth login`. The fix:

```bash
gcloud auth application-default login
```

This creates a credentials file that Terraform (and other GCP SDKs) pick up automatically.

</details>

---

**Q8.** The nightly auto-destroy GitHub Actions workflow reports "Found 0 resources" but your GKE cluster and VPC are clearly running. What is the likely cause?

<details>
<summary>Answer</summary>

The `jq` query is only checking `.values.root_module.resources` — but all resources in a modular Terraform setup live in **child modules** (`module.gke`, `module.networking`, etc.), not the root module. The root module has no direct resources, so the count is always 0. The fix is to traverse all child modules recursively:

```bash
terraform show -json | jq '[.values.root_module | .. | objects | .resources? // empty | .[]] | length'
```

</details>

---

**Q9.** `[Terraform Associate]` What is the difference between `terraform.tfstate` and `terraform.tfstate.backup`, and why should neither be committed to Git?

<details>
<summary>Answer</summary>

- `terraform.tfstate` — the current state of all managed resources. Terraform reads this before every plan/apply to know what exists.
- `terraform.tfstate.backup` — the previous state, kept automatically as a rollback reference.

Neither should be in Git because:
1. They can contain **sensitive values** (passwords, private keys) in plaintext
2. In a team, concurrent commits would cause **merge conflicts and state corruption**

Use a **remote backend** (GCS in this lab) so state is shared, locked, and never stored locally.

</details>

---

**Q10.** CoverLine's enterprise client asks: *"If your entire GCP project was deleted tonight, how long would it take to restore the platform?"* What does your Terraform setup enable, and what would still be missing for a full recovery?

<details>
<summary>Answer</summary>

With Terraform, the **infrastructure** (VPC, GKE cluster, NAT, IAM) can be restored with a single `terraform apply` — from minutes to under an hour depending on GKE provisioning time.

What would still be missing without additional planning:
- **Application data** — PostgreSQL data, Redis cache (requires backups, covered in Phase 10c)
- **Vault secrets and unseal keys** — need separate backup and recovery procedure (Phase 7)
- **Container images** — need to be in a registry that survives the project deletion (Artifact Registry in a separate project, or external registry)
- **Terraform state** — if the GCS bucket was in the same project and is deleted, the state is gone. The state bucket should be in a separate, protected project.

</details>
