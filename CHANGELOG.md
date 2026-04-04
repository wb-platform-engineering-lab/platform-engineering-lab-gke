# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [4.0.0] — 2026-04-04

### Phase 4 — CI/CD Pipelines

#### Added
- GitHub Actions CI workflow (`ci.yml`) — builds and pushes Docker images to Artifact Registry on every feature branch push, tagged with git SHA and `dev`
- GitHub Actions CD workflow (`cd.yml`) — builds, pushes images tagged with SHA and `latest`, deploys to GKE via Helm on every merge to main
- GCP Workload Identity Federation — GitHub Actions authenticates to GCP via OIDC, no JSON keys stored in GitHub secrets
- Dedicated `github-ci` service account with least-privilege permissions (`artifactregistry.writer` + `container.developer`)
- Phase 4 README with pipeline overview, full GCP setup commands, and troubleshooting

#### Fixed
- `gke-gcloud-auth-plugin` installed in CD runner to fix `Kubernetes cluster unreachable` error
- `--install` flag added to `helm upgrade` to handle first-time deploys
- CD `paths` trigger extended to include `.github/workflows/cd.yml` to allow workflow-only changes to trigger deploys

---

## [3.0.0] — 2026-04-04

### Phase 3 — Helm & Microservices

#### Added
- Backend and frontend packaged as Helm charts with templates, `values.yaml`, and `_helpers.tpl`
- PostgreSQL deployed via Bitnami Helm chart as a Kubernetes StatefulSet
- Redis deployed via Bitnami Helm chart as a Kubernetes StatefulSet
- Flask backend upgraded with real `/claims` endpoints (PostgreSQL reads/writes + Redis caching with 30s TTL)
- Node.js frontend upgraded to proxy claims API — displays live claims from backend
- `helm upgrade` and `helm rollback` demonstrated (scale to 3 replicas, rollback to 2)
- Phase 3 README with architecture diagram, deploy steps, and troubleshooting

#### Fixed
- `.gitignore` updated to exclude `phase-*/charts/` from the `charts/` ignore rule

---

## [2.0.0] — 2026-04-04

### Phase 2 — Kubernetes Core

#### Added
- Backend and frontend deployed as Kubernetes Deployments with 2 replicas each
- Services exposed via ClusterIP
- nginx Ingress controller installed, external traffic routed via path-based rules (`/` → frontend, `/api/*` → backend)
- ConfigMap for environment configuration — no hardcoded values in manifests
- Readiness and liveness probes on all containers
- Resource requests and limits on all containers
- Simulated bad deploy (broken image tag) and rollback via `kubectl rollout undo`
- Phase 2 README with architecture diagram, deploy steps, and troubleshooting

#### Fixed
- Docker images rebuilt with `--platform linux/amd64` to fix `no match for platform in manifest` on GKE (Apple Silicon build host)
- Artifact Registry reader IAM binding added to GKE node service account to fix `ImagePullBackOff`
- Ingress rewrite annotation fixed to strip `/api` prefix before forwarding to backend

---

## [1.0.0] — 2026-03-01

### Phase 1 — Cloud & Terraform

#### Added
- VPC with private subnet, secondary ranges for pods and services
- Cloud Router and Cloud NAT for private node outbound traffic
- GKE cluster with private nodes, VPC-native networking, `deletion_protection = false`
- Managed node pool: `e2-standard-2`, spot instances, autoscaling 1–3 nodes, `pd-standard` disks
- BigQuery dataset with `delete_contents_on_destroy = true`
- Remote Terraform state stored in GCS bucket (`platform-eng-lab-will-tfstate`)
- GitHub Actions nightly auto-destroy workflow (cron `0 20 * * *`, `AUTO_DESTROY_ENABLED` toggle)
- 9 Architecture Decision Records (ADRs 001–009, 022)
- Phase 1 README with deploy instructions, kubectl config, GKE node pool best practices, and troubleshooting

#### Fixed
- `disk_type = "pd-standard"` added to both node pool and cluster bootstrap node to fix `SSD_TOTAL_GB` quota error
- `deletion_protection = false` added to GKE cluster resource

---

## [0.1.0] — 2026-02-15

### Phase 0 — Foundations

#### Added
- Python Flask backend with `/health` and `/data` endpoints
- Node.js Express frontend calling backend via `BACKEND_URL` environment variable
- Multi-stage Dockerfiles for both services (backend: 1.62GB → 210MB, frontend: 310MB)
- `docker-compose.yml` with both services on a shared `app-network`
- Phase 0 README with image size comparison, run instructions, and troubleshooting

---

## [0.0.1] — 2026-02-01

### Repository bootstrap

#### Added
- Initial repository structure with phase directories
- Root `README.md` with CoverLine product story, tech stack badges, progress table, and certification path
- `roadmap.md` with all 13 phases, business context, cost estimates, Claude efficiency guides, and ADR prompts
- `.gitignore` covering Terraform, Helm, Docker, Python, Node.js, secrets, and IDE files
- 21 Architecture Decision Records planned across all phases
