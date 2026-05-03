# Platform Engineering Principles — Before You Write a Single Manifest

> Read this before Phase 0. The phases teach you *how* to build a platform. This document explains *why* — and what you should have decided before you start.

---

## What platform engineering is (and what it isn't)

Platform engineering is the practice of building internal infrastructure products that enable application teams to ship software reliably, securely, and autonomously — without needing to understand the underlying infrastructure.

The name describes the shift from a traditional ops model to a product-oriented one:

- **Traditional ops model** — teams file tickets to request infrastructure, wait for manual provisioning, and have no self-service. The ops team is a bottleneck.
- **DevOps model** — developers take on operational responsibility. This removes the bottleneck but creates cognitive overhead: every team must understand networking, security, observability, Kubernetes, secret management, and deployment pipelines.
- **Platform engineering model** — a dedicated platform team builds a paved road that gives developers self-service access to everything they need, with security and reliability built in by default. Developers focus on their applications. The platform team focuses on the platform.

The traditional model looks like this:

```
Dev team → ticket → Ops team (manual provisioning, 2-week wait)
                                    ↑
                    (bottleneck, toil, inconsistency across services)
```

The platform engineering model looks like this:

```
Dev team → self-service portal → Platform (automated, paved road)
                ↑                         ↑
         (Backstage catalog,         (ArgoCD, Vault, Terraform,
          one-click scaffolding)      observability, security baked in)
```

**What platform engineering is not:**

- It is not building infrastructure for your own team. The platform is a product — its users are other engineering teams.
- It is not a rebranding of DevOps or SRE. Platform engineering is distinct: it builds the tooling that DevOps and SRE practices run on.
- It is not a destination. A platform team that stops iterating is a platform team whose users start working around it.

---

## The three foundational shifts

### 1. From snowflakes to paved roads

A snowflake is a manually configured, unique piece of infrastructure that no one fully understands and no one dares to modify. Paved roads are the opposite: standardised, automated, documented paths that are the easiest way to do things correctly.

The economic case is clear:

| Model | Cost per new service | Risk |
|---|---|---|
| Snowflake (manual) | High — ticket, wait, bespoke config | High — undocumented, no drift detection |
| DIY per team | Medium — each team reinvents the wheel | Medium — inconsistency across teams |
| Paved road | Low — self-service, standardised | Low — policy enforced by default |

For Kubernetes platforms, paved roads mean:
- New services are scaffolded from a template (Backstage, Phase 11)
- Every service gets observability, RBAC, NetworkPolicies, and secret injection without asking for it
- Deployment follows a single promotion pipeline (Phase 11 pipeline)

This lab builds the paved road from Phase 0 (a raw GKE cluster) to Phase 11 (a fully self-service multi-environment platform).

### 2. From reactive to proactive reliability

Traditional operations teams react to incidents. Platform engineering teams design systems so incidents are caught before they affect users, and so the blast radius when they do occur is minimised.

Proactive reliability for a Kubernetes platform means:
- Metrics and alerts exist before anyone asks for them (Phase 6)
- SLOs are defined for every service, not just reported when something breaks (Phase 11)
- Progressive delivery means a bad deploy affects 10% of traffic, not 100% (Phase 6b)
- Autoscaling means a traffic spike is handled automatically, not by an on-call engineer (Phase 8)

### 3. From access by default to least privilege by default

Early-stage platforms grant broad access because it is the fastest way to unblock developers. This creates a security debt that is expensive to pay later — especially after a compliance audit or an incident.

Platform engineering inverts the default: security controls are applied at the platform level so every service inherits them automatically:

- RBAC scopes each service account to exactly what it needs (Phase 10)
- NetworkPolicies enforce that services can only talk to their declared dependencies (Phase 10)
- Vault injects secrets at runtime — no credentials in manifests or environment variables (Phase 3 / Phase 4)
- Pod Security Standards prevent privileged containers by default (Phase 10)

When security is a platform concern rather than a per-team concern, it is consistently enforced and continuously reconciled by ArgoCD rather than remembered by humans.

---

## The platform threat model

Before building defences, know what you are defending against. The table below lists the ten most common failure modes in Kubernetes platforms — drawn from CNCF security whitepapers, CIS Kubernetes Benchmark, and post-mortems from public incidents — with the failure path, the consequence, and the phase in this lab that mitigates it.

