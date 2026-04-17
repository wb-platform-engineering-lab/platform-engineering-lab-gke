# The CoverLine Story

> *A platform engineering journey told through the growing pains of a real company.*

This is the story behind the code. Each phase of this lab was built to solve a problem that CoverLine — a fictional digital health insurer — actually faced as it grew. The problems are real. The decisions are real. The implementation is production-quality.

If you want to understand *why* the technical choices were made before you read *how* they were implemented, start here.

---

## The Company

**CoverLine** is a B2B2C digital health insurer, built in Paris. Companies subscribe to offer health coverage to their employees. Members submit claims, manage their policy, and access their provider network through a web app.

The platform is run by a small engineering team that grew from 2 to 12 people over two years. This is their story.

---

## The Characters

**Léa** — Co-founder and CEO. Former actuary. Understands risk better than anyone in the room, which is why infrastructure incidents make her quietly furious.

**Thomas** — CTO and first engineer. Built the MVP in six weeks. Knows where every skeleton is buried. Has strong opinions about Terraform.

**Sarah** — Senior Backend Engineer. Joined at 20 employees. Has been on-call for every major incident. Wrote most of the post-mortems.

**Karim** — Platform Engineer. Joined at 5,000 members. Hired specifically to fix the deployment problem. Introduced Helm, then ArgoCD, then Vault.

**Inès** — CISO. Joined after the Series B scare. Quiet until she's not.

---

## Chapter 1 — It Works On My Laptop

*Phase 0 — 0 members*

Two founders. A rented desk in a co-working space. One laptop.

The MVP took six weeks. A Python backend, a Node.js frontend, a PostgreSQL database. It ran perfectly — on one machine, in one terminal window, with three `docker run` commands that only Thomas had memorised.

Then an investor asked for a demo. Léa tried to run it on her laptop. It didn't start.

*"It works on mine,"* said Thomas.

They rescheduled the demo. That weekend, they containerised everything properly.

→ **[Phase 0 — Foundations](./phase-0-foundations/README.md)**

---

*Phase 1 — 50 members*

The demo went well. The investors signed. CoverLine had 50 early members, a seed round, and a deadline to onboard their first corporate client in six weeks.

Thomas spun up a server manually on GCP. Clicked through the console. Picked a region. Wrote down the IP address on a sticky note.

Three weeks later, he needed a staging environment. He couldn't remember what he'd clicked. The two environments drifted immediately. A bug that only reproduced in production took two days to diagnose because staging was missing a firewall rule that had been added manually and never documented.

*"If this server dies tonight, how long to rebuild it?"* a colleague asked.

Thomas paused. *"A day. Maybe two."*

*"That's not acceptable."*

Every resource moved to Terraform. The entire platform became reproducible from a single command.

→ **[Phase 1 — Cloud & Terraform](./phase-1-terraform/README.md)**

---

## Chapter 2 — We Broke Prod and Didn't Know It

*Phase 2 — 200 members*

The first corporate client went live on a Monday. By Thursday, the backend was struggling under load.

A developer pushed a config change. The single container running the backend restarted. For 90 seconds, every claim submission returned an error. 23 members saw a blank screen. Four of them emailed support.

One container. One point of failure. Zero redundancy.

The team tried running two containers behind a load balancer. It worked, until a deploy took both containers down simultaneously. They tried staggering restarts manually. It worked, until someone forgot the procedure at 11 PM.

*"We need something that manages containers for us,"* Thomas said. *"Something that handles restarts, rollouts, and keeps a minimum number running at all times."*

They moved to Kubernetes.

→ **[Phase 2 — Kubernetes Core](./phase-2-kubernetes/README.md)**

---

*Phase 3 — 1,000 members*

The backend team shipped a Redis caching fix on a Tuesday afternoon. By Wednesday morning, the frontend was broken — the fix had changed an API response format that three other services depended on.

No one knew which version of the backend was running in production. The Kubernetes YAML files had drifted from what was actually deployed. A hotfix was pushed directly to the cluster by copy-pasting from a Slack message.

Thomas called an all-hands. *"We have four engineers and we already can't tell what's running in production. What happens at 10,000 members?"*

