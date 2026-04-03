# DevOps Practice Lab Roadmap (End-to-End Platform Engineering)

## Goal

Build a complete production-like DevOps platform step by step, including:

* Infrastructure as Code (Terraform on GCP)
* Kubernetes cluster (GKE)
* GitOps (ArgoCD)
* Microservices deployment (Helm)
* Observability stack (Prometheus, Grafana, Loki)
* Secrets management (Vault)
* Data platform (Airflow + dbt)
* CI/CD pipelines

Claude should guide the user through progressive challenges, increasing in complexity.

---

## Prerequisites

Before starting, ensure the following tools are installed and configured:

| Tool | Minimum Version | Purpose |
|---|---|---|
| `docker` | 24.x | Container runtime |
| `docker compose` | v2 | Local multi-container orchestration |
| `git` | 2.x | Version control |
| `gcloud` CLI | 460.x | GCP management |
| `terraform` | 1.7.x | Infrastructure as Code |
| `kubectl` | 1.29.x | Kubernetes CLI |
| `helm` | 3.14.x | Kubernetes package manager |
| `argocd` CLI | 2.10.x | GitOps deployments |
| `vault` CLI | 1.15.x | Secrets management |
| `dbt` | 1.7.x | Data transformations |

**GCP Requirements:**
* A GCP account with billing enabled
* A GCP project with Owner or Editor IAM role

**Always run `terraform destroy` after each session to avoid unnecessary charges.**

### Estimated Costs per Phase

> Costs assume spot nodes (`e2-standard-2`) in `us-central1`. Destroy infrastructure between sessions.

| Phase | New GCP Services | Est. Cost/Day | Notes |
|---|---|---|---|
| 0 | None (local Docker only) | $0 | No cloud resources |
| 1 | GKE cluster, VPC, NAT, BigQuery | ~$4–6 | GKE mgmt fee $0.10/hr + 3 spot nodes ~$1.50/day + NAT ~$0.50/day |
| 2 | None (uses Phase 1 cluster) | ~$4–6 | Same cluster |
| 3 | Persistent disks for PostgreSQL + Redis | ~$5–7 | PVCs add ~$0.04/GB/month |
| 4 | Artifact Registry | ~$5–7 | Registry storage ~$0.10/GB/month, negligible at lab scale |
| 5 | None (ArgoCD runs on cluster) | ~$5–7 | Same cluster |
| 6 | Additional nodes for Prometheus/Loki | ~$7–10 | Observability stack is memory-heavy, may trigger autoscale |
| 7 | None (Vault runs on cluster) | ~$7–10 | Same cluster |
| 8 | Temporary extra nodes during load tests | ~$8–12 | Autoscaler adds nodes under simulated load |
| 9 | Airflow workers, BigQuery queries | ~$8–12 | Airflow needs more CPU/memory |
| 10 | None | ~$7–10 | Same cluster |
| 10b | None | ~$7–10 | Same cluster |
| 11 | Everything running together | ~$15–25 | Full platform: all services active simultaneously |

**Free tier:** New GCP accounts get **$300 in free credits** — enough to complete the entire lab if you destroy resources between sessions.

**Recommended repository structure:**
```
platform-engineering-lab-gke/
├── docs/
│   └── decisions/          # Architecture Decision Records (ADRs)
├── phase-0-foundations/
│   └── docker/
├── phase-1-terraform/
│   └── modules/
│       ├── networking/
│       └── gke/
├── phase-2-kubernetes/
├── phase-3-helm/
├── phase-4-ci-cd/
├── phase-5-gitops/
├── phase-6-observability/
├── phase-7-vault/
├── phase-8-advanced-k8s/
├── phase-9-data-platform/
├── phase-10-security/
├── phase-10b-cks/
└── phase-11-capstone/
```

---

## Portfolio & Documentation Standards

Every phase folder must include a `README.md` covering:
* What was built and why
* Commands to deploy/run
* Expected output or screenshots
* Teardown instructions

A top-level `README.md` must be maintained throughout the project with:
* Short description of the platform
* Tech stack badges (Terraform, GKE, ArgoCD, Helm, Prometheus, Vault, etc.)
* Phase completion status table (checkboxes)
* High-level architecture diagram (Mermaid or image)

Architecture Decision Records (ADRs) live in `docs/decisions/`. Create one for each major tool choice (e.g., "Why ArgoCD over Flux", "Why GKE over self-managed Kubernetes"). This demonstrates senior-level thinking.

---

# Phase 0 — Foundations (MANDATORY)

## Objective

Build strong fundamentals before touching Kubernetes.

## Topics

* Linux basics (processes, networking, permissions)
* Git workflows
* Docker fundamentals
* Networking basics (VPC, DNS, HTTP)

## Challenges

1. Build a Dockerfile for a Python and Node.js app
2. Optimize image size (multi-stage builds)
3. Run containers locally with docker-compose
4. Simulate a simple service-to-service communication