| # | Failure | Path | Consequence | Mitigated in |
|---|---|---|---|---|
| 1 | **Hardcoded secrets in manifests** | Developer commits `DB_PASSWORD=prod123` to Git; secret is visible in repo history and CI logs forever | Credential exfiltration; impossible to remediate without rotating the credential and force-pushing history | Phase 3 (Vault), Phase 4 (Vault agent injection) |
| 2 | **Overly permissive RBAC** | Default ServiceAccount has cluster-admin; compromised pod can read all secrets in all namespaces | Full cluster compromise from a single RCE | Phase 10 (RBAC), Phase 7b (SSO with Keycloak) |
| 3 | **No network segmentation** | Any pod can reach any other pod; compromised service can make requests to internal APIs it has no business accessing | Lateral movement after initial compromise | Phase 10 (NetworkPolicies) |
| 4 | **No progressive delivery** | Bad deploy is rolled out to 100% of traffic simultaneously; 5 minutes to detection, 15 minutes to rollback | Full service outage; user-facing degradation proportional to traffic | Phase 6b (Argo Rollouts, canary) |
| 5 | **No resource limits** | Misbehaving pod consumes all node CPU/memory; other pods are evicted | Cascading failure across unrelated services on the same node | Phase 8 (HPA, resource limits, PDB) |
| 6 | **Shared cluster across environments** | A misconfigured dev deploy affects staging namespaces; a namespace-scoped RBAC bug leaks across boundaries | Environment contamination; staging tests pass on broken prod-bound config | Phase 1 (separate clusters), Phase 11 (multi-env Terraform) |
| 7 | **Manual deployment process** | Engineer SSHes into a node, runs `kubectl apply -f` with a locally modified manifest; change is untracked | Configuration drift; incident post-mortem cannot determine what changed or when | Phase 5 (ArgoCD GitOps), Phase 11 (ApplicationSets, no manual kubectl in prod) |
| 8 | **No observability before the SLO is breached** | Service degrades for 40 minutes before the on-call gets paged; by the time the dashboard loads, the cause is gone | Long MTTR; customer impact goes undetected until a user complains | Phase 6 (Prometheus, Grafana, Loki), Phase 11 (unified SLO dashboard) |
| 9 | **Undiscoverable services** | No one knows what a service does, who owns it, or how to reach it; incident response involves 6 people in a Slack thread trying to find the right person | Slow incident response; onboarding takes days; duplicated work across teams | Phase 11 (Backstage IDP) |
| 10 | **Unvetted container images** | Image pulled from an unscanned registry; known CVEs running in production undetected | RCE via documented exploit; supply chain compromise | Phase 11 CI (Trivy scan gate before deploy) |

---

## The eight platform engineering principles

### 1. The platform is a product

The platform team's users are other engineers. Like any product team, the platform team must understand user needs, prioritise based on impact, and measure success by adoption — not by uptime of internal tools.

Implications:
- A platform capability no one uses is waste, not an achievement
- The paved road must be the easiest path, not just the correct one — if it is harder than the workaround, engineers will use the workaround
- Backstage (Phase 11) is the product surface: every capability the platform exposes should be discoverable from the developer portal

**Implemented in:** Phase 11 (Backstage IDP, service catalog, self-service scaffolding).

### 2. Git is the control plane

No human runs `kubectl apply` in production. No engineer SSHes into a node. The only way to change the state of the cluster is to change the state of Git — and ArgoCD reconciles the two within minutes.

This principle has four consequences:
- Every change is code-reviewed before it affects production
- The entire history of the platform state is in git log
- Rolling back is `git revert`, not `kubectl rollout undo` from someone's laptop
- Security controls (RBAC, NetworkPolicies) cannot be bypassed by a sufficiently privileged engineer making a kubectl call — ArgoCD will restore them within 3 minutes

**Implemented in:** Phase 5 (ArgoCD), Phase 11 (ApplicationSets, security baseline as code).

### 3. Every environment is a clone, not a special case

Dev, staging, and prod should be functionally identical — same Terraform modules, same Helm charts, same deployment process. The only difference is the values passed in (cluster size, replica count, image tag).

When environments diverge:
- "It worked in staging" becomes meaningless — staging is not prod
- Debugging prod issues cannot be reproduced locally
- A new environment (a new region, a new country) requires starting from scratch

**Implemented in:** Phase 1 (Terraform modules with env dirs), Phase 11 (ArgoCD ApplicationSet matrix generator, per-env values files).

### 4. Secrets never touch Git or environment variables

A secret in Git is a secret that cannot be unread. A secret in an environment variable is a secret visible in `kubectl describe pod`, in CI logs, and in crash dumps.

The correct model:
- Secrets are stored in Vault, not in manifests or CI variables
- Vault agent injects secrets into the pod filesystem at runtime — the application reads them like a file
- Secret rotation does not require a redeploy
- Who accessed what secret, when, is auditable in Vault's audit log