Everything moved to Helm. One source of truth. Versioned. Rollbackable.

→ **[Phase 3 — Helm & Microservices](./phase-3-helm/README.md)**

---

## Chapter 3 — The Deploy Took Four Hours

*Phase 4 — 5,000 members*

CoverLine hired Karim as its first dedicated platform engineer.

His first week, a junior dev needed to ship a claims form fix before the weekend. She followed the deploy runbook — a Google Doc last updated eight months ago. Halfway through, she realised the steps assumed a tool that had since been replaced. She improvised. The deploy took four hours, involved three Slack calls, and broke the member login page for 40 minutes on a Friday afternoon.

Karim found six different versions of the deploy process spread across Slack threads, Notion pages, and a Post-it note on a monitor.

*"The deploy process can't live in someone's head,"* he said. *"It needs to be code."*

He built GitHub Actions pipelines. Every merge to main triggers a build, a push, and a deploy. No runbooks. No manual steps.

→ **[Phase 4 — CI/CD Pipelines](./phase-4-ci-cd/README.md)**

---

*Phase 5 — 15,000 members*

The pipelines worked. But they created a new problem.

A developer pushed a config change at 4 PM on a Friday. The CD pipeline passed. But at 4:47 PM, a second developer merged a conflicting change. The pipeline ran again and silently overwrote the first deploy with a broken config.

By 5 PM, the claims API was returning 500s. Neither developer knew the other had deployed. There was no single record of what was running in the cluster. The on-call engineer — Sarah — spent two hours diffing YAML files before finding the cause.

*"The cluster is the source of truth,"* she wrote in the post-mortem. *"But it shouldn't be. Git should be."*

Karim introduced ArgoCD. The cluster state is driven entirely from Git. Drift is impossible. Every change is traceable.

→ **[Phase 5 — GitOps with ArgoCD](./phase-5-gitops/README.md)**

---

*Phase 5b — 20,000 members*

GitOps was in place. The team was shipping fast, with confidence.

Too fast, that afternoon.

A new version of the claims service was merged and deployed automatically. Within seconds it was serving 100% of traffic. A bug in an edge case — long-term hospitalisation claims — started returning 5xx errors.

Nobody noticed.

Eighteen minutes later, a developer walked past a Grafana screen by chance. He stopped. He zoomed in on the error rate graph.

12% of 5xx errors. For eighteen minutes.

Hundreds of members had silently failed to submit their claims. The GitOps pipeline had worked perfectly — it had faithfully deployed exactly what was in Git. The problem was that there was no mechanism to slow down a deploy and watch what happened before it reached everyone.

*"GitOps without progressive delivery is just a faster way to break things at scale,"* Karim said.

They introduced Argo Rollouts. New versions now receive 10% of traffic first. A PromQL AnalysisTemplate watches the error rate continuously. If the threshold is breached, the rollback is automatic — no human required. If metrics stay clean for five minutes, the rollout promotes to 100%.

The next bug reached 10% of users for three minutes. The system corrected itself.

→ **[Phase 5b — Progressive Delivery](./phase-5b-progressive-delivery/README.md)**

---

## Chapter 4 — We Found Out From a Customer

*Phase 6 — 50,000 members*

At 2:14 AM on a Tuesday, CoverLine's claims processing stopped working. Members trying to submit claims got a blank screen.

Sarah woke up at 6:30 AM — not to a page, but to a Slack message from a member who had emailed support. By then, the issue had been ongoing for four hours and had self-resolved. No one knew what had caused it. No one knew how many members were affected.

The post-mortem conclusion was brutal: *"We found out about a 4-hour outage from a customer. We had no metrics, no alerts, and no centralised logs. We were flying blind."*

Karim and Sarah spent a week building the observability stack. Prometheus. Grafana. Loki. Alertmanager. Three custom alerting rules for CoverLine.

The next incident, they woke up before the customer did.

→ **[Phase 6 — Observability](./phase-6-observability/README.md)**

---

## Chapter 5 — The Credentials Were in Git

*Phase 7 — 100,000 members*

CoverLine was preparing for its Series B. As part of due diligence, the investors hired an external security firm to audit the codebase.

