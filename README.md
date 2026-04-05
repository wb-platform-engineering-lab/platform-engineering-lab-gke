# Platform Engineering Lab — GKE

A hands-on, end-to-end platform engineering project built on Google Kubernetes Engine. Each phase solves a real business problem faced by **CoverLine** — a fictional digital health insurance platform (Alan-style) — as it grows from a 2-person startup to a 2,000,000-member enterprise.

Built as a portfolio project and study path toward **7 industry certifications**: Terraform Associate, GCP ACE, Prometheus Certified Associate, CKAD, CKA, GCP Professional Cloud DevOps Engineer, and CKS.

---

## The Product — CoverLine

CoverLine is a B2B2C digital health insurer. Companies subscribe to offer health coverage to their employees. Members submit claims, manage their policy, and access their provider network through a web app.

Each phase is motivated by a real engineering problem that emerged as CoverLine grew:

| Phase | Members | Problem Solved |
|---|---|---|
| 0 | 0 | App only runs on one laptop — can't demo to investors |
| 1 | 50 | Infrastructure provisioned by hand — can't reproduce it |
| 2 | 200 | One bad deploy takes down the entire platform |
| 3 | 1,000 | Teams block each other — everything deploys as one unit |
| 4 | 5,000 | Manual deploys take half a day, releases are delayed |
| 5 | 15,000 | Someone pushed to prod on a Friday and broke claims processing |
| 6 | 50,000 | 4-hour outage — found out from a customer, not monitoring |
| 7 | 100,000 | GDPR audit: DB credentials found in plaintext in Git |
| 8 | 250,000 | Open enrollment — 10x traffic spike, app unresponsive for 45min |
| 9 | 500,000 | Actuarial team manually exporting CSVs every Monday |
| 10 | 1,000,000 | ISO 27001 audit — pods running as root, no network policies |
| 11 | 2,000,000+ | Full platform — zero manual steps, multi-environment |

---

## Tech Stack