**Implemented in:** Phase 3 (Vault setup, KMS unsealing), Phase 4 (Vault agent injection into Helm chart).

### 5. Observability is a platform concern, not a per-team concern

If each team is responsible for setting up their own dashboards, alerts, and log aggregation, observability will be inconsistent, incomplete, and the first thing cut under deadline pressure.

Platform observability means:
- Prometheus scrapes every pod automatically via ServiceMonitors — no opt-in required
- Every service gets the same base dashboard (RED metrics: rate, errors, duration)
- Logs are aggregated centrally in Loki — `kubectl logs` is for development, not production diagnosis
- SLO burn rate alerts exist before the first production incident

**Implemented in:** Phase 6 (kube-prometheus-stack, Loki, Promtail), Phase 11 (unified platform dashboard, SLO panels).

### 6. Progressive delivery is the default, not an advanced feature

A deployment strategy that rolls out 100% of traffic to a new version simultaneously is a strategy that turns every bad deploy into a production incident. Progressive delivery should be the default for any stateless service.

The implementation hierarchy:
- **Rolling update** — default Kubernetes behaviour, zero-downtime but no traffic control
- **Canary** — route a percentage of traffic to the new version, analyse metrics, promote or rollback automatically
- **Blue/green** — two full environments, instant switchover, easy rollback

Canary with automated analysis (Phase 6b) means a bad deploy that degrades P95 latency will automatically rollback before the SLO is breached — without a human in the loop.

**Implemented in:** Phase 6b (Argo Rollouts, canary strategy, AnalysisTemplate).

### 7. Security is enforced by the platform, not requested by teams

A security control that requires an application team to take action is a control that will be inconsistently applied. Platform-level security means:

- RBAC is applied to every namespace by ArgoCD — no team can skip it
- NetworkPolicies are reconciled continuously — they cannot be accidentally deleted
- Pod Security Standards reject privileged containers at admission — no opt-in
- Vault is the only way to get a secret into a pod — no workarounds

When security is the default, compliant services are the easy path.

**Implemented in:** Phase 3/4 (Vault), Phase 10 (RBAC, NetworkPolicies, PodSecurity), Phase 11 (security baseline ApplicationSet applied to all clusters).

### 8. The platform is disposable; the state is not

Any cluster should be destroyable and reproducible from Git in under an hour. If it is not, the platform has undocumented state — configuration applied by hand, secrets stored only in the cluster, resources created outside of Terraform.

Disposability requires:
- All infrastructure defined in Terraform (Phase 1)
- All Kubernetes resources managed by ArgoCD (Phase 5, 11)
- All secrets stored in Vault with GCS backup (Phase 3)
- A DR drill that proves the assumption: destroy the cluster, provision a new one, restore from backup, verify all services are healthy

**Implemented in:** Phase 1 (Terraform), Phase 3 (Vault with GCS backend), Phase 5 (ArgoCD), Phase 11 (DR drill in README).

---

## Before you write a single manifest: what to decide first

These are not technical decisions. They are architectural and organisational decisions that constrain every phase that follows.

### 1. Where is the boundary between platform and application?

The platform team owns the cluster, the deployment pipeline, and the shared services. The application team owns the Helm chart, the application code, and the service SLO. But there is a boundary in between that must be explicitly drawn:

| Area | Platform team | Application team |
|---|---|---|
| Cluster provisioning | ✓ | |
| Namespace creation | ✓ | |
| RBAC for namespace | ✓ (enforced by ArgoCD) | |
| Helm chart values | | ✓ |
| Application SLO | | ✓ (defines it) |
| Alerting rules | Platform-provided templates | Application customises thresholds |
| Secret rotation | ✓ (Vault policy) | ✓ (application tolerates rotation) |

If this boundary is unclear, the platform team will be asked to debug application bugs, and application teams will feel blocked waiting for platform changes.

### 2. What is your promotion model?

Decide before Phase 11 how an image moves from a feature branch to production:

```
Option A: Branch-based (this lab's model)
  feature → CI → push :sha → auto-deploy dev
                           → manual gate staging
                           → manual gate prod
  ✓ Simple, visible, one pipeline file
  ~ Works for 1–3 environments

Option B: Environment branches
  feature → merge to dev-branch → staging-branch → main
  ✗ Branch merges are not semantic; does a merge mean deploy?
  ✗ Git history becomes hard to read

Option C: ArgoCD Image Updater
  CI pushes image; ArgoCD watches registry, opens PR to bump the tag
  ✓ Fully decoupled CI and CD
  ✓ Scales to many services without pipeline changes
  ~ Requires ArgoCD Image Updater running in the management cluster
```