The audit took three days. The report took one paragraph to deliver its most critical finding:

*"Database credentials for the production PostgreSQL instance were found committed in plaintext in the application's Git history. The credentials appear in 14 commits across 3 branches, including the public-facing repository. These credentials have not been rotated in 11 months."*

Inès, the CISO hired two months earlier, read the report at 8 AM. By 9 AM, the credentials were rotated. By 10 AM, three engineers were in a war room.

The database password had been in the repo since the first sprint. Every contractor, every open-source contributor, every person who had ever cloned the repo had it.

The Series B was delayed by six weeks pending a full security remediation.

*"We didn't have a secrets problem,"* Inès said. *"We had a culture problem. Secrets need to be impossible to commit, not just discouraged."*

They deployed HashiCorp Vault. Credentials never touch the filesystem. Pods get short-lived dynamic credentials that rotate automatically. Git contains no secrets — not even accidentally.

→ **[Phase 7 — Secrets Management (Vault)](./phase-7-vault/README.md)**

---

## Chapter 6 — The Platform Survived Everything Except Its Own Success

*Phase 8 — 250,000 members*

Every year in November, companies renew their employee health coverage contracts.

In 72 hours, 40,000 employees log in simultaneously to update their details, choose their options, and submit their first claims.

CoverLine had planned for growth. They had not planned for this spike.

Twenty minutes after enrollment opened, the member portal was returning 504s. The claims service had stopped responding. The RH managers of three enterprise clients called at the same time.

The post-mortem was brutal. The cluster was fixed at three nodes — no autoscaling. One pod had consumed the entire CPU of a node because there were no resource limits. And during the maintenance window the previous evening, two out of three pods had been stopped simultaneously. There was no PodDisruptionBudget to prevent that.

The platform had survived everything. Except its own success.

*"We built the platform for the load we had,"* Thomas said. *"We need to build it for the load we'll have in six months."*

HPA was configured to scale on CPU, memory, and custom metrics. Cluster Autoscaler provisions new nodes under load and removes them when traffic drops. PodDisruptionBudgets ensure at least one pod remains available during any maintenance operation. Resource requests and limits were set on every workload. Then the team ran k6 load tests to validate that autoscaling triggered at the right threshold before the next enrollment window.

The following open enrollment: 10x the traffic. Zero incidents.

→ **[Phase 8 — Advanced Kubernetes](./phase-8-advanced-k8s/)** · [▶ watch the incident](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/incident-animation.html)

---

## Chapter 7 — The Bug Nobody Found For Three Weeks

*Phase 9 — 500,000 members*

Every Monday morning, the same ritual.

A developer connected to the production database, exported the week's claims to a CSV, and emailed it to the data team. The actuaries opened the file in Excel, cleaned duplicates by hand, removed irrelevant columns, and ran their risk models.

500,000 members. Critical actuarial analyses. Built on hand-cleaned data, six days stale.

One Monday, the export script had a silent bug. It duplicated 8,000 claims without raising an error. The data team didn't notice. The fraud detection model was trained on the corrupted data.

For three weeks, it flagged legitimate claims as fraudulent. Reimbursements were blocked. Members called support without understanding why.

The bug was discovered by chance, during an internal audit.

The post-mortem conclusion: *"We have data infrastructure. We don't have a data platform. There's no testing, no monitoring, no audit trail. The pipeline lives in one developer's head and one cron job nobody owns."*

Airflow now orchestrates the pipelines — DAGs versioned in Git, with automatic retry and immediate alerts on failure. dbt transforms and tests the data — a duplicate in the claims table fails the pipeline before it reaches BigQuery. Kafka streams claim events in real time, eliminating the weekly export entirely.

The actuaries have fresh data every morning. No CSV. No Excel. No developer.

→ **[Phase 9 — Data Platform](./phase-9-data-platform/)**

---

## Chapter 8 — The Audit

*Phase 10 — 1,000,000 members*

The ISO 27001 auditor asked for access to the cluster.

He spent two hours examining the configuration. Then he opened his report.

There were 14 points.

