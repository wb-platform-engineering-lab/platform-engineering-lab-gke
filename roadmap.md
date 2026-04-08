# Platform Engineering Lab — Roadmap

A phase-by-phase guide to building a complete, production-like platform on GKE. Each phase is grounded in a real engineering problem at **CoverLine**, a fictional digital health insurer, as it grows from 0 to 3,000,000+ members.

---

## Product Story — CoverLine

CoverLine is a B2B2C digital health insurer. Companies subscribe to offer health coverage to their employees. Members submit claims, manage their policy, and access their provider network through a web app.

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
| 2 | Early beta | 200 members | One bad deploy takes down claims processing and the member portal |
| 3 | Series A | 1,000 members | Claims, member portal, and provider API all in one repo — teams constantly blocking each other |
| 3b | Post-Series A | 2,000 members | Synchronous HTTP between services — triage slowdown cascades into claims timeouts |
| 4 | Growing | 5,000 members | 5 engineers — deploying takes half a day, releases are delayed by 2 weeks |
| 5 | Scaling | 15,000 members | Engineer pushed untested code to prod on a Friday — claims down for 2 hours |
| 5b | Scaling+ | 20,000 members | Every deploy reaches 100% of users instantly — one bad release caused a 12% error spike before anyone noticed |
| 6 | Series B | 50,000 members | Claims SLA breached — support team found out before engineering did |
| 7 | Enterprise sales | 100,000 members | GDPR audit: database credentials found in plaintext environment variables |
| 8 | High growth | 250,000 members | Open enrollment — 10x traffic spike, app unresponsive for 45 minutes |
| 8b | High growth | 300,000 members | Pentest found plaintext HTTP between all services — compromised pod can reach the database directly |
| 9 | Data team hired | 500,000 members | Actuarial team needs claims analytics in BigQuery — developers manually exporting CSVs every week |
| 10 | Enterprise | 1,000,000 members | ISO 27001 audit — need verifiable proof of least privilege, network isolation, and image provenance |
| 10b | CKS prep | 1,000,000 members | Security team formalises Kubernetes hardening ahead of certification audit |
| 10c | Backup & DR | 1,000,000 members | Enterprise client SLA requires RTO 4h / RPO 1h — no tested DR plan exists |
| 10d | Resilience | 1,000,000 members | PodDisruptionBudgets and HPA configured but never tested — node failure exercise exposed gaps |
| 10e | FinOps | 1,000,000 members | CFO asks for cost breakdown by team — no visibility into €18k/month GKE spend |
| 11 | Capstone | 2,000,000+ members | Full platform, zero manual steps, multi-region ready |
| 12 | GenAI & Agentic | 3,000,000+ members | AI claims triage assistant cuts manual review by 60% |

---

## Prerequisites

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

**GCP Requirements:** A GCP account with billing enabled and Owner or Editor IAM role on the project.

**Always run `terraform destroy` after each session to avoid unnecessary charges.**

### Estimated Costs per Phase

> Costs assume spot nodes (`e2-standard-2`) in `us-central1`. Destroy infrastructure between sessions.

| Phase | New GCP Services | Est. Cost/Day | Notes |
|---|---|---|---|
| 0 | None (local Docker only) | $0 | No cloud resources |
| 1 | GKE cluster, VPC, NAT, BigQuery | ~$4–6 | GKE mgmt fee $0.10/hr + 3 spot nodes ~$1.50/day + NAT ~$0.50/day |
| 2 | None (uses Phase 1 cluster) | ~$4–6 | Same cluster |
| 3 | Persistent disks for PostgreSQL + Redis | ~$5–7 | PVCs add ~$0.04/GB/month |
| 3b | Kafka brokers (3 pods, memory-heavy) | ~$7–10 | Strimzi brokers need ~512MB RAM each — may trigger autoscale to 4 nodes |
| 4 | Artifact Registry | ~$5–7 | Registry storage ~$0.10/GB/month, negligible at lab scale |
| 5 | None (ArgoCD runs on cluster) | ~$5–7 | Same cluster |
| 6 | Additional nodes for Prometheus/Loki | ~$7–10 | Observability stack is memory-heavy, may trigger autoscale |
| 7 | Compute Engine VM (e2-medium) for Vault | ~$8–12 | VM ~$1–2/day on top of cluster cost; no GKE Vault pods |
| 8 | Temporary extra nodes during load tests | ~$8–12 | Autoscaler adds nodes under simulated load |
| 9 | Airflow workers, BigQuery queries | ~$8–12 | Airflow needs more CPU/memory |
| 10 | None | ~$7–10 | Same cluster |
| 10b | None | ~$7–10 | Same cluster |
| 10c | GCS buckets for backups (~$0.02/GB/month) | ~$7–10 | Velero + pg_dump + Vault snapshots stored in GCS — negligible storage cost at lab scale |
| 11 | Everything running together | ~$15–25 | Full platform: all services active simultaneously |
| 12 | Claude API calls (~500K tokens/day in testing) | ~$5–8 + ~$1–3 API | Cluster cost unchanged; Claude API usage billed separately |

