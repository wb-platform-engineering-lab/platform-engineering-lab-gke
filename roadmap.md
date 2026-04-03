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

## Product Story — CoverLine

Every phase is grounded in a realistic business scenario. The product is **CoverLine** — a digital health insurance platform (Alan-style), selling group health plans to companies. Employees access their coverage, submit claims, and manage their policy through a web app.

**Why this product?**
- Health data is sensitive → security and compliance phases feel urgent and real
- Open enrollment creates predictable traffic spikes → autoscaling has a genuine business trigger
- Actuarial analytics on claims → data platform has a clear business owner
- GDPR + ISO 27001 requirements → hardening phases have audit-driven deadlines

### Product Evolution

| Phase | Company Stage | Covered Members | Core Engineering Problem |
|---|---|---|---|
| 0 | 2 founders, pre-launch | 0 | Claims API only runs on one laptop — can't demo to investors |
| 1 | Seed round | 50 (first B2B client) | Infrastructure provisioned by hand on a single VM — can't reproduce it |
| 2 | Early beta | 200 members | One bad deploy takes down claims processing and the member portal at the same time |
| 3 | Series A | 1,000 members | Claims, member portal, and provider API all in one repo — teams constantly blocking each other |
| 4 | Growing | 5,000 members | 5 engineers — deploying takes half a day, releases are delayed by 2 weeks |
| 5 | Scaling | 15,000 members | Engineer pushed untested code to prod on a Friday — claims processing was down for 2 hours |
| 6 | Series B | 50,000 members | Claims SLA breached — support team found out before engineering did |
| 7 | Enterprise sales | 100,000 members | GDPR audit: database credentials found in plaintext environment variables |
| 8 | High growth | 250,000 members | Open enrollment period — 10x traffic spike, app unresponsive for 45 minutes |
| 9 | Data team hired | 500,000 members | Actuarial team needs claims analytics in BigQuery — developers manually exporting CSVs every week |
| 10 | Enterprise | 1,000,000 members | ISO 27001 audit — need verifiable proof of least privilege, network isolation, and image provenance |
| 10b | CKS prep | 1,000,000 members | Security team formalises Kubernetes hardening ahead of certification audit |
| 11 | Capstone | 2,000,000+ members | Full platform, zero manual steps, multi-region ready |

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

## Business Context

> **CoverLine — 2 founders, 0 members**
> The two founders built a proof-of-concept claims submission API and member portal. The backend runs on one laptop and the frontend on another. Every investor demo requires both founders to be in the same room. There is no shared development environment, no versioning, and no way to onboard a third engineer without spending a day on setup.
>
> **Goal:** Make the app run consistently on any machine using containers.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing Dockerfiles |
| **Agents** | None needed — files are small and self-contained |
| **Key tools** | `Write`, `Edit`, `Bash` (docker build/run), `WebFetch` (Docker docs) |
| **Watch for** | Use `Bash` to run `docker images` and verify image sizes after each build |
| **Est. tokens** | ~60–80K |
| **Est. cost** | ~$0.40–0.55 |

---

# Phase 1 — Cloud & Terraform (GCP)

## Business Context

> **CoverLine — Seed round closed, 50 covered members (first B2B client)**
> CoverLine signed its first corporate client — a 50-person startup. The CTO manually spun up a VM on GCP, SSH'd in, and ran `docker run` to deploy the app. Two weeks later, a colleague tried to reproduce the environment for staging and couldn't — there were no notes, no scripts, and the VM had been modified by hand a dozen times.
>
> The first enterprise prospect asked: *"How do you manage your infrastructure?"* The answer of "we SSH in and run commands" ended the conversation.
>
> **Goal:** Replace manual VM setup with reproducible, version-controlled infrastructure using Terraform.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing modules |
| **Agents** | `Plan` before designing module structure — ask it to design the VPC + GKE module layout first |
| **Key tools** | `Write`, `Edit`, `Bash` (terraform commands + gcloud), `WebFetch` (GCP provider docs) |
| **Watch for** | Terraform errors are verbose — paste the full error, not just the last line. Use `Bash` to run `terraform plan` before `apply` |
| **Est. tokens** | ~150–200K (debugging GCP quota and auth issues adds tokens) |
| **Est. cost** | ~$1.00–1.35 |