Pods were running as root — a compromised container had write access to the node filesystem. Any pod could open a direct connection to PostgreSQL — no network isolation. Developers had `cluster-admin` rights in production — anyone could delete anything at any time. And the Docker images in production had never been scanned — some contained critical CVEs that had been present for months.

The ISO 27001 certification was suspended.

1,000,000 members. Health data. A platform built fast, under pressure, without ever thinking about this moment.

Inès handed Thomas the report the same afternoon. *"This isn't a list of things to fix. It's a list of things that were never built. Security doesn't get retrofitted — it gets rebuilt."*

RBAC was restructured: developers have read-only access in production, and `cluster-admin` is no longer handed out by default. NetworkPolicies enforce strict isolation — the frontend can only reach the backend, the backend can only reach PostgreSQL. Pod Security Standards enforce `runAsNonRoot`, `readOnlyRootFilesystem`, and the dropping of all unnecessary Linux capabilities. Trivy scans every image in CI — a CRITICAL CVE fails the build before the image reaches the registry. GKE audit logs now record who did what, from which IP, on which resource, and when.

A compromised pod can no longer pivot to the database. A developer can no longer accidentally delete a production deployment.

The next audit: zero critical non-conformities.

→ **[Phase 10 — Security Hardening](./phase-10-security/README.md)**

---

## Chapter 9 — The Contract That Revealed the Gap

*Phase 10c — ~1,200,000 members*

The enterprise client closing meeting went well.

12,000 employees. A multi-year contract. And a standard clause the client's lawyer insisted on including: RTO 4 hours, RPO 1 hour on claims data.

Thomas said yes. The signature happened.

Back at the office, he asked the team: *"Can we actually meet that SLA?"*

A silence.

The team had backups — in theory. A script that ran somewhere. But nobody had ever run it in reverse. Nobody had ever restored anything. A quick tabletop exercise revealed that a complete cluster loss would take between two and three days to recover manually.

The contract was signed. The SLA was contractual. And the platform couldn't meet it.

Sarah ran the work. A `pg_dump` CronJob runs every hour and writes to GCS with a seven-day retention. Velero takes daily snapshots of the full namespace, including PVCs. Vault raft snapshots run every hour. Prometheus alerts fire if any backup job fails — the team knows before it counts.

Then they ran the drill. They simulated a complete cluster loss and measured the actual RTO. PostgreSQL restored in 28 minutes. Full cluster back in 2 hours 47 minutes.

SLA met. Proven. Documented.

*"A backup you've never tested isn't a backup,"* Sarah wrote in the runbook. *"It's a false sense of security with a contract around it."*

→ **[Phase 10c — Backup & Disaster Recovery](./phase-10c-backup-dr/README.md)**

---

## Chapter 10 — The CFO's Question

*Phase 10e — ~1,500,000 members*

The CFO sent an email on a Thursday morning.

*"Last month's GCP bill: €18,400. Can you tell me what that's for, by team?"*

Engineering's response, Friday: *"We don't know exactly. It's one cluster. We can look into it."*

The CFO replied: *"I'm asking this question again at the next board in 10 days."*

The platform team spent a week trying to reconstruct costs from GCP logs. It was imprecise, manual, and incomplete. And during that week, they found something else: the data team's batch job ran every day at 9 AM — peak usage — and consumed 60% of available CPU. The claims service slowed every morning. Nobody had connected it to the batch job.

Kubecost was installed and allocated costs by namespace, by deployment, by `team=` label — in real time. Every workload was labelled: `team=`, `env=`, `product=`. GCP Budget Alerts send notifications at 80% and 100% of the monthly budget. Billing exports flow into BigQuery and a dbt model produces cost-per-phase, cost-per-team, cost-per-environment reports.

The batch job was rescheduled to 3 AM. The CPU contention disappeared. Three over-provisioned workloads were right-sized. The bill dropped 23% the following month.

At the next board, the CFO had his dashboard.

→ **[Phase 10e — FinOps](./phase-10e-finops/README.md)**

---

## Chapter 11 — The Platform You Wish You'd Had From Day One

*Phase 11 — 2,000,000 members*

The new CTO spent his first two weeks reading the code, the runbooks, and the post-mortems.