**This lab's choice:** Option A. The GitHub Actions workflow patches `values-{env}.yaml` per environment with explicit approval gates via GitHub Environments.

### 3. What is your multi-tenancy model?

On a shared cluster, you must decide how tenant isolation is enforced:

| Level | Isolation mechanism | Tradeoff |
|---|---|---|
| **Namespace** | RBAC + NetworkPolicies per namespace | Kernel shared; strong misconfiguration blast radius |
| **Node pool** | Taints/tolerations route tenants to dedicated nodes | Cost; workload cluster per-team is expensive |
| **Cluster** | Each team or environment gets its own cluster | Strongest isolation; highest operational overhead |

This lab uses **cluster-level isolation per environment** (dev/staging/prod are separate GKE clusters) and **namespace-level isolation within a cluster** for the services within an environment.

### 4. How will you handle cluster upgrades?

GKE releases a new minor version roughly every 4 months. If cluster upgrades are not planned for, they become emergency work.

Decide before you build:
- **Who approves a cluster upgrade?** (Platform team, after testing in dev and staging)
- **What is the upgrade process?** (GKE release channels — Rapid, Regular, Stable — or manual)
- **How do you validate an upgrade?** (Run the bootstrap script against the upgraded cluster, verify all services are healthy)
- **What is the rollback plan?** (GKE node pool rollback, or destroy and recreate from Terraform)

### 5. What does "platform done" look like for your organisation?

A platform that is always in progress is one where teams do not know what to expect. Define a maturity target:

| Maturity level | What it means |
|---|---|
| **Level 1 — Running** | Cluster exists, apps deploy, logs are somewhere |
| **Level 2 — Observable** | RED metrics, alerting, log aggregation, on-call runbooks |
| **Level 3 — Self-service** | Service catalog, one-click scaffolding, no platform tickets for new services |
| **Level 4 — Autonomous** | Progressive delivery, auto-remediation, zero-manual-step deployments to prod |
| **Level 5 — Optimised** | Cost visibility per service, capacity planning, SLO-driven autoscaling |

This lab takes CoverLine from Level 0 to Level 4 across 12 phases. Level 5 (cost visibility, Kubecost) is referenced in Phase 10.

---

## Architecture decisions

### Decision 1 — Cluster topology

**The question:** One cluster or many?

```
Option A: Single cluster, namespace-per-environment
  + Cheapest
  + Simplest to operate
  ✗ Environment blast radius (misconfigured RBAC can leak across namespaces)
  ✗ Noisy neighbour on shared nodes
  ✗ A cluster upgrade affects all environments simultaneously

Option B: One cluster per environment (this lab)
  + Strong environment isolation
  + Independent upgrade cadence per environment
  + Clean cost attribution per environment
  ~ Higher base cost (3 control planes)

Option C: One cluster per team per environment
  + Strongest isolation; teams cannot affect each other
  ✗ Cluster sprawl (10 teams × 3 environments = 30 clusters)
  ✗ Platform tooling must scale to N clusters
```

**This lab's choice:** Option B. Dev, staging, and prod are separate GKE clusters provisioned from the same Terraform modules with different variable files.

---

### Decision 2 — Secret management strategy

**The question:** How do secrets get into pods?

```
Option A: Kubernetes Secrets (base64, not encrypted by default)
  + Simple
  ✗ Secrets visible in etcd unless encryption at rest is configured
  ✗ No audit log of who accessed what secret
  ✗ Rotation requires a redeployment

Option B: Vault with agent injection (this lab)
  + Secrets never stored in Kubernetes
  + Full audit log (who accessed what, when)
  + Dynamic secrets: Vault generates short-lived DB credentials per pod
  + Rotation without redeployment (agent re-fetches on TTL expiry)
  ~ Vault must be highly available and backed up

Option C: Cloud-native secret manager (GCP Secret Manager, AWS Secrets Manager)
  + No infrastructure to run
  + Native IAM integration (Workload Identity)
  + Managed rotation
  ~ Vendor lock-in; portability reduced
  ~ No dynamic credentials
```

**This lab's choice:** Option B (Vault) in Phase 3/4 for portability and to demonstrate the full pattern. In a GCP-only production environment, Option C with Workload Identity is a valid simpler alternative.

---

### Decision 3 — GitOps model

**The question:** Push or pull?