**Free tier:** New GCP accounts get **$300 in free credits** — enough to complete the entire lab if you destroy resources between sessions.

---

# Phase 0 — Foundations

## Business Context

> **CoverLine — 2 founders, 0 members**
> The two founders built a proof-of-concept claims submission API and member portal. The backend runs on one laptop and the frontend on another. Every investor demo requires both founders to be in the same room. There is no shared development environment, no versioning, and no way to onboard a third engineer without spending a day on setup.
>
> **Goal:** Make the app run consistently on any machine using containers.

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

## ADRs

* `adr-004-flask-backend.md` — Why Python Flask over Node.js, Go, FastAPI
* `adr-005-docker-compose-local.md` — Why Docker Compose over Podman, Minikube, manual `docker run`

---

# Phase 1 — Cloud & Terraform (GCP)

## Business Context

> **CoverLine — Seed round closed, 50 covered members (first B2B client)**
> CoverLine signed its first corporate client — a 50-person startup. The CTO manually spun up a VM on GCP, SSH'd in, and ran `docker run` to deploy the app. Two weeks later, a colleague tried to reproduce the environment for staging and couldn't — there were no notes, no scripts, and the VM had been modified by hand a dozen times.
>
> The first enterprise prospect asked: *"How do you manage your infrastructure?"* The answer of "we SSH in and run commands" ended the conversation.
>
> **Goal:** Replace manual VM setup with reproducible, version-controlled infrastructure using Terraform.

## Topics

* Terraform basics (providers, state, modules)
* GCP fundamentals (IAM, VPC, Compute)
* Multi-environment setup (dev/staging/prod)
* Cost optimization (preemptible nodes, autoscaling, committed use discounts)

## Challenges

1. Create a GCP project using Terraform
2. Create a VPC with public and private subnets and firewall rules
3. Provision a GKE cluster
4. Configure kubectl access
5. Structure Terraform for multiple environments (dev/staging/prod) using workspaces or separate state files
6. Configure preemptible/spot nodes to minimize cost
7. **Cost governance — automated nightly destroy (two approaches):**
   * **GitHub Actions:** Create `.github/workflows/auto-destroy.yml` — scheduled workflow that runs `terraform destroy` every night at 8 PM UTC. Controlled via a `AUTO_DESTROY_ENABLED` repository variable
   * **Cloud Run Job (bonus):** Build a Docker image with Terraform + gcloud installed, push it to Artifact Registry, and trigger it via Cloud Scheduler on the same cron. This is the GCP-native production equivalent
8. **Enable Workload Identity on the GKE cluster** — required for pods to authenticate to GCP services (KMS, Secret Manager) without JSON keys. Add `workload_identity_config` to the GKE module and `workload_metadata_config { mode = "GKE_METADATA" }` on the node pool.

## Expected Outcome

Reusable Terraform modules for networking, Kubernetes cluster, and BigQuery dataset. Deployable to at least two environments (dev and staging) with environment-specific variables. Nightly auto-destroy in place to prevent runaway costs. Workload Identity enabled on the cluster — required for Phase 7 (Vault KMS auto-unseal) and Phase 10 (Falco, OPA).

## ADRs

* `adr-001-gke-over-self-managed.md` — Why GKE over EKS, AKS, kubeadm
* `adr-002-spot-nodes.md` — Why spot nodes over on-demand for dev/staging
* `adr-003-vpc-native-cluster.md` — Why VPC-native networking over routes-based
* `adr-006-bigquery.md` — Why BigQuery over Snowflake, Redshift, self-hosted

> **Cost reminder:** Run `terraform destroy` after completing this phase to avoid ongoing GCP charges.

---