> **Cost reminder:** Run `terraform destroy` after completing this phase to avoid ongoing GCP charges.

---

> **Certification Milestone: Terraform Associate + Google Cloud ACE**
> After completing Phase 1 you have the hands-on knowledge for two certifications:
> - **HashiCorp Certified: Terraform Associate (003)** — covers providers, state, modules, workspaces, and CLI commands. [Study guide](https://developer.hashicorp.com/terraform/tutorials/certification-003)
> - **Google Cloud Associate Cloud Engineer (ACE)** — covers GCP core services, IAM, VPC, GKE, and CLI. Foundational GCP cert required before the Professional tier. [Study guide](https://cloud.google.com/learn/certification/cloud-engineer)

---

# Phase 2 — Kubernetes Core

## Business Context

> **CoverLine — 200 covered members, early beta**
> CoverLine now has 4 corporate clients. The app runs as a single container on GKE. During a routine deploy, the container crashed mid-startup. For 18 minutes, members trying to submit claims saw a blank page — no error, no fallback. The on-call engineer had no way to inspect the running state, read logs, or roll back without SSH access to the node.
>
> A second engineer trying to reproduce a bug locally asked: *"Which environment variable controls the claims timeout?"* Nobody knew — it was set manually on the old VM and never documented.
>
> **Goal:** Learn raw Kubernetes primitives so the team can deploy, inspect, debug, and configure applications without touching the underlying infrastructure.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing YAML manifests |
| **Agents** | `Explore` to navigate existing manifests; none needed for new YAML |
| **Key tools** | `Write`, `Edit`, `Bash` (kubectl commands), `WebFetch` (Kubernetes docs) |
| **Watch for** | Paste full `kubectl describe pod` output when debugging — not just the error line |
| **Est. tokens** | ~70–100K |
| **Est. cost** | ~$0.45–0.65 |

---

# Phase 3 — Helm & Microservices

## Business Context

> **CoverLine — Series A closed, 1,000 covered members**
> The engineering team grew to 4 people. Claims processing, the member portal, and the provider network API all live in a single repository and deploy as one unit. Deploying a one-line fix to the claims service requires redeploying the entire app — including the portal and provider API — causing unnecessary downtime.
>
> A new engineer joining the team asked how to deploy just the claims service to staging. The answer involved editing raw YAML files by hand, changing image tags manually, and hoping nothing was missed. Two weeks later, a misconfigured YAML brought down the provider API in production for 35 minutes.
>
> The database is a single PostgreSQL instance running directly on a VM. Redis doesn't exist yet — every API call hits the database, including repeated lookups for the same provider data.
>
> **Goal:** Split the app into independently deployable services packaged as Helm charts. Add PostgreSQL and Redis as proper Kubernetes workloads.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing Helm chart templates |
| **Agents** | `Plan` before designing the Helm chart structure — especially for multi-service layout |
| **Key tools** | `Write`, `Edit`, `Bash` (helm install/upgrade/template), `WebFetch` (Bitnami chart docs) |
| **Watch for** | Use `helm template` to render charts locally before deploying — catches templating errors early |
| **Est. tokens** | ~180–230K (Helm templating + StatefulSet debugging is token-heavy) |
| **Est. cost** | ~$1.20–1.55 |

---

# Phase 4 — CI/CD Pipelines

## Business Context

> **CoverLine — 5,000 covered members, 5 engineers**
> Deploying a new feature takes half a day. An engineer manually builds the Docker image on their laptop, pushes it to the registry, edits the Helm values file with the new image tag, and runs `helm upgrade`. Last month, a deployment went to production with a broken image because the engineer forgot to run tests first. The week before, two engineers deployed conflicting versions of the claims service at the same time.
>
> The team agreed to ship a new claims dashboard by end of sprint. They missed the deadline because deployment logistics consumed two days of engineering time.
>
> **Goal:** Automate the entire build, test, and delivery process so engineers focus on code, not deployments.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `update-config` if adding new env vars to settings |
| **Agents** | `Explore` to inspect existing Helm charts before writing the pipeline |
| **Key tools** | `Write` (workflow YAML), `Edit`, `WebFetch` (GitHub Actions / GitLab CI docs), `Bash` (test pipeline locally with `act`) |
| **Watch for** | Share the full pipeline run log on failure — GitHub Actions truncates errors in the UI |
| **Est. tokens** | ~120–160K |
| **Est. cost** | ~$0.80–1.05 |

---

# Phase 5 — GitOps with ArgoCD

## Business Context

> **CoverLine — 15,000 covered members, Series A**
> CI/CD is in place — builds are automated. But deployments still require an engineer to manually run `helm upgrade` after the pipeline completes. On a Friday evening, a junior engineer pushed a hotfix directly to the production cluster from their laptop to unblock a client. The fix worked, but the cluster was now out of sync with what was in Git. Nobody noticed until the next deploy overwrote the change and broke claims processing again.
>
> An insurance regulator asked: *"Can you show us an audit trail of every change made to your production environment?"* The answer was a mix of Slack messages, terminal history, and memory.
>
> **Goal:** Make Git the single source of truth for production. Every change to the cluster must come from a Git commit — no exceptions.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase |
| **Agents** | None needed — ArgoCD Application YAML is compact |
| **Key tools** | `Write` (Application YAML), `Bash` (argocd CLI + kubectl), `WebFetch` (ArgoCD docs) |
| **Watch for** | Share `argocd app get <name>` output when debugging sync failures — it contains the full diff |
| **Est. tokens** | ~70–100K |
| **Est. cost** | ~$0.45–0.65 |

---

# Phase 6 — Observability Stack

## Business Context

> **CoverLine — Series B, 50,000 covered members**
> On a Tuesday morning, the claims processing service started returning errors for 12% of requests. Members couldn't submit claims. The engineering team found out 4 hours later when the support inbox was full. By the time they identified the cause — a memory leak introduced in the previous release — the SLA had been breached and two enterprise clients had escalated to account management.
>
> The post-mortem revealed the team had no metrics, no alerting, and no centralized logs. Debugging meant SSH-ing into nodes and grepping log files one pod at a time.
>
> A new enterprise client's IT team asked: *"What is your mean time to detect an incident?"* The honest answer was "whenever a customer tells us."
>
> **Goal:** Know about production problems before customers do.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing PromQL alert rules |
| **Agents** | `Plan` for designing the full observability stack before installing — Prometheus, Grafana, and Loki have many config options |
| **Key tools** | `Write` (PrometheusRule, Grafana dashboard JSON), `Bash` (helm install, kubectl port-forward), `WebFetch` (PromQL docs, kube-prometheus-stack docs) |
| **Watch for** | This phase is memory-heavy — if pods are OOMKilled, share `kubectl top nodes` output. Prometheus scrape config errors are silent by default — check Prometheus UI targets page |
| **Est. tokens** | ~200–260K (most config-heavy phase after Capstone) |
| **Est. cost** | ~$1.35–1.75 |

> **Certification Milestone: Prometheus Certified Associate (PCA)**
> After completing Phase 6 you have the hands-on knowledge for the **Prometheus Certified Associate (PCA)** exam — covers PromQL, alerting, recording rules, Alertmanager, and Grafana dashboards. [Study guide](https://training.linuxfoundation.org/certification/prometheus-certified-associate/)

---

# Phase 7 — Secrets Management (Vault)

## Business Context

> **CoverLine — 100,000 covered members, enterprise sales pipeline**
> CoverLine is closing its first large enterprise deal — a 5,000-employee company. The enterprise client's security team ran a vendor assessment and flagged a critical finding: database credentials were stored as plaintext environment variables in the Kubernetes deployment manifests, which are committed to Git. Anyone with read access to the repository had access to the production database.
>
> Two days later, a developer accidentally included a `.env` file in a commit. GitHub's secret scanning flagged it, but the credentials had already been exposed in the git history for 3 hours. The database password had to be rotated immediately, causing 40 minutes of unplanned downtime.
>
> The enterprise deal was put on hold pending a security remediation plan.
>
> **Goal:** Remove all secrets from code and environment variables. Centralise secret management with dynamic, short-lived credentials.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing Vault policies |
| **Agents** | `Plan` before setting up Kubernetes auth — the Vault + K8s trust chain has several steps that must be done in order |
| **Key tools** | `Write` (Vault policies, agent config), `Bash` (vault CLI commands), `WebFetch` (Vault K8s auth docs) |
| **Watch for** | Vault errors are often cryptic — share the full `vault status` and `kubectl logs` of the Vault agent injector when debugging injection failures |
| **Est. tokens** | ~130–170K |
| **Est. cost** | ~$0.85–1.15 |

---

# Phase 8 — Advanced Kubernetes

## Business Context

> **CoverLine — 250,000 covered members, high growth**
> Every year in November, companies renew their employee benefits — open enrollment. In 72 hours, 40,000 members log in simultaneously to review their coverage, update dependents, and submit claims. Last enrollment period, the app became unresponsive after 20 minutes of peak traffic. The member portal returned 504 errors. Claims couldn't be submitted. HR managers from three enterprise clients called account management demanding answers.
>
> The root cause: the cluster had a fixed 3-node configuration with no autoscaling. The claims service had no resource limits — one runaway pod consumed all CPU on a node, starving every other workload. There was no pod disruption budget, so a routine node upgrade during the incident window took down 2 of 3 pods simultaneously.
>
> **Goal:** Build a cluster that handles 10x traffic spikes automatically, recovers from node failures gracefully, and never degrades due to a single misbehaving workload.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing HPA and PDB configs |
| **Agents** | `Explore` to review existing deployments before adding autoscaling — resource limits must exist before HPA works |
| **Key tools** | `Write` (HPA, PDB YAML), `Bash` (kubectl top, load testing with `k6` or `hey`), `WebFetch` (HPA docs) |
| **Watch for** | HPA won't scale without metrics-server installed — verify with `kubectl get hpa` showing `<unknown>` targets. Share full output |
| **Est. tokens** | ~110–150K |
| **Est. cost** | ~$0.75–1.00 |

> **Certification Milestone: CKAD + CKA**
> After completing Phase 8 you have the practical knowledge for two Kubernetes certifications — attempt them in order:
> - **Certified Kubernetes Application Developer (CKAD)** — focuses on deploying and configuring applications: Pods, Deployments, Services, ConfigMaps, Helm, resource limits. Easier than CKA, good warm-up. [Study guide](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
> - **Certified Kubernetes Administrator (CKA)** — covers cluster administration, networking, storage, RBAC, troubleshooting, and upgrades. Attempt after CKAD. [Study guide](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)
>
> Complete both before moving to Phase 9.

---

# Phase 9 — Data Platform (Airflow + dbt)

## Business Context

> **CoverLine — 500,000 covered members, data team hired**
> CoverLine hired its first Head of Data and two actuaries. Their job: model claims risk, detect fraud, and forecast costs by employer segment. Every analysis requires data from the production PostgreSQL database — claims history, member demographics, provider billing codes.
>
> The current process: a developer manually exports CSVs from the database every Monday morning and uploads them to Google Sheets. The actuarial team then cleans the data by hand in Excel before running their models. Last month, an export had a bug that silently duplicated 8,000 claim records. The fraud model trained on this data flagged legitimate claims as suspicious for three weeks before anyone noticed.
>
> The CEO wants a live dashboard showing claims cost per employer, loss ratio by coverage type, and fraud detection alerts. The data team says it will take 6 months with the current setup.
>
> **Goal:** Build an automated, reliable data pipeline that delivers clean, transformed claims data to BigQuery every day — no manual exports, no Excel cleaning.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing Airflow DAGs and dbt models |
| **Agents** | `Plan` before designing the DAG and dbt model structure — this is the most architecturally complex phase. `general-purpose` agent for researching Airflow + BigQuery integration patterns |
| **Key tools** | `Write` (DAGs, dbt models, schemas), `Edit`, `Bash` (airflow CLI, dbt run/test), `WebFetch` (Airflow docs, dbt-bigquery adapter docs) |
| **Watch for** | Airflow DAG import errors are silent — always check the Airflow UI "Import Errors" tab. Share full dbt run output on failure, not just the last line |
| **Est. tokens** | ~250–320K (most Python-heavy phase — DAGs + dbt models + BigQuery schemas) |
| **Est. cost** | ~$1.65–2.15 |

---

> **Certification Milestone: Google Cloud Professional Cloud DevOps Engineer**
> After completing Phase 9 you have covered the full scope of the **Google Cloud Professional Cloud DevOps Engineer** exam — CI/CD pipelines, GKE, GitOps, observability (Cloud Operations Suite / Prometheus), SRE practices, and data pipelines on GCP. This is one of the most relevant certifications for Platform Engineering roles on GCP. [Study guide](https://cloud.google.com/learn/certification/cloud-devops-engineer)

---

# Phase 10 — Security & Production Hardening

## Business Context

> **CoverLine — 1,000,000 covered members, enterprise**
> CoverLine is now processing health insurance claims for 1 million people across 200 corporate clients. Two major enterprise clients — a bank and a hospital network — require ISO 27001 certification as a contractual condition. The ISO audit starts in 6 weeks.
>
> The auditor's preliminary questionnaire reveals several gaps: pods run as root, there are no network policies restricting service-to-service communication (meaning a compromised claims pod could reach the database directly), container images are never scanned for CVEs, and there is no audit log of who accessed what in the cluster.
>
> One finding is critical: a misconfigured RBAC role gives the CI/CD service account cluster-admin privileges — effectively giving the pipeline root access to everything.
>
> **Goal:** Harden the platform to pass the ISO 27001 audit. Implement least privilege, network isolation, image provenance, and audit logging.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase, `simplify` after writing NetworkPolicy and RBAC YAML |
| **Agents** | `Explore` to audit existing RBAC and service account configs before writing new policies |
| **Key tools** | `Write` (NetworkPolicy, RBAC), `Bash` (trivy/grype scan commands, kubectl auth can-i), `WebFetch` (CIS Kubernetes Benchmark) |
| **Watch for** | NetworkPolicy is additive — a missing policy is not the same as an allow-all. Test with `kubectl exec` + curl to verify policies work as expected |
| **Est. tokens** | ~110–150K |
| **Est. cost** | ~$0.75–1.00 |

---

# Phase 10b — CKS Exam Preparation (Certified Kubernetes Security Specialist)

## Business Context

> **CoverLine — 1,000,000 covered members, security certification**
> Following the ISO 27001 audit, the engineering team formalised its Kubernetes security posture. The security team decides to pursue the CKS certification to validate the team's knowledge and prepare for a future SOC 2 Type II audit. The challenges in this phase are drawn directly from real findings in production security reviews of Kubernetes clusters at scale.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at end of phase |
| **Agents** | `general-purpose` agent for researching specific CKS topics (AppArmor syntax, seccomp profiles, OPA Gatekeeper policies) — these are niche and benefit from web search |
| **Key tools** | `Write` (AppArmor profiles, Falco rules, Kyverno policies), `Bash` (kube-bench, kubectl), `WebFetch` (Kubernetes security docs, Falco docs) |
| **Watch for** | CKS exam is time-pressured — use Claude to understand concepts, but practice commands manually without assistance to build speed |
| **Est. tokens** | ~200–270K (many new security tools with complex configs) |
| **Est. cost** | ~$1.35–1.80 |

> **Certification Milestone: CKS**
> After completing Phase 10b, attempt the **Certified Kubernetes Security Specialist (CKS)** exam. The exam is performance-based (2 hours, live cluster). Practice speed — you will not have time to read docs for every answer.

---

# Phase 11 — Capstone Project

## Business Context

> **CoverLine — 2,000,000+ covered members, Series C**
> CoverLine is now one of the largest digital health insurers in Europe. The platform processes 50,000 claims per day across 500 corporate clients in 3 countries. The engineering team has grown to 40 engineers across 6 product teams. A new CTO joined from a large-scale platform background and ran a full infrastructure review.
>
> The verdict: the platform works, but it was built phase by phase by a small team under pressure. There is no single place to see the health of the entire system. Onboarding a new engineer still takes 3 days. Deploying to a new country requires manually duplicating infrastructure. Some services still have hardcoded config that nobody dares touch.
>
> The CTO's mandate: *"Build the platform you wish you'd had from day one."*
>
> **Goal:** Assemble every component built across phases 0–10 into a single, fully automated platform. Zero manual steps from code to production. Multi-environment. Fully observable. Secure by default.

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

## Claude Efficiency

| | |
|---|---|
| **Skills** | `/commit` at each milestone, `simplify` across all phases, `/review-pr` before merging the final PR |
| **Agents** | `Plan` to design the assembly strategy before starting — critical for avoiding conflicts between phases. `Explore` to audit all previous phase outputs before wiring them together |
| **Key tools** | All tools — this phase touches every part of the codebase |
| **Watch for** | Start with a fresh `terraform apply` and document every manual step you have to take — those are the gaps to automate. Use `Plan` agent if stuck on how to wire two components together |
| **Est. tokens** | ~350–500K (touches all phases, highest debugging surface) |
| **Est. cost** | ~$2.30–3.35 |

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

## Certification Path

| Cert | Issuer | After Phase | Focus |
|---|---|---|---|
| Terraform Associate (003) | HashiCorp | Phase 1 | IaC, state, modules |
| Google Cloud ACE | Google | Phase 1 | GCP fundamentals, IAM, GKE |
| Prometheus Certified Associate | CNCF / Linux Foundation | Phase 6 | Metrics, alerting, PromQL |
| CKAD | CNCF / Linux Foundation | Phase 8 | Kubernetes application deployment |
| CKA | CNCF / Linux Foundation | Phase 8 | Kubernetes cluster administration |
| GCP Professional Cloud DevOps Engineer | Google | Phase 9 | CI/CD, GKE, observability, SRE on GCP |
| CKS | CNCF / Linux Foundation | Phase 10b | Kubernetes security |

Completing all seven certifications alongside this project is equivalent to senior-level Platform Engineering experience, with industry-recognized credentials to prove it.

## Total Claude Usage Estimate

| Phase | Est. Tokens | Est. Cost |
|---|---|---|
| 0 — Foundations | 60–80K | ~$0.40–0.55 |
| 1 — Terraform | 150–200K | ~$1.00–1.35 |
| 2 — Kubernetes Core | 70–100K | ~$0.45–0.65 |
| 3 — Helm & Microservices | 180–230K | ~$1.20–1.55 |
| 4 — CI/CD | 120–160K | ~$0.80–1.05 |
| 5 — GitOps | 70–100K | ~$0.45–0.65 |
| 6 — Observability | 200–260K | ~$1.35–1.75 |
| 7 — Vault | 130–170K | ~$0.85–1.15 |
| 8 — Advanced Kubernetes | 110–150K | ~$0.75–1.00 |
| 9 — Data Platform | 250–320K | ~$1.65–2.15 |
| 10 — Security | 110–150K | ~$0.75–1.00 |
| 10b — CKS Prep | 200–270K | ~$1.35–1.80 |
| 11 — Capstone | 350–500K | ~$2.30–3.35 |
| **Total** | **~2.0–2.5M** | **~$13–18** |

> Estimates assume Claude Sonnet pricing ($3/M input tokens, $15/M output tokens) with a typical 70/30 input/output ratio. Debugging-heavy sessions will be at the higher end. The full lab costs less than a single technical book.