```
Push model (traditional CI/CD):
  CI pipeline → kubectl apply → cluster
  + Simple to understand
  ✗ CI must have cluster credentials stored as secrets
  ✗ No continuous reconciliation — drift is not detected
  ✗ Rollback requires re-running the pipeline

Pull model — ArgoCD (this lab):
  CI pipeline → push to Git → ArgoCD watches Git → applies to cluster
  + Cluster credentials never leave the cluster
  + Continuous reconciliation — drift is detected and healed within 3 minutes
  + Rollback is git revert
  + Audit trail is git log
  ~ ArgoCD must be running and healthy
  ~ Initial setup is more complex
```

**This lab's choice:** Pull model via ArgoCD from Phase 5 onwards.

---

### Decision 4 — Management cluster vs. in-cluster tooling

**The question:** Do platform tools (ArgoCD, Vault, Backstage, Grafana) run in the same cluster as applications, or in a dedicated management cluster?

```
In-cluster tooling (this lab, for cost):
  + Simpler; one cluster to manage during learning
  ✗ ArgoCD outage means deployments stop for the apps it manages
  ✗ Platform tooling and app workloads compete for the same resources
  ✗ Access control is harder to enforce cleanly

Management cluster (production standard):
  + ArgoCD manages workload clusters from outside them
  + Blast radius is isolated: platform tools failing doesn't affect running apps
  + Workload clusters are lean: only app workloads, Prometheus, ingress
  + Platform tooling can be upgraded independently
  ~ Higher cost (additional cluster)
  ~ More complex networking (cross-cluster API server access)
```

**This lab's choice:** In-cluster tooling for cost and simplicity. The production topology (management cluster with ArgoCD hub-spoke) is documented in `phase-11-capstone/README.md — Production considerations`.

---

### Decision 5 — Observability data plane

**The question:** Where does each signal live?

```
Option A: Centralised (one Prometheus for all clusters)
  + One place to query
  ✗ Network latency for scraping remote pods
  ✗ Single Prometheus becomes a SPOF for all cluster observability

Option B: Federated (Prometheus per cluster, remote-write to central Grafana)
  + Local scraping, low latency
  + Central Grafana aggregates all signals
  + Cluster Prometheus failure is scoped to that cluster only
  ~ More Prometheus instances to maintain

Option C: Managed observability (Cloud Monitoring, Datadog, Grafana Cloud)
  + No infrastructure to run
  + Long retention by default
  ~ Cost at scale
  ~ Vendor lock-in for dashboards and alert rules
```

**This lab's choice:** Option B. Each cluster runs kube-prometheus-stack (local scraping). Grafana is installed on the dev cluster and reads from local Prometheus. In a multi-cluster production setup, each cluster's Prometheus remote-writes to a central Grafana (or Thanos/Cortex).

---

## How this lab implements each principle

| Principle | Phase(s) |
|---|---|
| The platform is a product | 11 (Backstage) |
| Git is the control plane | 5 (ArgoCD), 11 (ApplicationSets) |
| Every environment is a clone | 1 (Terraform modules), 11 (matrix generator) |
| Secrets never touch Git | 3 (Vault), 4 (Vault agent injection) |
| Observability is a platform concern | 6 (Prometheus, Grafana, Loki), 11 (SLO dashboard) |
| Progressive delivery is the default | 6b (Argo Rollouts, canary) |
| Security is enforced by the platform | 10 (RBAC, NetworkPolicies), 11 (security baseline AppSet) |
| The platform is disposable; the state is not | 1 (Terraform), 3 (Vault GCS), 5 (ArgoCD), 11 (DR) |

| Architecture decision | Phase(s) |
|---|---|
| Cluster topology | 1 (Terraform envs), 11 (multi-cluster) |
| Secret management | 3 (Vault), 4 (agent injection) |
| GitOps model | 5 (ArgoCD), 11 (ApplicationSets) |
| Management cluster topology | 11 (Production considerations) |
| Observability data plane | 6 (kube-prometheus-stack, Loki) |

---

## Reading order

Read this document before Phase 3. Phases 0 through 2 are setup: a GKE cluster, basic networking, and Terraform state. From Phase 3 onwards, every decision builds on the last, and the architectural choices made in Phase 3 (Vault) directly affect how secrets are handled in Phases 4, 7, 9, and 11.

The eight principles are not a checklist to complete. They are a frame for evaluating every decision you make as you go through the lab. When Phase 10 introduces RBAC, the question to ask is not "how do I write a ClusterRole?" — it is "which principle does this serve, and how does it relate to what I built in Phase 5?"

---

[Start: Phase 0 — Terraform & GKE →](./phase-0-terraform-gke/README.md)
