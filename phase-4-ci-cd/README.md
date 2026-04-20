# Phase 4 — CI/CD Pipelines

> **CI/CD concepts introduced:** GitHub Actions, Workload Identity Federation, Artifact Registry, Trivy, SonarCloud, pre-commit | **Builds on:** Phase 3 Helm charts

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-4-ci-cd/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **GitHub Actions** | Event-driven CI/CD workflows defined as YAML | Automates build, scan, and deploy on every push — no manual steps |
| **Workload Identity Federation** | OIDC token exchange between GitHub and GCP | Eliminates long-lived service account JSON keys stored as secrets |
| **Artifact Registry** | Private Docker image registry on GCP | Stores versioned images tagged with git SHA for full traceability |
| **Trivy** | Container image vulnerability scanner | Blocks the pipeline if CRITICAL or HIGH CVEs are found before pushing |
| **SonarCloud** | Static code analysis and quality gate | Blocks merges if code quality or security thresholds are breached |
| **Pre-commit hooks** | Local linters that run before every commit | Catches issues before they reach CI — faster feedback loop |

---

## The problem

> *CoverLine — 5,000 members. June.*
>
> A senior engineer was on holiday. A junior dev needed to ship a claims form fix before the weekend. She followed the deploy runbook — a Google Doc last updated eight months ago. Halfway through, she realised the steps assumed a tool that had since been replaced. She improvised. The deploy took four hours, involved three Slack calls, and broke the member login page for 40 minutes on a Friday afternoon.
>
> When the senior engineer returned on Monday, he found six different versions of the deploy process spread across Slack threads, Notion pages, and one Post-it note on a monitor.
>
> *"The deploy process can't live in someone's head. It needs to be code."*

The decision: automated CI/CD pipelines. Every merge to main triggers a build, a scan, and a deploy. No runbooks. No manual steps. No surprises.

---

## Architecture

```
Feature branch push
    └── CI workflow (ci.yml)
            ├── Build backend + frontend images (linux/amd64)
            ├── Push to Artifact Registry → tagged :SHA + :dev
            ├── Trivy scan — blocks on CRITICAL/HIGH CVEs
            └── SonarCloud analysis — reports quality gate result

Pull request
    └── Lint workflow (lint.yml)
            ├── TFLint   — Terraform best practices
            ├── Hadolint — Dockerfile best practices
            └── yamllint — YAML syntax

Merge to main
    └── CD workflow (cd.yml)
            ├── Build + push images → tagged :SHA + :latest
            ├── Update image tag in charts/backend/values.yaml
            ├── Update image tag in charts/frontend/values.yaml
            └── Commit updated values.yaml → ArgoCD syncs automatically

Authentication (no stored keys):
    GitHub Actions OIDC token
        └── GCP STS token exchange
                └── github-ci service account
                        ├── roles/artifactregistry.writer
                        └── roles/container.developer
```

---

## Repository structure

```
.github/workflows/
├── ci.yml          ← build + push + Trivy scan (feature branches)
├── cd.yml          ← build + push + update values.yaml (main)
├── lint.yml        ← TFLint + Hadolint + yamllint (PRs + main)
└── auto-destroy.yml← nightly Terraform destroy (cost governance)

.pre-commit-config.yaml   ← local hooks: TFLint, Hadolint, yamllint
.yamllint.yml             ← yamllint rules
sonar-project.properties  ← SonarCloud project configuration
```

---

## Prerequisites

- GKE cluster from Phase 1
- Helm charts from Phase 3
- GitHub repository with Actions enabled
- SonarCloud account (free for public repos — sonarcloud.io)

---

## Architecture Decision Records

- `docs/decisions/adr-014-workload-identity-federation.md` — Why Workload Identity Federation over stored service account keys in GitHub secrets
- `docs/decisions/adr-015-sha-tagging.md` — Why git SHA image tags over `:latest` for traceability and rollback
- `docs/decisions/adr-016-sonarcloud-over-sonarqube.md` — Why SonarCloud over self-hosted SonarQube for this lab
- `docs/decisions/adr-017-trivy-in-ci.md` — Why image scanning in CI rather than at the registry level

---

## Challenge 1 — Set up GCP Workload Identity Federation

This challenge configures keyless authentication between GitHub Actions and GCP. No JSON key is ever stored or rotated.

### Step 1: Create the CI service account

```bash
gcloud iam service-accounts create github-ci \
  --display-name="GitHub CI" \
  --project=platform-eng-lab-will
```