## Expected Outcome

* A working `docker-compose.yml` with a Python backend and Node.js frontend communicating over a shared network
* Multi-stage Dockerfiles for both services with optimized image sizes
* Basic understanding of container networking and inter-service communication

---

# Phase 1 — Cloud & Terraform (GCP)

## Objective

Provision infrastructure using Terraform across multiple environments.

## Topics

* Terraform basics (providers, state, modules)
* GCP fundamentals (IAM, VPC, Compute)
* Multi-environment setup (dev/staging/prod)
* Cost optimization (preemptible nodes, autoscaling, committed use discounts)

## Challenges

1. Create a GCP project using Terraform
2. Create a VPC with:

   * Public and private subnets
   * Firewall rules
3. Provision a GKE cluster
4. Configure kubectl access
5. Structure Terraform for multiple environments (dev/staging/prod) using workspaces or separate state files
6. Configure preemptible/spot nodes to minimize cost

## Expected Outcome

Reusable Terraform modules for:

* networking
* Kubernetes cluster

Deployable to at least two environments (dev and staging) with environment-specific variables.

> **Cost reminder:** Run `terraform destroy` after completing this phase to avoid ongoing GCP charges.

---

# Phase 2 — Kubernetes Core

## Objective

Understand raw Kubernetes before abstractions.

## Topics

* Pods, Deployments, Services
* ConfigMaps and Secrets
* Ingress controllers

## Challenges

1. Deploy a simple app using raw YAML
2. Expose it via Service + Ingress
3. Inject environment variables via ConfigMaps
4. Debug a failing pod

---

# Phase 3 — Helm & Microservices

## Objective

Package and deploy applications properly, including stateful services.

## Topics

* Helm charts
* Values.yaml
* Templating
* StatefulSets and PersistentVolumeClaims
* Kubernetes-hosted databases and caching

## Challenges

1. Convert a raw deployment into a Helm chart
2. Deploy a microservices app:

   * frontend (Node.js)
   * backend (Python API)
3. Use Helm values for environment configs
4. Version and upgrade releases
5. Deploy PostgreSQL via Helm (Bitnami chart) — backend connects to it
6. Deploy Redis via Helm (Bitnami chart) — backend uses it for caching
7. Connect the Python backend to both PostgreSQL and Redis

## Note on managed vs self-hosted
PostgreSQL and Redis are deployed as Kubernetes StatefulSets in this phase to practice PVCs, StatefulSets, and Helm. In production these would be Cloud SQL and Cloud Memorystore (managed GCP services) to reduce operational overhead.

---

# Phase 4 — CI/CD Pipelines

## Objective

Automate build and delivery before introducing GitOps — so there is a real pipeline pushing image changes for ArgoCD to watch.

## Tools

* GitHub Actions or GitLab CI
* `tflint` — Terraform linting
* `hadolint` — Dockerfile linting
* `yamllint` — YAML linting
* pre-commit hooks

## Challenges

1. Set up pre-commit hooks with `tflint`, `hadolint`, and `yamllint`
2. Build Docker images on commit
3. Push to container registry (GCR or Artifact Registry)
4. Update the Helm chart image tag automatically
5. Add a test stage before image push

---

# Phase 5 — GitOps with ArgoCD

## Objective

Automate deployments using GitOps, driven by the CI/CD pipeline from Phase 4.

## Topics

* ArgoCD architecture
* Declarative deployments

## Challenges

1. Install ArgoCD in the cluster
2. Connect a Git repo
3. Deploy Helm charts via ArgoCD
4. Enable auto-sync
5. Simulate drift and recovery

## ADR

Write `docs/decisions/adr-001-argocd-over-flux.md` explaining why ArgoCD was chosen.

---

# Phase 6 — Observability Stack

## Objective

Monitor and debug systems.

## Stack

* Prometheus (metrics)
* Grafana (dashboards)
* Loki (logs)

## Challenges

1. Install kube-prometheus-stack
2. Create dashboards for:

   * CPU / memory
   * request latency
3. Centralize logs with Loki
4. Create alerts (e.g., high CPU)

---

# Phase 7 — Secrets Management (Vault)

## Objective

Secure secrets properly — injecting them into both pods and CI/CD pipelines.

## Topics

* Vault basics
* Dynamic secrets
* Kubernetes integration

## Challenges

1. Deploy Vault in Kubernetes
2. Store application secrets
3. Inject secrets into pods
4. Rotate secrets dynamically
5. Integrate Vault with the CI/CD pipeline from Phase 4

---

# Phase 8 — Advanced Kubernetes

## Objective

Operate production-grade clusters.

## Topics

* HPA (autoscaling)
* Resource limits and requests
* Pod disruption budgets
* Cost optimization (cluster autoscaler, node auto-provisioning)

## Challenges

1. Configure HPA and cluster autoscaler
2. Simulate load and observe scale-out
3. Set resource limits and tune performance
4. Configure scale-to-zero for non-production environments