![Terraform](https://img.shields.io/badge/Terraform-7B42BC?style=flat&logo=terraform&logoColor=white)
![GCP](https://img.shields.io/badge/Google_Cloud-4285F4?style=flat&logo=google-cloud&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat&logo=helm&logoColor=white)
![ArgoCD](https://img.shields.io/badge/ArgoCD-EF7B4D?style=flat&logo=argo&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?style=flat&logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?style=flat&logo=grafana&logoColor=white)
![Vault](https://img.shields.io/badge/Vault-FFEC6E?style=flat&logo=vault&logoColor=black)
![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat&logo=docker&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![Node.js](https://img.shields.io/badge/Node.js-339933?style=flat&logo=node.js&logoColor=white)
![Apache Airflow](https://img.shields.io/badge/Airflow-017CEE?style=flat&logo=apache-airflow&logoColor=white)
![Apache Kafka](https://img.shields.io/badge/Kafka-231F20?style=flat&logo=apache-kafka&logoColor=white)
![dbt](https://img.shields.io/badge/dbt-FF694B?style=flat&logo=dbt&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=flat&logo=postgresql&logoColor=white)
![Redis](https://img.shields.io/badge/Redis-DC382D?style=flat&logo=redis&logoColor=white)
![BigQuery](https://img.shields.io/badge/BigQuery-4285F4?style=flat&logo=google-cloud&logoColor=white)
![Claude](https://img.shields.io/badge/Claude_API-D97757?style=flat&logo=anthropic&logoColor=white)

---

## Architecture

```
                        ┌──────────────────────────────────────────────────┐
                        │                   GCP Project                    │
                        │                                                  │
                        │  ┌────────────────────────────────────────────┐ │
                        │  │                   VPC                      │ │
                        │  │                                            │ │
                        │  │  ┌─────────────────────┐  ┌────────────┐  │ │
   Developer  ──push──▶ │  │  │    GKE Cluster       │  │  Artifact  │ │ │
                        │  │  │                      │  │  Registry  │ │ │
   GitHub CI  ──build──▶│  │  │  ArgoCD  │ Helm      │  └────────────┘ │ │
              ──push──▶ │  │  │  Vault   │ Falco     │                  │ │
                        │  │  │  Prometheus│ Grafana │  ┌────────────┐  │ │
   ArgoCD  ──sync──────▶│  │  │  Loki    │ Airflow   │  │  BigQuery  │ │ │
                        │  │  │  PostgreSQL│ Redis   │  └────────────┘  │ │
                        │  │  └─────────────────────┘                   │ │
                        │  └────────────────────────────────────────────┘ │
                        └──────────────────────────────────────────────────┘
```

---

## Progress

| Phase | Topic | Members | Est. Time | Status |
|---|---|---|---|---|
| 0 | Foundations (Docker, Linux, Git) | 0 | 2–3 days | ✅ Complete |
| 1 | Cloud & Terraform (GCP, VPC, GKE) | 50 | 4–6 days | ✅ Complete |
| 2 | Kubernetes Core (raw YAML) | 200 | 2–3 days | ✅ Complete |
| 3 | Helm & Microservices + PostgreSQL + Redis | 1,000 | 5–7 days | ✅ Complete |
| 3b | Event-Driven Architecture (Kafka + Strimzi) | 2,000 | 3–4 days | ⬜ Not started |
| 4 | CI/CD Pipelines | 5,000 | 3–4 days | ✅ Complete |
| 5 | GitOps with ArgoCD | 15,000 | 2–3 days | ✅ Complete |
| 6 | Observability (Prometheus, Grafana, Loki) + **PCA** | 50,000 | 5–7 days | ✅ Complete |
| 7 | Secrets Management (Vault) | 100,000 | 4–5 days | ⬜ Not started |
| 8 | Advanced Kubernetes + **CKAD** + **CKA** | 250,000 | 3–4 days + 4–8 wks cert | ⬜ Not started |
| 9 | Data Platform (Airflow + dbt + BigQuery) + **GCP DevOps** | 500,000 | 6–8 days | ⬜ Not started |
| 10 | Security & Production Hardening | 1,000,000 | 3–4 days | ⬜ Not started |
| 10b | CKS Exam Preparation + **CKS** | 1,000,000 | 5–7 days + 4–6 wks cert | ⬜ Not started |
| 10c | Backup & Disaster Recovery (Velero, pg_dump, DR runbook) | 1,000,000 | 3–4 days | ⬜ Not started |
| 11 | Capstone Project | 2,000,000+ | 7–10 days | ⬜ Not started |
| 12 | GenAI & Agentic Workflows (Claude API, Airflow + LLM) | 3,000,000+ | 4–6 days | ⬜ Not started |
| | **Total lab work** | | **~66–88 days** | |
| | **With cert study** | | **~6–9 months** | |

---

## Certification Path

| Certification | Issuer | After Phase |
|---|---|---|
| Terraform Associate (003) | HashiCorp | Phase 1 |
| Google Cloud Associate Cloud Engineer | Google | Phase 1 |
| Prometheus Certified Associate (PCA) | CNCF | Phase 6 |
| Certified Kubernetes Application Developer (CKAD) | CNCF | Phase 8 |
| Certified Kubernetes Administrator (CKA) | CNCF | Phase 8 |
| GCP Professional Cloud DevOps Engineer | Google | Phase 9 |
| Certified Kubernetes Security Specialist (CKS) | CNCF | Phase 10b |

---

## Repository Structure

```
.
├── docs/
│   └── decisions/        # Architecture Decision Records (9 ADRs)
├── phase-0-foundations/
├── phase-1-terraform/
│   └── modules/
│       ├── networking/
│       ├── gke/
│       └── bigquery/
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
├── phase-10c-backup-dr/
├── phase-11-capstone/
└── phase-12-genai/
```

---

## Getting Started

### GCP Account Setup

Phases 1 and above require a GCP account with billing enabled.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and sign in with any Google account
2. Click **Start free trial** — you get **$300 in free credits** (credit card required but not charged unless you manually upgrade)
3. Install the `gcloud` CLI: [cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install)
4. Authenticate locally:

```bash
gcloud auth login
gcloud auth application-default login
```

> **Cost warning:** A running GKE cluster costs ~$5–20/day. Always run `terraform destroy` when done with a session.

### Prerequisites

See [roadmap.md](./roadmap.md#prerequisites) for the full tool list with versions.

```bash
# Verify core tools
docker --version
terraform --version
kubectl version --client
helm version
gcloud --version
```

### Connect to the GKE Cluster

After the cluster is provisioned via Terraform (Phase 1), configure `kubectl`:

```bash
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region europe-west1 \
  --project platform-eng-lab-will
```

Verify:

```bash
kubectl get nodes
```

### Branch Strategy

Each phase is developed on its own branch and merged via PR:

```bash
git checkout -b phase-2
# do work
git push origin phase-2
# open PR → merge to main → tag release
```

---

## Architecture Decision Records

21 ADRs documented in [`docs/decisions/`](./docs/decisions/) — one for every major tool choice across all phases, from why GKE over self-managed Kubernetes to why Falco over Sysdig for runtime security.

---

## Roadmap

See [roadmap.md](./roadmap.md) for the full phase-by-phase plan, CoverLine business context, cost estimates, and certification milestones.