### Step 2: Grant least-privilege permissions

```bash
# Push images to Artifact Registry
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:github-ci@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Deploy to GKE via Helm
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:github-ci@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/container.developer"
```

### Step 3: Create the Workload Identity pool and provider

```bash
gcloud iam workload-identity-pools create github-pool \
  --location="global" \
  --project=platform-eng-lab-will

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='wb-platform-engineering-lab/platform-engineering-lab-gke'" \
  --project=platform-eng-lab-will
```

### Step 4: Allow GitHub Actions to impersonate the CI service account

```bash
gcloud iam service-accounts add-iam-policy-binding \
  github-ci@platform-eng-lab-will.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/253419630104/locations/global/workloadIdentityPools/github-pool/attribute.repository/wb-platform-engineering-lab/platform-engineering-lab-gke"
```

### Step 5: Verify — retrieve the provider resource name

```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --workload-identity-pool="github-pool" \
  --location="global" \
  --project=platform-eng-lab-will \
  --format="value(name)"
```

Copy this value — it goes into the `workload_identity_provider` field in the workflow files.

---

## Challenge 2 — Set up SonarCloud

### Step 1: Create the project on SonarCloud

1. Go to [sonarcloud.io](https://sonarcloud.io) and sign in with GitHub
2. Click **Analyze new project** → select this repository
3. Choose **GitHub Actions** as the analysis method
4. Copy the `SONAR_TOKEN` displayed

### Step 2: Add the secret to GitHub

**Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Value |
|---|---|
| `SONAR_TOKEN` | Token copied from SonarCloud |

### Step 3: Create `sonar-project.properties` at the repo root

```properties
sonar.projectKey=wb-platform-engineering-lab_platform-engineering-lab-gke
sonar.organization=wb-platform-engineering-lab
sonar.sources=phase-3-helm/app
sonar.exclusions=**/node_modules/**,**/*.test.js
```

### Step 4: Verify the quality gate

After the first CI run, open the SonarCloud dashboard. The default quality gate requires:
- No new bugs
- No new vulnerabilities
- Code coverage on new code ≥ 80% (can be adjusted)
- No new security hotspots unreviewed

---

## Challenge 3 — Explore the CI workflow

### Step 1: Review `.github/workflows/ci.yml`

```yaml
on:
  push:
    branches-ignore:
      - main
    paths:
      - "phase-3-helm/app/**"
      - ".github/workflows/ci.yml"
```

The `paths` filter means CI only runs when application code or the workflow itself changes. A README update does not trigger a build.

### Step 2: Understand the job steps

| Step | What it does |
|---|---|
| Authenticate to GCP | Exchanges GitHub OIDC token for GCP credentials — no stored key |
| Build & push backend | Builds for `linux/amd64`, pushes `:SHA` and `:dev` tags |
| Trivy scan | Scans the pushed image — exits 1 on CRITICAL/HIGH unfixed CVEs |
| Build & push frontend | Same as backend |
| SonarCloud analysis | Sends source code to SonarCloud, reports quality gate status |

### Step 3: Trigger a CI run manually

Push a change to a feature branch:

```bash
git checkout -b test/ci-check
echo "# test" >> phase-3-helm/app/backend/app.py
git add phase-3-helm/app/backend/app.py
git commit -m "test: trigger CI"
git push origin test/ci-check
```

Go to **Actions → CI — Build & Push** and watch the run. Each step should pass in sequence.

---

## Challenge 4 — Explore the CD workflow and image tag update

### Step 1: Review `.github/workflows/cd.yml`

```yaml
on:
  push:
    branches:
      - main
    paths:
      - "phase-3-helm/app/**"
      - ".github/workflows/cd.yml"
```

CD runs only on merges to `main`. It builds and pushes images tagged `:SHA` and `:latest`, then updates `values.yaml` with the new SHA.

### Step 2: Understand the image tag update

```yaml
- name: Update image tags in values.yaml
  run: |
    sed -i "s/tag: .*/tag: \"${{ github.sha }}\"/" \
      phase-3-helm/charts/backend/values.yaml
    sed -i "s/tag: .*/tag: \"${{ github.sha }}\"/" \
      phase-3-helm/charts/frontend/values.yaml

- name: Commit and push updated values.yaml
  run: |
    git config user.name "github-actions[bot]"
    git add phase-3-helm/charts/backend/values.yaml \
            phase-3-helm/charts/frontend/values.yaml
    git diff --cached --quiet || git commit -m "ci: update image tags to ${{ github.sha }}"
    git push
```

The CD workflow commits the new image tag directly into `values.yaml`. ArgoCD (Phase 5) watches this file and syncs the cluster automatically when it changes.

### Step 3: Verify an image was pushed

```bash
gcloud artifacts docker images list \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline \
  --format="table(IMAGE, TAGS, CREATE_TIME)"
```

---

## Challenge 5 — Install and configure pre-commit hooks

Pre-commit hooks run the same linters locally before a commit reaches CI — catching issues in seconds instead of minutes.

### Step 1: Install pre-commit

```bash
pip install pre-commit
pre-commit install
```

### Step 2: Run against all files

```bash
pre-commit run --all-files
```

### Step 3: Review the hooks

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    hooks:
      - id: terraform_tflint
  - repo: https://github.com/hadolint/hadolint
    hooks:
      - id: hadolint
  - repo: https://github.com/adrienverge/yamllint
    hooks:
      - id: yamllint
```

| Hook | What it checks |
|---|---|
| `terraform_tflint` | Terraform best practices and variable misuse |
| `hadolint` | Dockerfile instructions (layer ordering, pinned versions) |
| `yamllint` | YAML syntax, indentation, trailing spaces |

From this point on, every `git commit` runs these checks automatically. A failed hook blocks the commit and shows exactly what to fix.

---

## Teardown

Workflows are GitHub-hosted and have no cluster cost. To remove the GCP resources created in this phase:

```bash
# Remove CI service account
gcloud iam service-accounts delete \
  github-ci@platform-eng-lab-will.iam.gserviceaccount.com

# Remove Workload Identity pool
gcloud iam workload-identity-pools delete github-pool \
  --location="global" --project=platform-eng-lab-will
```

---

## Cost breakdown

GitHub Actions is free for public repositories. GCP costs come only from the cluster (Phase 1).

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| GitHub Actions minutes | free (public repo) |
| SonarCloud | free (public repo) |
| Artifact Registry storage | ~$0.02 |
| **Phase 4 additional cost** | **~$0.02** |

---

## CI/CD concept: Workload Identity Federation

Traditional CI/CD stores a service account JSON key as a GitHub secret. This key is long-lived, can be leaked, and must be rotated manually.

Workload Identity Federation replaces this with a short-lived OIDC token exchange:

```
GitHub Actions generates a JWT signed by GitHub's OIDC provider
    └── Presented to GCP Security Token Service
            └── GCP verifies the token against the configured provider
                    └── Returns a short-lived access token scoped to github-ci SA
                            └── Token expires when the job ends — nothing to rotate
```

The `attribute-condition` field locks this exchange to a specific repository. Even if someone forks the repo, GitHub Actions in the fork cannot impersonate the `github-ci` service account.

---

## Production considerations

### 1. Add a manual approval gate before production
This lab deploys automatically on every merge to main. In production, a deployment to prod should pause for human approval. GitHub Actions supports `environments` with required reviewers:

```yaml
jobs:
  deploy-prod:
    environment:
      name: production   # pauses until approved in GitHub Settings → Environments
```

### 2. Sign images with cosign
This lab pushes unsigned images. In production, every image should be signed with cosign and verified at admission by Binary Authorization on GKE — guaranteeing that only images built by the official pipeline can run in the cluster. Covered in Phase 10.

### 3. Separate application and config repositories
This lab updates `values.yaml` in the same repo as the application code. The strict GitOps pattern uses two repos: one for application code (triggers CI), one for cluster config (ArgoCD watches it). CI opens a PR against the config repo with the new image tag — it never pushes directly. Implemented in Phase 5.

### 4. Set branch protection rules
This lab has no protection on `main`. In production: require at least one reviewer, require passing CI and SonarCloud quality gate, forbid force pushes and direct commits to main.

### 5. Use self-hosted runners for sensitive workloads
GitHub-hosted runners are shared infrastructure. For a health insurer like CoverLine, builds that process patient data or credentials should run on self-hosted runners inside the GCP VPC — code and artefacts never leave the secure perimeter.

---

## Outcome

Every push to a feature branch builds, scans for CVEs with Trivy, and runs a SonarCloud quality gate automatically. Every merge to main pushes a new image and updates `values.yaml` with the git SHA. Pre-commit hooks catch formatting and security issues before they reach CI. No deploy runbook exists — the pipeline is the runbook.

---

[Back to main README](../README.md) | [Next: Phase 5 — GitOps](../phase-5-gitops/README.md)
