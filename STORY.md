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

## What's Next

CoverLine keeps growing. The problems keep changing.

| Chapter | Members | The Problem |
|---------|---------|-------------|
| 6 — Scale | 250,000 | Open enrollment hits. 10x traffic spike. The app is unresponsive for 45 minutes. |
| 7 — Data | 500,000 | The actuarial team is manually exporting CSVs every Monday. Three analysts. Four hours. Every week. |
| 8 — Security | 1,000,000 | ISO 27001 audit. Pods running as root. No network policies. Falco finds a cryptominer. |
| 9 — Platform | 2,000,000+ | 12 engineering teams. No shared standards. Every team reinventing the same infrastructure. |

These chapters are in progress. Follow along:

→ **[Phase 8 — Advanced Kubernetes + CKAD/CKA](./phase-8-advanced-k8s/)** · [▶ watch the incident](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-8-advanced-k8s/incident-animation.html)
→ **[Phase 9 — Data Platform](./phase-9-data-platform/)**
→ **[Phase 10 — Security Hardening](./phase-10-security/)**
→ **[Phase 11 — Capstone + Backstage IDP](./phase-11-capstone/)**

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