Then he called a meeting with the platform team.

*"The platform works. I'm not disputing that. But it was built phase by phase, under pressure, by a small team solving urgent problems. The result is that every tool is well configured in its corner — but nobody can see the state of the entire system in one place. Onboarding a new engineer still takes three days. Deploying to a new country requires duplicating the infrastructure by hand. And security is applied in dev, but nobody can prove it's applied in staging and prod."*

2,000,000 members. 40 engineers. 6 product teams.

The mandate: *"Build the platform you wish you'd had from day one. Zero manual steps from code to production. Multi-environment. Fully observable. Secure by default. Every service self-documented and discoverable."*

Multi-environment Terraform gave dev, staging, and prod separate state files with isolated blast radius. An ArgoCD ApplicationSet replaced every individual Application manifest — one YAML file generates one ArgoCD Application per service per environment. The Matrix generator means adding a new service is creating a Helm chart directory. The promotion pipeline goes feature branch → CI (Trivy) → dev (automatic) → staging (one approver) → prod (one approver), with no manual AWS steps. Backstage provides a service catalog, self-service scaffolding, and TechDocs pulled from Git — onboarding dropped from three days to two hours. A unified Grafana dashboard shows the state of the entire platform on a single screen.

Adding a new environment: `terraform apply`, register the cluster in ArgoCD. Everything else is automatic.

→ **[Phase 11 — Capstone](./phase-11-capstone/README.md)**

---

## Chapter 12 — The Queue That Couldn't Shrink

*Phase 12 — 3,000,000 members*

The claims triage team started at 7:30 every morning. By 10 AM, the backlog already exceeded 72 hours.

The Head of Claims opened his dashboard and showed the CTO the breakdown for the week. 63% of incoming claims were GP consultations, prescription renewals, and optical reimbursements. Simple cases, well-documented, no ambiguity. They all followed the same pattern. And each one took a human analyst 8 to 12 minutes.

Meanwhile, the complex claims — long hospitalisations, chronic conditions, disputes with providers — were waiting behind the same queue.

*"We can't hire fast enough to keep up with growth,"* the Head of Claims said. *"And we shouldn't need to — not for those cases."*

A claims triage agent was built on the Claude API with tool use. Every incoming claim is classified as AUTO_APPROVE, MANUAL_REVIEW, or ESCALATE, with a natural-language justification the analyst can read and override. An on-call SRE assistant connects to Prometheus and Loki, receives PagerDuty alerts, queries the metrics and logs, and generates a structured incident diagnosis in 30 seconds. A weekly summary agent produces a report every Monday: average cost per claim, approval rates, anomalies detected during the week. Everything is orchestrated via Airflow DAGs and deployed on the cluster like any other workload. LLM observability — cost per request, latency, confidence scores — lives in Grafana alongside the rest of the platform metrics.

Result: 60% of claims processed automatically in under 30 seconds. Analysts focus on the 40% that actually need a human.

*"The LLMs aren't magic,"* Karim said. *"But integrated properly into an observable, governed platform, they change what a small team can do."*

→ **[Phase 12 — GenAI & Agentic Workflows](./phase-12-genai/README.md)**

---

## How to Use This Lab

Each phase is self-contained. You can start at any chapter.

If you're new to platform engineering, start at Phase 0 and follow CoverLine's journey.

If you're preparing for a specific certification:
- **Terraform Associate** → Phase 1
- **GCP ACE** → Phase 1
- **Prometheus Certified Associate** → Phase 6
- **CKAD / CKA** → Phase 8
- **CKS** → Phase 10

---

## How to Use This Lab

Each phase is self-contained. You can start at any chapter.

If you're new to platform engineering, start at Phase 0 and follow CoverLine's journey.

If you're preparing for a specific certification:
- **Terraform Associate** → Phase 1
- **GCP ACE** → Phase 1
- **Prometheus Certified Associate** → Phase 6
- **CKAD / CKA** → Phase 8
- **CKS** → Phase 10

→ **[Full setup and prerequisites](./README.md)**
→ **[Detailed roadmap with cost estimates](./roadmap.md)**
