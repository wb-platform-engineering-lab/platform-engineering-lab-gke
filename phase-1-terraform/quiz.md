# Phase 1 Quiz — Cloud & Terraform (GCP)

10 questions · one correct answer per question

> Interactive version: [▶ Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-1-terraform/quiz.html)

---

**Q1.** Your colleague runs `terraform apply` at the same time as you against the same environment. What prevents the state file from getting corrupted when using a GCS backend?

- A) You need to manually configure a DynamoDB lock table
- B) GCS supports state locking natively via object locks — automatic, no extra config needed ✅
- C) Terraform queues operations using a local mutex file
- D) The second apply fails immediately with a "state version mismatch" error

---

**Q2.** A firewall rule was added manually in the GCP console and never documented. The environments have drifted. Which command reveals the drift?

- A) `terraform validate`
- B) `terraform refresh`
- C) `terraform plan` ✅
- D) `terraform show`

---

**Q3.** CoverLine needs a staging environment isolated from production — separate state, same Terraform code. Which approach gives the strongest isolation?

- A) Use `terraform.workspace` conditions with a shared backend bucket
- B) Duplicate the `.tf` files and rename the resources
- C) Separate GCP projects, each with their own GCS state bucket ✅
- D) Use different `.tfvars` files pointing at the same backend

---

**Q4.** Why does this lab use `remove_default_node_pool = true` and create a separate managed node pool?

- A) The default node pool doesn't support autoscaling
- B) GKE charges extra for the default node pool
- C) To have full control over machine type, disk type, spot settings, and lifecycle ✅
- D) The default pool always runs on spot instances

---

**Q5.** GKE nodes have no public IP address. How do they pull container images from the internet (e.g., Docker Hub)?

- A) Through the GKE control plane, which acts as an outbound proxy
- B) They can't — all images must be mirrored to Artifact Registry first
- C) Via Cloud NAT, which gives nodes outbound internet access without a public IP ✅
- D) Via a Kubernetes NetworkPolicy that opens egress to the internet

---

**Q6.** You set `spot = true` on the node pool. GCP reclaims a spot node while a claims request is being processed. What happens to the pod running on that node?

- A) The pod is paused and resumed on another node with its state intact
- B) Kubernetes terminates the pod and reschedules it on another available node ✅
- C) The pod finishes the current request, then is gracefully evicted
- D) The cluster autoscaler provisions a replacement node before the eviction completes

---

**Q7.** `terraform apply` fails with `google: could not find default credentials`. What is the correct fix?

- A) Run `gcloud auth login` to re-authenticate your account
- B) Set `GOOGLE_CREDENTIALS` to the path of your `~/.config/gcloud` directory
- C) Run `gcloud auth application-default login` ✅
- D) Add `credentials = "~/.config/gcloud/application_default_credentials.json"` to the provider block

---

**Q8.** The nightly auto-destroy GitHub Actions workflow reports "Found 0 resources" but the GKE cluster and VPC are clearly running. What is the most likely cause?

- A) The workflow is authenticating against the wrong GCP project
- B) Terraform state is stored locally on the runner and not accessible
- C) The `jq` query only checks `root_module.resources`, but all resources live in child modules ✅
- D) `terraform show -json` requires the `-no-color` flag to produce valid JSON in CI

---

**Q9.** `[Terraform Associate]` Why should `terraform.tfstate` never be committed to Git?

- A) Git can't correctly parse the JSON format of the state file
- B) It contains resource IDs that conflict across environments
- C) It can contain sensitive values in plaintext and causes state corruption in teams ✅
- D) Terraform overwrites it on every plan, generating too many noisy Git diffs

---

**Q10.** Your entire GCP project is deleted overnight. `terraform apply` restores the cluster in 20 minutes. What critical data is still missing?

- A) The VPC and firewall rules — Terraform only manages the GKE cluster
- B) Kubernetes manifests — Terraform doesn't manage application workloads
- C) Application data (PostgreSQL), Vault secrets, and images if stored in the same project ✅
- D) IAM roles — Terraform can't recreate service accounts after a project deletion