---

> **Certification Milestone: CKA**
> After completing Phase 8 you have the practical knowledge to sit the **Certified Kubernetes Administrator (CKA)** exam. You have covered: workloads, services, networking, storage, cluster maintenance, troubleshooting, and autoscaling. Register and attempt the CKA before moving to Phase 9.

---

# Phase 9 — Data Platform (Airflow + dbt)

## Objective

Build a modern data pipeline.

## Stack

* Airflow (orchestration)
* dbt (transformations)

## Challenges

1. Deploy Airflow on Kubernetes
2. Create DAG for ETL pipeline
3. Use dbt for transformations
4. Store results in a data warehouse

---

# Phase 10 — Security & Production Hardening

## Objective

Make system production-ready.

## Topics

* RBAC
* Network policies
* Image scanning

## Challenges

1. Restrict pod communication with NetworkPolicy
2. Apply least privilege IAM and service account bindings
3. Scan container images (Trivy or Grype)
4. Enable and review Kubernetes audit logs

---

# Phase 10b — CKS Exam Preparation (Certified Kubernetes Security Specialist)

## Objective

Cover all six CKS exam domains with hands-on challenges. Requires CKA certification (see milestone after Phase 8).

## CKS Exam Domains & Challenges

### 1. Cluster Setup (10%)
1. Run CIS benchmark against the cluster using `kube-bench`
2. Configure TLS on the Ingress controller
3. Restrict access to the node metadata endpoint
4. Verify API server flags (disable anonymous auth, enable audit logging)

### 2. Cluster Hardening (15%)
1. Lock down service accounts — disable auto-mount where not needed
2. Restrict API server access with RBAC (no wildcard permissions)
3. Upgrade the cluster to a newer Kubernetes minor version

### 3. System Hardening (15%)
1. Apply an AppArmor profile to a pod
2. Apply a seccomp profile (RuntimeDefault) to a pod
3. Minimize the attack surface: remove unnecessary packages from a base image

### 4. Minimize Microservice Vulnerabilities (20%)
1. Apply Pod Security Standards (`restricted` mode)
2. Deploy OPA Gatekeeper and write a policy to block privileged containers
3. Run a workload in a sandboxed runtime (gVisor / `runsc`)
4. Configure mTLS between services using a service mesh (Istio or Linkerd)

### 5. Supply Chain Security (20%)
1. Sign container images with Cosign
2. Enforce signed-image policy in the cluster (Kyverno or Gatekeeper)
3. Generate and verify a Software Bill of Materials (SBOM) with Syft
4. Run static analysis on a Dockerfile with `hadolint` and on IaC with `checkov`

### 6. Monitoring, Logging & Runtime Security (20%)
1. Deploy Falco and write a custom rule to detect shell execution in a container
2. Review and query Kubernetes audit logs for suspicious activity
3. Make a container filesystem immutable (`readOnlyRootFilesystem: true`)
4. Detect and respond to a simulated runtime threat using Falco alerts

## Study Resources

* [killer.sh CKS simulator](https://killer.sh) — use the two free sessions included with exam registration
* [Kubernetes docs — Security](https://kubernetes.io/docs/concepts/security/)
* Falco documentation
* CIS Kubernetes Benchmark (PDF)

> **Certification Milestone: CKS**
> After completing Phase 10b, attempt the **Certified Kubernetes Security Specialist (CKS)** exam. The exam is performance-based (2 hours, live cluster). Practice speed — you will not have time to read docs for every answer.

---

# Phase 11 — Capstone Project

## Objective

Combine everything into one platform.

## Requirements

* Fully automated infrastructure (Terraform)
* GitOps deployment (ArgoCD)
* Microservices (Helm)
* Observability stack
* Vault secrets
* CI/CD pipeline
* Data pipeline (Airflow + dbt)

## Final Challenge

Deploy a production-like system with:

* Zero manual steps
* Full monitoring
* Secure secret handling
* Automated deployments
* Multi-environment promotion (dev → staging → prod)

---

# Instructions for Claude

When guiding the user:

1. Break each phase into small actionable steps
2. Provide commands and explanations
3. Simulate real-world issues (failures, debugging)
4. Ask the user to validate outcomes
5. Increase difficulty gradually
6. Encourage best practices, not shortcuts
7. Remind the user to run `terraform destroy` after any phase that provisions GCP resources
8. Prompt the user to update the top-level `README.md` and write a per-phase `README.md` at the end of each phase
9. Suggest ADRs when a significant tool or design decision is made

---

# End Goal

By completing this roadmap, the user should be able to:

* Design and operate cloud infrastructure
* Manage Kubernetes clusters
* Implement GitOps workflows
* Build CI/CD pipelines
* Monitor and secure production systems
* Deploy data pipelines
* Pass the CKA and CKS certification exams

This is equivalent to real-world DevOps / Platform Engineer experience, with industry-recognized certifications to prove it.
