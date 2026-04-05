# Phase 4 — CI/CD Pipelines

## What was built

- GitHub Actions CI pipeline: builds and pushes Docker images to Artifact Registry on every feature branch push
- GitHub Actions CD pipeline: builds, pushes, and deploys to GKE via Helm on every merge to main
- Images tagged with git SHA for full traceability
- GCP Workload Identity Federation — no long-lived JSON keys stored in GitHub secrets
- Dedicated `github-ci` service account with least-privilege permissions

## Pipelines

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Push to any branch except main | Build + push images tagged with SHA and `dev` |
| `cd.yml` | Push to main (app or workflow changes) | Build + push images tagged with SHA and `latest`, deploy via Helm |
| `lint.yml` | PR or push to main | TFLint + Hadolint + yamllint |
| `auto-destroy.yml` | Nightly 8 PM UTC | Destroy all Terraform-managed GCP resources |

## Pre-commit hooks

Linters also run locally before every commit via [pre-commit](https://pre-commit.com):

```bash
# Install pre-commit (once)
pip install pre-commit
pre-commit install

# Run manually on all files
pre-commit run --all-files
```

| Hook | Tool | What it checks |
|---|---|---|
| `tflint` | TFLint | Terraform best practices and errors |
| `hadolint` | Hadolint | Dockerfile best practices |
| `yamllint` | yamllint | YAML syntax and formatting |

Config: `.pre-commit-config.yaml` and `.yamllint.yml` at repo root.

## Authentication — Workload Identity Federation

GitHub Actions authenticates to GCP without any stored credentials using OIDC:

```
GitHub Actions job
    └── requests OIDC token from GitHub
            └── exchanges token at GCP STS
                    └── assumes github-ci service account
                            └── pushes to Artifact Registry
                            └── deploys to GKE
```

No `GCP_SA_KEY` secret needed. The identity is scoped to this specific repository.

## GCP Setup

```bash
# Create CI service account
gcloud iam service-accounts create github-ci --display-name="GitHub CI" --project=platform-eng-lab-will

# Grant Artifact Registry write access
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:github-ci@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

# Grant GKE deploy access
gcloud projects add-iam-policy-binding platform-eng-lab-will \
  --member="serviceAccount:github-ci@platform-eng-lab-will.iam.gserviceaccount.com" \
  --role="roles/container.developer"

# Create Workload Identity pool and provider
gcloud iam workload-identity-pools create github-pool \
  --location="global" --project=platform-eng-lab-will

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='wb-platform-engineering-lab/platform-engineering-lab-gke'" \
  --project=platform-eng-lab-will

# Allow GitHub Actions to impersonate the CI SA
gcloud iam service-accounts add-iam-policy-binding \
  github-ci@platform-eng-lab-will.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/253419630104/locations/global/workloadIdentityPools/github-pool/attribute.repository/wb-platform-engineering-lab/platform-engineering-lab-gke"
```

## Troubleshooting

### 1. `gke-gcloud-auth-plugin not found` in CD workflow

**Fix:** The plugin must be installed on the runner before calling Helm:
```yaml
- name: Install gke-gcloud-auth-plugin
  run: gcloud components install gke-gcloud-auth-plugin --quiet
```

### 2. CD workflow not triggering after merge

**Cause:** The `paths` filter — CD only triggers when files matching the paths change.

**Fix:** Ensure the merge includes changes to `phase-3-helm/app/**` or `.github/workflows/cd.yml`.

### 3. `helm upgrade` fails — release not found

**Fix:** Use `--install` flag so Helm creates the release if it doesn't exist:
```bash
helm upgrade --install coverline phase-3-helm/charts/backend/
```
