# Platform Engineering Lab — GKE

A hands-on, end-to-end platform engineering project built on Google Kubernetes Engine. Each phase covers a real-world DevOps skill, progressing from Docker fundamentals to a fully automated, production-like platform with GitOps, observability, secrets management, and CI/CD.

Built as a portfolio project and study path toward **CKA** and **CKS** certifications.

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
![dbt](https://img.shields.io/badge/dbt-FF694B?style=flat&logo=dbt&logoColor=white)

---

## Architecture

```
                        ┌─────────────────────────────────────────┐
                        │              GCP Project                │
                        │                                         │
                        │  ┌─────────────────────────────────┐   │
                        │  │            VPC                  │   │
                        │  │                                 │   │
                        │  │  ┌──────────┐  ┌────────────┐  │   │
   Developer  ──push──▶ │  │  │  GKE     │  │  Artifact  │  │   │
                        │  │  │  Cluster │  │  Registry  │  │   │
   GitHub CI  ──build──▶│  │  │          │  └────────────┘  │   │
              ──push──▶ │  │  │ ArgoCD   │                   │   │
                        │  │  │ Helm     │                   │   │
   ArgoCD  ──sync──────▶│  │  │ Vault    │                   │   │
                        │  │  │ Prometheus│                  │   │
                        │  │  │ Grafana  │                   │   │
                        │  │  │ Loki     │                   │   │
                        │  │  │ Falco    │                   │   │
                        │  │  └──────────┘                   │   │
                        │  └─────────────────────────────────┘   │
                        └─────────────────────────────────────────┘
```

---

## Progress

| Phase | Topic | Status |
|---|---|---|
| 0 | Foundations (Docker, Linux, Git) | ✅ Complete |
| 1 | Cloud & Terraform (GCP, VPC, GKE) | ⬜ Not started |
| 2 | Kubernetes Core (raw YAML) | ⬜ Not started |
| 3 | Helm & Microservices | ⬜ Not started |
| 4 | CI/CD Pipelines | ⬜ Not started |
| 5 | GitOps with ArgoCD | ⬜ Not started |
| 6 | Observability (Prometheus, Grafana, Loki) | ⬜ Not started |
| 7 | Secrets Management (Vault) | ⬜ Not started |
| 8 | Advanced Kubernetes + **CKA** | ⬜ Not started |
| 9 | Data Platform (Airflow + dbt) | ⬜ Not started |
| 10 | Security & Production Hardening | ⬜ Not started |
| 10b | CKS Exam Preparation + **CKS** | ⬜ Not started |
| 11 | Capstone Project | ⬜ Not started |

---

## Repository Structure

```
.
├── docs/
│   └── decisions/        # Architecture Decision Records
├── phase-0-foundations/
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

## Getting Started

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

### Branch Strategy

Each phase is developed on its own branch and merged via PR:

```bash
git checkout -b phase-0
# do work
git push origin phase-0
# open PR → merge to main
```

---

## Architecture Decision Records

Key design decisions are documented in [`docs/decisions/`](./docs/decisions/).

---

## Roadmap

See [roadmap.md](./roadmap.md) for the full phase-by-phase plan, challenges, and certification milestones.