> **Certification Milestone: Terraform Associate + Google Cloud ACE**
> After completing Phase 1 you have the hands-on knowledge for two certifications:
> - **HashiCorp Certified: Terraform Associate (003)** — covers providers, state, modules, workspaces, and CLI commands. [Study guide](https://developer.hashicorp.com/terraform/tutorials/certification-003)
> - **Google Cloud Associate Cloud Engineer (ACE)** — covers GCP core services, IAM, VPC, GKE, and CLI. [Study guide](https://cloud.google.com/learn/certification/cloud-engineer)

---

# Phase 2 — Kubernetes Core

## Business Context

> **CoverLine — 200 covered members, early beta**
> CoverLine now has 4 corporate clients. The app runs as a single container on GKE. During a routine deploy, the container crashed mid-startup. For 18 minutes, members trying to submit claims saw a blank page — no error, no fallback. The on-call engineer had no way to inspect the running state, read logs, or roll back without SSH access to the node.
>
> A second engineer trying to reproduce a bug locally asked: *"Which environment variable controls the claims timeout?"* Nobody knew — it was set manually on the old VM and never documented.
>
> **Goal:** Learn raw Kubernetes primitives so the team can deploy, inspect, debug, and configure applications without touching the underlying infrastructure.

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

## Business Context

> **CoverLine — Series A closed, 1,000 covered members**
> The engineering team grew to 4 people. Claims processing, the member portal, and the provider network API all live in a single repository and deploy as one unit. Deploying a one-line fix to the claims service requires redeploying the entire app — including the portal and provider API — causing unnecessary downtime.
>
> A new engineer joining the team asked how to deploy just the claims service to staging. The answer involved editing raw YAML files by hand, changing image tags manually, and hoping nothing was missed. Two weeks later, a misconfigured YAML brought down the provider API in production for 35 minutes.
>
> The database is a single PostgreSQL instance running directly on a VM. Redis doesn't exist yet — every API call hits the database, including repeated lookups for the same provider data.
>
> **Goal:** Split the app into independently deployable services packaged as Helm charts. Add PostgreSQL and Redis as proper Kubernetes workloads.

## Topics

* Helm charts and templating
* Values.yaml and environment configs
* StatefulSets and PersistentVolumeClaims
* Kubernetes-hosted databases and caching

## Challenges

1. Convert a raw deployment into a Helm chart
2. Deploy a microservices app (frontend Node.js + backend Python API)
3. Use Helm values for environment configs
4. Version and upgrade releases
5. Deploy PostgreSQL via Helm (Bitnami chart) — backend connects to it
6. Deploy Redis via Helm (Bitnami chart) — backend uses it for caching
7. Connect the Python backend to both PostgreSQL and Redis

> **Note:** PostgreSQL and Redis are deployed as Kubernetes StatefulSets in this phase to practice PVCs and Helm. In production these would be Cloud SQL and Cloud Memorystore (managed GCP services) to reduce operational overhead.

## ADRs

* `adr-007-postgresql.md` — Why PostgreSQL over MySQL, MongoDB, Cloud SQL
* `adr-008-redis.md` — Why Redis over Memcached, Cloud Memorystore
* `adr-009-kubernetes-hosted-vs-managed.md` — Why Helm-deployed databases over managed GCP services for this lab

---

# Phase 3b — Event-Driven Architecture (Kafka)

## Business Context

> **CoverLine — 2,000 covered members, post-Series A**
> Claims volume doubled in 90 days. The claims service calls the triage service synchronously over HTTP — when triage is under load, response times spike and claims submission starts timing out. On a busy Monday morning, a 30-second triage delay caused the claims API to return 504s for 12 minutes. 400 members couldn't submit claims.
>
> The root cause: tight coupling. If triage is slow, claims is slow. If triage crashes, claims crashes with it.
>
> **Goal:** Replace synchronous HTTP calls between services with an event-driven pipeline. Claims publishes an event. Triage consumes it. Neither service knows about the other.

## Topics

* Event-driven architecture — producers, consumers, topics, partitions, consumer groups
* Kafka on Kubernetes via Strimzi operator (industry standard) or Redpanda (simpler, Kafka-compatible)
* Kubernetes operators — how they extend the Kubernetes API
* Dead letter queues — handling failed message processing
* Exactly-once vs at-least-once delivery semantics

## Challenges

1. **Deploy Kafka** — Install the Strimzi operator via Helm and provision a 3-broker Kafka cluster as a Kubernetes custom resource (`Kafka` CR). Alternatively use Redpanda for a lighter setup
2. **Claims producer** — Modify the Python backend so every successful claim submission publishes a `claim.submitted` event to a `claims` topic (JSON payload: claim_id, member_id, amount, timestamp)
3. **Triage consumer** — Write a Python consumer service that reads from the `claims` topic, simulates triage logic (approve / review / reject), and writes the result back to a `claims.triage` topic
4. **Dead letter queue** — Route failed triage events to a `claims.dlq` topic. Add a Prometheus alert when DLQ depth exceeds 10 messages
5. **Kafka UI** — Deploy Kafka UI (or Redpanda Console) to browse topics, inspect messages, and monitor consumer group lag
6. **End-to-end test** — Submit 100 seeded claims via the API, verify all 100 appear in the triage topic, and measure consumer lag under load

## Event Flow

```
Member submits claim
    └── Claims API (Python)
            └── Publishes → Kafka topic: claims.submitted
                    └── Triage Consumer (Python)
                            ├── Success → Kafka topic: claims.triage
                            └── Failure → Kafka topic: claims.dlq
                                    └── Prometheus alert: dlq_depth > 10
```

## Expected Outcome

* Kafka cluster running on GKE with 3 brokers
* Producer and consumer services deployed as Kubernetes Deployments
* DLQ in place with a Prometheus alert
* Claims and triage services fully decoupled — triage can be taken down without affecting claim submission

## ADRs

* `adr-026-kafka-strimzi-vs-redpanda.md` — Why Strimzi (or Redpanda) for Kafka on Kubernetes

---

# Phase 4 — CI/CD Pipelines

## Business Context

> **CoverLine — 5,000 covered members, 5 engineers**
> Deploying a new feature takes half a day. An engineer manually builds the Docker image on their laptop, pushes it to the registry, edits the Helm values file with the new image tag, and runs `helm upgrade`. Last month, a deployment went to production with a broken image because the engineer forgot to run tests first. The week before, two engineers deployed conflicting versions of the claims service at the same time.
>
> The team agreed to ship a new claims dashboard by end of sprint. They missed the deadline because deployment logistics consumed two days of engineering time.
>
> **Goal:** Automate the entire build, test, and delivery process so engineers focus on code, not deployments.

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

## ADRs

* `adr-010-github-actions-vs-gitlab-ci.md` — Why GitHub Actions (or GitLab CI) over the alternative
* `adr-011-artifact-registry-vs-dockerhub.md` — Why GCP Artifact Registry over Docker Hub or GCR

---

# Phase 5 — GitOps with ArgoCD

## Business Context

> **CoverLine — 15,000 covered members, Series A**
> CI/CD is in place — builds are automated. But deployments still require an engineer to manually run `helm upgrade` after the pipeline completes. On a Friday evening, a junior engineer pushed a hotfix directly to the production cluster from their laptop to unblock a client. The fix worked, but the cluster was now out of sync with what was in Git. Nobody noticed until the next deploy overwrote the change and broke claims processing again.
>
> An insurance regulator asked: *"Can you show us an audit trail of every change made to your production environment?"* The answer was a mix of Slack messages, terminal history, and memory.
>
> **Goal:** Make Git the single source of truth for production. Every change to the cluster must come from a Git commit — no exceptions.

## Topics

* ArgoCD architecture
* Declarative deployments
* Drift detection and reconciliation

## Challenges

1. Install ArgoCD in the cluster
2. Connect a Git repo
3. Deploy Helm charts via ArgoCD
4. Enable auto-sync
5. Simulate drift and recovery

## ADRs

* `adr-001-argocd-over-flux.md` — Why ArgoCD over Flux for GitOps

---

# Phase 5b — Progressive Delivery (Argo Rollouts)

## Business Context

> **CoverLine — 20,000 covered members**
> After adopting GitOps, the team ships faster — but every deploy is still all-or-nothing. A bad release of the claims service reaches 100% of members instantly. The SRE team wants to ship to 10% of traffic first, watch the error rate for 5 minutes, and only proceed if metrics are healthy. One release caused a 12% increase in 5xx errors that went undetected for 18 minutes before someone checked Grafana manually.
>
> **Goal:** Deploy with confidence — canary releases that promote automatically on green metrics and roll back automatically on errors.

## Topics

* Argo Rollouts controller
* Canary deployments with traffic splitting
* Analysis templates (PromQL success rate gates)
* Automatic rollback on metric thresholds
* Blue/green deployments

## Challenges

1. Install Argo Rollouts on the cluster
2. Convert the `coverline-backend` Deployment to a Rollout resource
3. Define a canary strategy: 10% → 30% → 100% with 2-minute pause between steps
4. Create an AnalysisTemplate using Prometheus to gate promotion (error rate < 1%)
5. Simulate a bad deploy — verify automatic rollback fires before 100% traffic
6. Integrate with ArgoCD — Rollouts as the deployment mechanism within the GitOps flow

## ADRs

* `adr-023-argo-rollouts-over-flagger.md` — Why Argo Rollouts over Flagger for progressive delivery

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

## Stack

* Prometheus (metrics)
* Grafana (dashboards)
* Loki (logs)

## Challenges

1. Install kube-prometheus-stack
2. Create dashboards for CPU / memory and request latency
3. Centralize logs with Loki
4. Create alerts (e.g., high error rate, memory pressure)

## ADRs

* `adr-012-kube-prometheus-stack.md` — Why kube-prometheus-stack over standalone Prometheus + Grafana installs
* `adr-013-loki-vs-elasticsearch.md` — Why Loki over Elasticsearch/OpenSearch for log aggregation

---

> **Certification Milestone: Prometheus Certified Associate (PCA)**
> After completing Phase 6 you have the hands-on knowledge for the **PCA** exam — covers PromQL, alerting, recording rules, Alertmanager, and Grafana dashboards. [Study guide](https://training.linuxfoundation.org/certification/prometheus-certified-associate/)

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

## Topics

* Vault basics (KV v2, dynamic secrets, policies)
* Vault on a dedicated VM — avoiding the circular dependency with GKE
* GCP KMS auto-unseal
* Kubernetes auth and the Vault Agent Injector
* Dynamic PostgreSQL credentials

## Challenges

1. Provision a Vault VM with Terraform (Compute Engine, no external IP, IAP SSH access)
2. Install and configure Vault with Ansible (Raft storage, GCP KMS auto-unseal)
3. Deploy only the Vault Agent Injector in GKE (Helm, `server.enabled: false`)
4. Initialize Vault, enable Kubernetes auth, store application secrets
5. Inject secrets into pods via Vault Agent annotations
6. Enable dynamic PostgreSQL credentials — no more static passwords
7. Integrate Vault with the CI/CD pipeline from Phase 4

## ADRs

* `adr-014-vault-over-k8s-secrets.md` — Why HashiCorp Vault over native Kubernetes Secrets or GCP Secret Manager

---

# Phase 8 — Advanced Kubernetes

## Business Context

> **CoverLine — 250,000 covered members, high growth**
> Every year in November, companies renew their employee benefits — open enrollment. In 72 hours, 40,000 members log in simultaneously to review their coverage, update dependents, and submit claims. Last enrollment period, the app became unresponsive after 20 minutes of peak traffic. The member portal returned 504 errors. Claims couldn't be submitted. HR managers from three enterprise clients called account management demanding answers.
>
> The root cause: the cluster had a fixed 3-node configuration with no autoscaling. The claims service had no resource limits — one runaway pod consumed all CPU on a node, starving every other workload. There was no pod disruption budget, so a routine node upgrade during the incident window took down 2 of 3 pods simultaneously.
>
> **Goal:** Build a cluster that handles 10x traffic spikes automatically, recovers from node failures gracefully, and never degrades due to a single misbehaving workload.

## Topics

* HPA (autoscaling)
* Resource limits and requests
* Pod disruption budgets
* Cluster autoscaler and node auto-provisioning

## Challenges

1. Configure HPA and cluster autoscaler
2. Simulate load and observe scale-out
3. Set resource limits and tune performance
4. Configure scale-to-zero for non-production environments

## ADRs

* `adr-015-hpa-over-keda.md` — Why native HPA over KEDA for autoscaling in this lab

---

> **Certification Milestone: CKAD + CKA**
> After completing Phase 8 you have the practical knowledge for two Kubernetes certifications — attempt them in order:
> - **Certified Kubernetes Application Developer (CKAD)** — focuses on deploying and configuring applications: Pods, Deployments, Services, ConfigMaps, Helm, resource limits. [Study guide](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
> - **Certified Kubernetes Administrator (CKA)** — covers cluster administration, networking, storage, RBAC, troubleshooting, and upgrades. Attempt after CKAD. [Study guide](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)

---

# Phase 8b — Service Mesh (Istio)

## Business Context

> **CoverLine — 300,000 covered members**
> The security team ran a penetration test on the internal cluster network. They found that a compromised claims pod could open a direct TCP connection to the PostgreSQL database — no authentication, no encryption, no audit trail inside the cluster. All traffic between services was plaintext HTTP.
>
> A second finding: the team has no visibility into which service is calling which, how long each call takes, or where latency originates in a chain of 5+ services. Debugging a slow `/claims` response means reading logs from 4 different pods manually.
>
> **Goal:** Enforce mutual TLS between all services automatically. Get distributed tracing without changing application code.

## Topics

* Istio architecture (control plane / data plane, Envoy sidecar)
* mTLS — automatic encryption and authentication between pods
* Traffic management — canary weights, circuit breakers, retries, timeouts
* Distributed tracing with Jaeger
* Observability — Istio metrics in Prometheus, service graph in Kiali

## Challenges

1. Install Istio on the cluster (istioctl or Helm)
2. Enable sidecar injection for the `default` namespace
3. Verify mTLS is enforced between `coverline-backend` and `postgresql` using `istioctl authn tls-check`
4. Configure a VirtualService and DestinationRule for the backend (retries, 5s timeout)
5. Deploy Jaeger — trace a full `/claims` request through frontend → backend → PostgreSQL
6. Enable Kiali — visualize the live service graph
7. Simulate a failing service — verify circuit breaker opens and returns a fallback

## ADRs

* `adr-024-istio-over-linkerd.md` — Why Istio over Linkerd, Consul Connect for the service mesh

---

# Phase 9 — Data Platform (Airflow + dbt)

## Business Context

> **CoverLine — 500,000 covered members, data team hired**
> CoverLine hired its first Head of Data and two actuaries. Every analysis requires data from the production PostgreSQL database. The current process: a developer manually exports CSVs every Monday morning and uploads them to Google Sheets. The actuarial team then cleans the data by hand in Excel before running their models. Last month, an export had a bug that silently duplicated 8,000 claim records. The fraud model trained on this data flagged legitimate claims as suspicious for three weeks before anyone noticed.
>
> **Goal:** Build an automated, reliable data pipeline that delivers clean, transformed claims data to BigQuery every day — no manual exports, no Excel cleaning.

## Stack

* Airflow (orchestration)
* dbt (transformations)
* BigQuery (data warehouse)

## Challenges

1. Deploy Airflow on Kubernetes
2. Create a DAG for the ETL pipeline
3. Use dbt for transformations
4. Store results in BigQuery

## ADRs

* `adr-016-airflow-over-prefect.md` — Why Apache Airflow over Prefect, Dagster for orchestration
* `adr-017-dbt-transformations.md` — Why dbt over custom SQL scripts or Spark for transformations

---

> **Certification Milestone: Google Cloud Professional Cloud DevOps Engineer**
> After completing Phase 9 you have covered the full scope of the **GCP Professional Cloud DevOps Engineer** exam — CI/CD pipelines, GKE, GitOps, observability, SRE practices, and data pipelines on GCP. [Study guide](https://cloud.google.com/learn/certification/cloud-devops-engineer)

---

# Phase 10 — Security & Production Hardening

## Business Context

> **CoverLine — 1,000,000 covered members, enterprise**
> Two major enterprise clients require ISO 27001 certification as a contractual condition. The ISO audit starts in 6 weeks.
>
> The auditor's preliminary questionnaire reveals several gaps: pods run as root, there are no network policies restricting service-to-service communication, container images are never scanned for CVEs, and there is no audit log of who accessed what in the cluster.
>
> One finding is critical: a misconfigured RBAC role gives the CI/CD service account cluster-admin privileges — effectively giving the pipeline root access to everything.
>
> **Goal:** Harden the platform to pass the ISO 27001 audit. Implement least privilege, network isolation, image provenance, and audit logging.

## Topics

* RBAC and least privilege
* NetworkPolicy
* Image scanning (Trivy or Grype)
* Kubernetes audit logs

## Challenges

1. Restrict pod communication with NetworkPolicy
2. Apply least privilege IAM and service account bindings
3. Scan container images (Trivy or Grype)
4. Enable and review Kubernetes audit logs

## ADRs

* `adr-018-trivy-over-snyk.md` — Why Trivy (or Grype) over Snyk, Twistlock for image scanning

---

# Phase 10b — CKS Exam Preparation

## Business Context

> **CoverLine — 1,000,000 covered members, security certification**
> Following the ISO 27001 audit, the security team formalises its Kubernetes hardening posture and pursues the CKS certification ahead of a future SOC 2 Type II audit.

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

## ADRs

* `adr-019-falco-over-sysdig.md` — Why Falco over Sysdig for runtime threat detection
* `adr-020-kyverno-over-opa-gatekeeper.md` — Why Kyverno (or OPA Gatekeeper) for policy enforcement

---

> **Certification Milestone: CKS**
> After completing Phase 10b, attempt the **Certified Kubernetes Security Specialist (CKS)** exam. The exam is performance-based (2 hours, live cluster). Practice speed — you will not have time to read docs for every answer.

---

# Phase 10c — Backup & Disaster Recovery

## Business Context

> **CoverLine — 1,000,000 covered members, enterprise SLA**
> A major corporate client signs a master services agreement with a contractual RTO of 4 hours and RPO of 1 hour for claims data. Legal flags that CoverLine has no tested DR plan. The engineering team has backups in theory but has never restored from them. A tabletop exercise reveals that a full cluster loss would take 2–3 days to recover from manually.
>
> **Goal:** Implement and test a DR strategy that meets the contractual SLA.

## Topics

* GCS bucket versioning and lifecycle policies
* PostgreSQL continuous backup — WAL archiving + `pg_dump` CronJobs to GCS
* Velero — Kubernetes workload and PVC backup/restore
* Vault snapshot automation
* RTO/RPO concepts and how to measure them
* DR runbook — written, version-controlled, and tested

## Challenges

1. **PostgreSQL backup** — Deploy a Kubernetes CronJob that runs `pg_dump` nightly, uploads to GCS, and alerts via Prometheus if the job fails
2. **Restore test** — Simulate a PostgreSQL failure, restore from the latest GCS backup, and measure actual RTO
3. **Velero** — Install Velero with a GCS backend. Back up the `coverline` namespace. Delete the namespace. Restore it. Verify data integrity
4. **Vault snapshots** — Configure automated Vault snapshots to GCS on a schedule
5. **DR runbook** — Write a step-by-step runbook in `docs/runbooks/dr-recovery.md` covering cluster loss, database loss, and Vault loss. Each section must include estimated time and validation steps
6. **RTO/RPO measurement** — Run a timed DR drill. Record actual recovery time against the 4-hour contractual RTO. Document gaps

## Backup Architecture

```
PostgreSQL (nightly)
    └── pg_dump CronJob → GCS bucket (versioned, 30-day retention)

Kubernetes workloads (daily)
    └── Velero → GCS bucket (namespace snapshots)

Vault (hourly)
    └── vault operator raft snapshot → GCS bucket

Terraform state
    └── GCS backend with versioning (already in place from Phase 1)
```

## Expected Outcome

* All stateful components have automated backups running on schedule
* A tested restore procedure with measured RTO (target: < 4 hours)
* DR runbook committed to the repo at `docs/runbooks/dr-recovery.md`
* Prometheus alert firing if any backup job fails

## ADRs

* `adr-025-velero-backup.md` — Why Velero over manual `kubectl` exports or GCP-native Backup for GKE

---

# Phase 10d — Chaos Engineering (LitmusChaos)

## Business Context

> **CoverLine — 1,000,000 covered members**
> The SRE team has PodDisruptionBudgets, HPA, circuit breakers, and alerting in place. But nobody has verified they actually work under real failure conditions. During a GCP zone outage simulation exercise, the team discovered that 2 of 3 backend pods were on the same node — the PodAntiAffinity rule was configured but not enforced because the cluster didn't have enough nodes. The HPA didn't scale fast enough because the Prometheus scrape interval was too slow.
>
> The CTO's question: *"Can you prove the platform survives a node failure without an outage?"*
>
> **Goal:** Systematically inject failures in a controlled way and verify the platform's resilience guarantees hold.

## Topics

* Chaos engineering principles (Chaos Monkey, GameDays)
* LitmusChaos — pod kill, node drain, network latency, CPU stress
* Hypothesis-driven experiments: define expected system behaviour before injecting chaos
* SLO validation — confirm error budget is not consumed during experiments
* Chaos as a CI gate — run lightweight experiments on every deploy

## Challenges

1. Install LitmusChaos on the cluster
2. Run a pod-kill experiment on `coverline-backend` — verify the service remains available (HPA replaces the pod within 30s, no 5xx to users)
3. Run a node-drain experiment — verify PodDisruptionBudgets prevent total downtime
4. Inject network latency (200ms) on the backend → PostgreSQL path — verify circuit breaker opens before timeout
5. Run a CPU stress experiment — verify HPA scales out before latency SLO is breached
6. Schedule a weekly chaos GameDay: automated experiment suite that runs every Monday at 9 AM

## ADRs

* `adr-026-litmuschaos-over-chaosmonkey.md` — Why LitmusChaos over Chaos Monkey, Chaos Mesh for Kubernetes chaos engineering

---

# Phase 10e — FinOps & Cost Visibility (Kubecost)

## Business Context

> **CoverLine — 1,000,000 covered members, Series C budget review**
> The CFO asked the engineering team to break down cloud spend by product team. The answer was: "We don't know — it's one big cluster." GCP billing shows €18,000/month on GKE but nobody can say which service, which team, or which feature is responsible for what portion.
>
> Three teams are fighting over node capacity. One team's batch job runs at peak hours and starves the claims service of CPU. Nobody knows until claims latency spikes.
>
> **Goal:** Give every team visibility into what their workloads cost and enforce fair resource usage across the cluster.

## Topics

* Kubecost — cost allocation per namespace, deployment, label
* GCP billing export to BigQuery — cluster-level cost breakdown
* Cost allocation labels (team, environment, product)
* Budget alerts — GCP budget notifications when spend exceeds threshold
* Resource rightsizing — identify over-provisioned workloads

## Challenges

1. Install Kubecost on the cluster
2. Label all workloads with `team=`, `env=`, and `product=` labels
3. View cost breakdown per namespace in the Kubecost UI
4. Identify the top 3 most expensive workloads — verify resource requests match actual usage
5. Set up a GCP budget alert at 80% and 100% of the monthly budget
6. Export GCP billing to BigQuery — build a simple dbt model showing cost per phase

## ADRs

* `adr-027-kubecost-finops.md` — Why Kubecost over OpenCost, GCP-native billing for cluster cost allocation

---

# Phase 11 — Capstone Project

## Business Context

> **CoverLine — 2,000,000+ covered members, Series C**
> CoverLine is now one of the largest digital health insurers in Europe. The platform processes 50,000 claims per day across 500 corporate clients in 3 countries. The engineering team has grown to 40 engineers across 6 product teams.
>
> The new CTO ran a full infrastructure review. The verdict: the platform works, but it was built phase by phase under pressure. There is no single place to see the health of the entire system. Onboarding a new engineer still takes 3 days. Deploying to a new country requires manually duplicating infrastructure.
>
> The CTO's mandate: *"Build the platform you wish you'd had from day one."*
>
> **Goal:** Assemble every component built across phases 0–10 into a single, fully automated platform. Zero manual steps from code to production. Multi-environment. Fully observable. Secure by default.

## Requirements

* Fully automated infrastructure (Terraform)
* GitOps deployment (ArgoCD)
* Microservices (Helm)
* Observability stack (Prometheus, Grafana, Loki)
* Vault secrets (VM-based, injector in GKE)
* CI/CD pipeline
* Data pipeline (Airflow + dbt)
* Progressive delivery (Argo Rollouts)
* Service mesh (Istio — mTLS, distributed tracing)
* Internal Developer Portal (Backstage) — service catalog, self-service scaffolding, TechDocs

## Final Challenge

Deploy a production-like system with:

* Zero manual steps
* Full monitoring and alerting
* Secure secret handling
* Automated deployments
* Multi-environment promotion (dev → staging → prod)

## ADRs

* `adr-021-multi-env-promotion.md` — How dev → staging → prod promotion is implemented (branch strategy, Terraform workspaces, ArgoCD ApplicationSets)

---

# Phase 12 — GenAI & Agentic Platform

## Business Context

> **CoverLine — Series D, 3,000,000+ covered members**
> CoverLine's claims operations team is drowning. With 3M members, over 8,000 claims are submitted every day. Manual triage takes 48–72 hours and costs €4 per claim in human review time. The medical director proposes an AI triage assistant: an agentic system that reads incoming claims, queries the member's policy and history, decides whether to auto-approve, flag for review, or reject, and posts a structured explanation to the case management system.
>
> The platform team is tasked with deploying, observing, and governing this system — without touching the ML model itself.

## Topics

* Claude API + Anthropic SDK (Python)
* Agentic workflows — tool use, multi-step reasoning
* LLM observability — token usage, latency, cost tracking in Prometheus/Grafana
* Prompt management and versioning
* Rate limiting and cost controls for LLM APIs
* Airflow DAG triggering an agentic pipeline
* Structured outputs and schema validation

## Challenges

1. **Claims triage agent** — Build an agent using the Anthropic SDK that reads a claim from PostgreSQL, queries the member's policy, and returns a structured triage decision (approve / review / reject + reason)
2. **Airflow integration** — Wrap the agent in an Airflow DAG so it runs automatically on new claims batches
3. **LLM observability** — Track token usage, latency, and cost per claim in Prometheus; build a Grafana dashboard showing daily spend and p95 response times
4. **Weekly summary agent** — Agent that queries BigQuery for weekly claims trends and posts a structured report — replacing the manual CSV export from Phase 9
5. **On-call assistant** (bonus) — Agent that reads Grafana alert state, queries recent logs via Loki API, and posts a root cause hypothesis to a webhook

## Agentic Architecture

```
Airflow DAG (daily)
    └── Python operator → Claude API (claude-sonnet-4-6)
            ├── Tool: query_claim(claim_id) → PostgreSQL
            ├── Tool: get_policy(member_id) → PostgreSQL
            ├── Tool: get_claim_history(member_id) → PostgreSQL
            └── Returns: TriageDecision { decision, confidence, reason }
                    └── Write result → PostgreSQL (claims.triage table)
                    └── Emit metrics → Prometheus pushgateway
```

## Expected Outcome

* A working claims triage agent deployed as an Airflow DAG, processing real (seeded) claim data
* Grafana dashboard showing LLM cost per day, tokens per claim, and triage decision distribution
* Weekly summary agent replacing the manual reporting workflow from Phase 9

## ADRs

* `adr-023-llm-provider.md` — Why Claude (Anthropic) over OpenAI, Gemini, self-hosted Ollama
* `adr-024-agentic-framework.md` — Why raw Anthropic SDK over LangChain, LlamaIndex, CrewAI

---

## Certification Path

| Certification | Issuer | Unlocked after | Focus |
|---|---|---|---|
| Terraform Associate (003) | HashiCorp | Phase 1 | IaC, state, modules |
| Google Cloud ACE | Google | Phase 1 | GCP fundamentals, IAM, GKE |
| Prometheus Certified Associate | CNCF | Phase 6 | Metrics, alerting, PromQL |
| CKAD | CNCF | Phase 8 | Kubernetes application deployment |
| CKA | CNCF | Phase 8 | Kubernetes cluster administration |
| GCP Professional Cloud DevOps Engineer | Google | Phase 9 | CI/CD, GKE, observability, SRE |
| CKS | CNCF | Phase 10b | Kubernetes security |
