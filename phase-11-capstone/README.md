# Phase 11 — Capstone: The Platform You Wish You'd Had From Day One

---

> **CoverLine — 2,000,000+ covered members. Series C.**
>
> A new CTO joined from a large-scale platform background and ran a full infrastructure review. The verdict was clear:
>
> The platform works. But it was assembled phase by phase under pressure, and it shows. There is no single place to see the health of the entire system. Onboarding a new engineer still takes three days of Slack messages, tribal knowledge, and manual kubectl commands. Deploying to a new country requires manually duplicating Terraform and hoping you remember every environment-specific variable. Some services still have hardcoded config that nobody dares touch because no one fully understands what it feeds.
>
> The security team fixed the worst gaps in Phase 10. The observability stack landed in Phase 6. The CI/CD pipeline matured through Phases 4 and 5. ArgoCD is syncing. Vault is running. Progressive delivery is wired up.
>
> But the pieces do not talk to each other as a platform. They are components, not a system.
>
> The CTO's mandate, written in a shared doc and left open for the whole engineering org to read: *"Build the platform you wish you'd had from day one. Zero manual steps from code to production. Multi-environment. Fully observable. Secure by default. Every service self-documented and discoverable. Done."*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **Multi-environment Terraform** | `dev` / `staging` / `prod` workspaces from one configuration — environment-specific values via var files |
| **ArgoCD ApplicationSets** | One manifest that automatically creates one ArgoCD Application per service per environment from Git |
| **Full GitOps promotion pipeline** | Feature branch → CI (build + Trivy scan) → dev auto-deploy → staging manual gate → prod with second approver |
| **Backstage IDP** | Internal Developer Portal — service catalog, self-service scaffolding, and TechDocs pulled from this repo |
| **Unified Grafana dashboard** | All services in one view: RED metrics per service, node utilisation, SLO burn rate panel |
| **Security baseline as code** | RBAC, NetworkPolicies, and Pod Security Standards wired into the ApplicationSet so every new environment inherits them automatically |

---

## Prerequisites

Phases 1 through 10 must be complete. The capstone layer sits on top of everything built so far — it does not replace any of it.

Start with a clean cluster before running the capstone bootstrap:

```bash
cd phase-1-terraform && terraform apply -var="environment=dev"
gcloud container clusters get-credentials platform-eng-lab-will-gke-dev \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 11
```

Verify everything is running before proceeding:

```bash
kubectl get pods
kubectl get pods -n argocd
kubectl get pods -n monitoring
```

Local tools required:

```bash
brew install terraform helm argocd trivy
npm install -g @backstage/create-app
```

---

## Step 1 — Multi-Environment Terraform

### The problem

The Terraform in `phase-1-terraform` was written for a single cluster. To add staging and prod, engineers have been copying the directory and changing values by hand. When a variable changes in dev it is easy to forget to apply it in the other two environments. State files live locally. There is no audit trail of who changed infrastructure and when.

### Refactor to Terraform workspaces

The cleanest approach for this lab is Terraform workspaces backed by a shared GCS bucket for state, with per-environment var files for overrides.

First, create the state bucket (one-time):

```bash
gsutil mb -p platform-eng-lab-will -l us-central1 gs://platform-eng-lab-will-tf-state
gsutil versioning set on gs://platform-eng-lab-will-tf-state
```

Update `phase-1-terraform/main.tf` to use remote state:

```hcl
terraform {
  backend "gcs" {
    bucket = "platform-eng-lab-will-tf-state"
    prefix = "terraform/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}
```

Create a var file for each environment. `phase-1-terraform/envs/dev.tfvars`:

```hcl
environment    = "dev"
node_count     = 1
machine_type   = "e2-standard-2"
cluster_name   = "platform-eng-lab-will-gke-dev"
min_node_count = 1
max_node_count = 3
```

`phase-1-terraform/envs/staging.tfvars`:

```hcl
environment    = "staging"
node_count     = 2
machine_type   = "e2-standard-4"
cluster_name   = "platform-eng-lab-will-gke-staging"
min_node_count = 1
max_node_count = 5
```

`phase-1-terraform/envs/prod.tfvars`:

```hcl
environment    = "prod"
node_count     = 3
machine_type   = "e2-standard-4"
cluster_name   = "platform-eng-lab-will-gke-prod"
min_node_count = 2
max_node_count = 10
```

Add the corresponding variables to `phase-1-terraform/variables.tf`:

```hcl
variable "environment" {
  description = "Deployment environment: dev, staging, or prod"
  type        = string
}

variable "node_count" {
  description = "Initial node count for the node pool"
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "GCE machine type for cluster nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
}

variable "min_node_count" {
  type    = number
  default = 1
}

variable "max_node_count" {
  type    = number
  default = 3
}
```

Use the workspace commands to provision each environment independently:

```bash
# Create and switch to the dev workspace
terraform -chdir=phase-1-terraform workspace new dev
terraform -chdir=phase-1-terraform workspace select dev
terraform -chdir=phase-1-terraform apply -var-file=envs/dev.tfvars

# Create and switch to staging
terraform -chdir=phase-1-terraform workspace new staging
terraform -chdir=phase-1-terraform workspace select staging
terraform -chdir=phase-1-terraform apply -var-file=envs/staging.tfvars

# Create and switch to prod
terraform -chdir=phase-1-terraform workspace new prod
terraform -chdir=phase-1-terraform workspace select prod
terraform -chdir=phase-1-terraform apply -var-file=envs/prod.tfvars
```

Verify all three clusters exist:

```bash
gcloud container clusters list --project=platform-eng-lab-will
```

Expected output:

```
NAME                              LOCATION     STATUS
platform-eng-lab-will-gke-dev     us-central1  RUNNING
platform-eng-lab-will-gke-staging us-central1  RUNNING
platform-eng-lab-will-gke-prod    us-central1  RUNNING
```

Fetch credentials for all three:

```bash
for env in dev staging prod; do
  gcloud container clusters get-credentials "platform-eng-lab-will-gke-${env}" \
    --region us-central1 \
    --project platform-eng-lab-will
done
```

Verify the kubectl contexts were created:

```bash
kubectl config get-contexts | grep platform-eng-lab-will
```

---

## Step 2 — ArgoCD ApplicationSets

### The problem

With three environments and multiple services, the ArgoCD Application manifest approach from Phase 5 no longer scales. Adding a new service means writing four new Application manifests — one per environment plus one for the top-level app-of-apps. Adding a new environment means touching every service. This is the exact kind of manual overhead the capstone exists to eliminate.

### Replace per-service Applications with a single ApplicationSet

An ApplicationSet uses a generator to produce one ArgoCD Application per combination of cluster and service. The Git generator reads a directory structure. The cluster generator reads ArgoCD's registered clusters. We will use the Matrix generator to combine both.

First, register each cluster with ArgoCD. Run these commands against the cluster where ArgoCD is installed (dev):

```bash
kubectl config use-context gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-dev

argocd login \
  --insecure \
  --grpc-web \
  localhost:8080 \
  --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)"

argocd cluster add \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  --name staging

argocd cluster add \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-prod \
  --name prod
```

Verify the clusters are registered:

```bash
argocd cluster list
```

Expected:

```
SERVER                                                       NAME      STATUS
https://kubernetes.default.svc                               in-cluster  Successful
https://<staging-api-endpoint>                               staging     Successful
https://<prod-api-endpoint>                                  prod        Successful
```

Now create the ApplicationSet. Save this to `phase-11-capstone/argocd/applicationset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: coverline-platform
  namespace: argocd
spec:
  generators:
    - matrix:
        generators:
          # Generator 1: one entry per registered cluster
          - clusters:
              selector:
                matchLabels:
                  argocd.argoproj.io/secret-type: cluster
              values:
                env: "{{name}}"  # 'staging' or 'prod' — or 'in-cluster' for dev
          # Generator 2: one entry per service directory in the Helm charts path
          - git:
              repoURL: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke.git
              revision: HEAD
              directories:
                - path: phase-3-helm/charts/*
  template:
    metadata:
      name: "coverline-{{path.basename}}-{{values.env}}"
      labels:
        environment: "{{values.env}}"
        service: "{{path.basename}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke.git
        targetRevision: HEAD
        path: "{{path}}"
        helm:
          valueFiles:
            - values.yaml
            - "values-{{values.env}}.yaml"
      destination:
        server: "{{server}}"
        namespace: coverline
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Apply the ApplicationSet to ArgoCD:

```bash
kubectl apply -f phase-11-capstone/argocd/applicationset.yaml -n argocd
```

Watch the Applications being generated:

```bash
kubectl get applications -n argocd -w
```

Within two minutes you should see ArgoCD create one Application per service per environment. For example:

```
NAME                              SYNC STATUS   HEALTH STATUS
coverline-backend-staging         Synced        Healthy
coverline-backend-prod            Synced        Healthy
coverline-frontend-staging        Synced        Healthy
coverline-frontend-prod           Synced        Healthy
```

### Per-environment Helm values

For the ApplicationSet `values-{{values.env}}.yaml` override to work, each chart needs an environment-specific values file alongside `values.yaml`. For example, `phase-3-helm/charts/backend/values-prod.yaml`:

```yaml
replicaCount: 3

resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

image:
  tag: ""  # Will be overridden by the CI/CD pipeline with the exact image SHA
```

And `phase-3-helm/charts/backend/values-staging.yaml`:

```yaml
replicaCount: 2

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "250m"
    memory: "256Mi"

image:
  tag: ""
```

---

## Step 3 — Full Promotion Pipeline (dev → staging → prod)

### Pipeline architecture

```
Feature branch pushed
    └── CI: build image + Trivy scan
            └── Image pushed to Artifact Registry with :sha tag

Merge to main
    └── CD: update dev values-dev.yaml with new image SHA
            └── ArgoCD detects values-dev.yaml change → auto-syncs dev cluster

Staging promotion (manual)
    └── workflow_dispatch: update values-staging.yaml with SHA
            └── ArgoCD detects change → syncs staging cluster
                    └── GitHub environment rule: requires 1 approver

Prod promotion (manual + second approver)
    └── workflow_dispatch: update values-prod.yaml with SHA
            └── ArgoCD detects change → syncs prod cluster
                    └── GitHub environment rule: requires 2 approvers
```

### GitHub Actions workflow

Save this to `.github/workflows/platform-pipeline.yml`:

```yaml
name: Platform Pipeline

on:
  push:
    branches:
      - main
      - "feature/**"
  workflow_dispatch:
    inputs:
      image_sha:
        description: "Image SHA to promote (e.g. abc1234)"
        required: true
      target_env:
        description: "Target environment: staging or prod"
        required: true
        type: choice
        options:
          - staging
          - prod

env:
  REGISTRY: us-central1-docker.pkg.dev/platform-eng-lab-will/coverline
  PROJECT: platform-eng-lab-will
  REGION: us-central1

jobs:
  # ── CI: runs on every push to any branch ─────────────────────────────────
  ci:
    name: Build and Scan
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
    outputs:
      image_sha: ${{ steps.meta.outputs.sha }}

    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account: ${{ secrets.WIF_SERVICE_ACCOUNT }}

      - name: Configure Docker for Artifact Registry
        run: gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

      - name: Set image SHA output
        id: meta
        run: echo "sha=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - name: Build backend image
        run: |
          docker build \
            -t ${{ env.REGISTRY }}/backend:${{ steps.meta.outputs.sha }} \
            phase-3-helm/app/backend/

      - name: Scan backend image for CVEs
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin
          trivy image \
            --severity CRITICAL,HIGH \
            --exit-code 1 \
            --ignore-unfixed \
            ${{ env.REGISTRY }}/backend:${{ steps.meta.outputs.sha }}

      - name: Build frontend image
        run: |
          docker build \
            -t ${{ env.REGISTRY }}/frontend:${{ steps.meta.outputs.sha }} \
            phase-3-helm/app/frontend/

      - name: Scan frontend image for CVEs
        run: |
          trivy image \
            --severity CRITICAL,HIGH \
            --exit-code 1 \
            --ignore-unfixed \
            ${{ env.REGISTRY }}/frontend:${{ steps.meta.outputs.sha }}

      - name: Push images (main branch only)
        if: github.ref == 'refs/heads/main'
        run: |
          docker push ${{ env.REGISTRY }}/backend:${{ steps.meta.outputs.sha }}
          docker push ${{ env.REGISTRY }}/frontend:${{ steps.meta.outputs.sha }}

  # ── CD: auto-deploys to dev on every merge to main ───────────────────────
  deploy-dev:
    name: Deploy to dev
    needs: ci
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: write
      id-token: write

    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Update dev image tag
        run: |
          SHA=${{ needs.ci.outputs.image_sha }}
          # Patch the image tag in each chart's dev values file
          for chart in backend frontend; do
            VALUES="phase-3-helm/charts/${chart}/values-dev.yaml"
            # Use yq to update the tag field
            yq eval ".image.tag = \"${SHA}\"" -i "$VALUES"
          done

      - name: Commit and push values change
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add phase-3-helm/charts/*/values-dev.yaml
          git commit -m "chore(dev): deploy image sha ${{ needs.ci.outputs.image_sha }}"
          git push

  # ── Manual promotion: staging or prod ────────────────────────────────────
  promote:
    name: Promote to ${{ github.event.inputs.target_env }}
    runs-on: ubuntu-latest
    if: github.event_name == 'workflow_dispatch'
    environment: ${{ github.event.inputs.target_env }}  # triggers protection rules
    permissions:
      contents: write
      id-token: write

    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Update ${{ github.event.inputs.target_env }} image tag
        run: |
          SHA=${{ github.event.inputs.image_sha }}
          ENV=${{ github.event.inputs.target_env }}
          for chart in backend frontend; do
            VALUES="phase-3-helm/charts/${chart}/values-${ENV}.yaml"
            yq eval ".image.tag = \"${SHA}\"" -i "$VALUES"
          done

      - name: Commit and push values change
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          ENV=${{ github.event.inputs.target_env }}
          git add phase-3-helm/charts/*/values-${ENV}.yaml
          git commit -m "chore(${ENV}): promote image sha ${{ github.event.inputs.image_sha }}"
          git push
```

### GitHub environment protection rules

Set up approval requirements in the GitHub repository settings. These rules gate the `promote` job before it runs.

Navigate to **Settings → Environments** in the GitHub repository.

For the `staging` environment:
- Required reviewers: 1 (e.g. a tech lead)
- Deployment branches: `main` only
- Wait timer: none

For the `prod` environment:
- Required reviewers: 2 (e.g. tech lead + CTO or SRE lead)
- Deployment branches: `main` only
- Wait timer: optional 5-minute delay to allow cancellation

With these rules, the `promote` job pauses at the `environment: prod` line and GitHub sends review requests to the configured approvers. The job does not continue until both have approved in the GitHub UI.

To trigger a promotion after a successful dev deploy:

```bash
# Get the SHA from the last dev deploy commit
SHA=$(git log --oneline | grep "chore(dev)" | head -1 | grep -oP '(?<=sha )\w+')
echo "Promoting SHA: $SHA"

# Trigger the workflow — GitHub will request approvals from configured reviewers
gh workflow run platform-pipeline.yml \
  -f image_sha="$SHA" \
  -f target_env=staging
```

---

## Step 4 — Install Backstage

### Why an internal developer portal

At 200 engineers across three time zones, the cost of tribal knowledge is measurable. A new engineer joining CoverLine's platform team needs to know: which team owns which service, where the runbook is, what the current SLO is, how to scaffold a new service without copy-pasting a template from Slack. Backstage provides all of this in one place, pulled directly from Git — so it is always current.

### Install Backstage via Helm

Add the Backstage Helm repository:

```bash
helm repo add backstage https://backstage.github.io/charts
helm repo update
```

Create a namespace and a values file:

```bash
kubectl create namespace backstage
```

Save the following to `phase-11-capstone/backstage/values.yaml`:

```yaml
backstage:
  image:
    registry: ghcr.io
    repository: backstage/backstage
    tag: latest

  appConfig:
    app:
      title: CoverLine Developer Portal
      baseUrl: http://localhost:7007

    backend:
      baseUrl: http://localhost:7007
      listen:
        port: 7007

    integrations:
      github:
        - host: github.com
          token: ${GITHUB_TOKEN}

    catalog:
      providers:
        github:
          coverlineOrg:
            organization: wb-platform-engineering-lab
            catalogPath: /catalog-info.yaml
            filters:
              branch: main
            schedule:
              frequency: { minutes: 30 }
              timeout: { minutes: 3 }

      rules:
        - allow: [Component, System, API, Resource, Location]

    techdocs:
      builder: external
      generator:
        runIn: local
      publisher:
        type: googleGcs
        googleGcs:
          bucketName: platform-eng-lab-will-techdocs

postgresql:
  enabled: true
  auth:
    password: backstage-local-dev-only

ingress:
  enabled: false
```

Install Backstage:

```bash
helm install backstage backstage/backstage \
  --namespace backstage \
  --values phase-11-capstone/backstage/values.yaml \
  --set backstage.extraEnvVars[0].name=GITHUB_TOKEN \
  --set backstage.extraEnvVars[0].value="$(vault kv get -field=github_token secret/coverline/backstage)"
```

Access the Backstage UI:

```bash
kubectl port-forward -n backstage svc/backstage 7007:7007
# Open http://localhost:7007
```

### catalog-info.yaml for the backend service

Add this file to the root of the repo as `catalog-info.yaml` and also save a copy to `phase-3-helm/app/backend/catalog-info.yaml`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: coverline-backend
  description: CoverLine claims processing API
  annotations:
    github.com/project-slug: wb-platform-engineering-lab/platform-engineering-lab-gke
    backstage.io/techdocs-ref: dir:.
    prometheus.io/alert: coverline-backend-error-rate
  tags:
    - python
    - flask
    - api
    - claims
  links:
    - url: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke/blob/main/phase-3-helm/app/backend/
      title: Source Code
    - url: https://grafana.coverline.internal/d/platform-overview
      title: Grafana Dashboard
spec:
  type: service
  lifecycle: production
  owner: platform-team
  system: coverline-platform
  providesApis:
    - coverline-claims-api
  dependsOn:
    - resource:default/postgresql
    - resource:default/redis
```

`phase-3-helm/app/frontend/catalog-info.yaml`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: coverline-frontend
  description: CoverLine member-facing web application
  annotations:
    github.com/project-slug: wb-platform-engineering-lab/platform-engineering-lab-gke
    backstage.io/techdocs-ref: dir:.
  tags:
    - nodejs
    - frontend
    - react
  links:
    - url: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke/blob/main/phase-3-helm/app/frontend/
      title: Source Code
spec:
  type: website
  lifecycle: production
  owner: platform-team
  system: coverline-platform
  consumesApis:
    - coverline-claims-api
  dependsOn:
    - component:default/coverline-backend
```

The System and API entities that tie these together:

```yaml
---
apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: coverline-platform
  description: CoverLine's core insurance processing platform
spec:
  owner: platform-team
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: coverline-claims-api
  description: REST API for submitting and querying health insurance claims
spec:
  type: openapi
  lifecycle: production
  owner: platform-team
  system: coverline-platform
  definition: |
    openapi: 3.0.0
    info:
      title: CoverLine Claims API
      version: 1.0.0
    paths:
      /health:
        get:
          summary: Health check
          responses:
            "200":
              description: OK
      /claims:
        post:
          summary: Submit a claim
          responses:
            "201":
              description: Claim created
```

Verify Backstage discovered the catalog entries:

```bash
# Check the catalog import logs
kubectl logs -n backstage deploy/backstage | grep -i "catalog\|discovered\|import"
```

---

## Step 5 — Unified Grafana Dashboard

### The problem

There are currently separate dashboards per service, per phase, and per concern. When an incident happens, the on-call engineer opens four browser tabs and tries to correlate timelines manually. The capstone replaces this with a single dashboard that covers the entire platform at a glance.

### Create the platform overview dashboard

The dashboard is provisioned as a ConfigMap so ArgoCD manages it like any other resource. Save this to `phase-11-capstone/grafana/platform-overview-dashboard.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  platform-overview.json: |
    {
      "title": "CoverLine Platform Overview",
      "uid": "platform-overview",
      "refresh": "30s",
      "time": { "from": "now-1h", "to": "now" },
      "panels": [
        {
          "title": "Request Rate (req/s) — all services",
          "type": "timeseries",
          "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "sum(rate(flask_http_request_total[2m])) by (service)",
              "legendFormat": "{{service}}"
            }
          ]
        },
        {
          "title": "Error Rate (5xx / total) — all services",
          "type": "timeseries",
          "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "sum(rate(flask_http_request_total{status=~\"5..\"}[2m])) by (service) / sum(rate(flask_http_request_total[2m])) by (service)",
              "legendFormat": "{{service}} error rate"
            }
          ]
        },
        {
          "title": "P95 Latency (ms) — backend",
          "type": "timeseries",
          "gridPos": { "x": 0, "y": 8, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "histogram_quantile(0.95, sum(rate(flask_http_request_duration_seconds_bucket[5m])) by (le, service)) * 1000",
              "legendFormat": "{{service}} p95"
            }
          ]
        },
        {
          "title": "Node CPU Utilisation (%)",
          "type": "timeseries",
          "gridPos": { "x": 12, "y": 8, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "100 - (avg by(node) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
              "legendFormat": "{{node}}"
            }
          ]
        },
        {
          "title": "Node Memory Utilisation (%)",
          "type": "timeseries",
          "gridPos": { "x": 0, "y": 16, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100",
              "legendFormat": "{{instance}}"
            }
          ]
        },
        {
          "title": "PostgreSQL Active Connections",
          "type": "timeseries",
          "gridPos": { "x": 12, "y": 16, "w": 12, "h": 8 },
          "targets": [
            {
              "expr": "pg_stat_activity_count",
              "legendFormat": "active connections"
            }
          ]
        },
        {
          "title": "SLO — 99.9% Availability (30-day window)",
          "type": "stat",
          "gridPos": { "x": 0, "y": 24, "w": 8, "h": 6 },
          "options": {
            "colorMode": "background",
            "thresholds": {
              "steps": [
                { "color": "red",   "value": 0 },
                { "color": "yellow", "value": 0.995 },
                { "color": "green",  "value": 0.999 }
              ]
            }
          },
          "targets": [
            {
              "expr": "1 - (sum(increase(flask_http_request_total{status=~\"5..\"}[30d])) / sum(increase(flask_http_request_total[30d])))",
              "legendFormat": "Availability"
            }
          ]
        },
        {
          "title": "SLO Burn Rate (1-hour window)",
          "description": "Burn rate > 14.4 means you will exhaust the 30-day error budget within 1 hour.",
          "type": "stat",
          "gridPos": { "x": 8, "y": 24, "w": 8, "h": 6 },
          "options": {
            "colorMode": "background",
            "thresholds": {
              "steps": [
                { "color": "green",  "value": 0 },
                { "color": "yellow", "value": 1 },
                { "color": "red",    "value": 14.4 }
              ]
            }
          },
          "targets": [
            {
              "expr": "(sum(rate(flask_http_request_total{status=~\"5..\"}[1h])) / sum(rate(flask_http_request_total[1h]))) / 0.001",
              "legendFormat": "Burn rate"
            }
          ]
        },
        {
          "title": "Error Budget Remaining (30-day, minutes)",
          "type": "stat",
          "gridPos": { "x": 16, "y": 24, "w": 8, "h": 6 },
          "targets": [
            {
              "expr": "(0.001 - (sum(increase(flask_http_request_total{status=~\"5..\"}[30d])) / sum(increase(flask_http_request_total[30d])))) * 30 * 24 * 60",
              "legendFormat": "Budget remaining (min)"
            }
          ]
        }
      ]
    }
```

Apply the ConfigMap — Grafana's sidecar will pick it up automatically:

```bash
kubectl apply -f phase-11-capstone/grafana/platform-overview-dashboard.yaml
```

Verify the dashboard was loaded:

```bash
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard | tail -20
```

You should see a log line confirming `platform-overview.json` was imported. Open Grafana at `http://localhost:3000` (after port-forwarding) and navigate to **Dashboards → CoverLine Platform Overview**.

---

## Step 6 — Security Baseline as Code

### The problem

The RBAC, NetworkPolicies, and Pod Security contexts from Phase 10 were applied manually with `kubectl apply`. They exist in the dev cluster. They do not exist in staging or prod yet. When a new environment is created via Terraform and the ApplicationSet generates its Applications, there is nothing to enforce these controls automatically.

The fix: wire the security manifests into ArgoCD as a dedicated Application so they are applied to every cluster, and reference them from the ApplicationSet so new environments inherit them on creation.

### Create a security baseline Application

Save this to `phase-11-capstone/argocd/security-baseline-appset.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: coverline-security-baseline
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            argocd.argoproj.io/secret-type: cluster
        values:
          env: "{{name}}"
  template:
    metadata:
      name: "security-baseline-{{values.env}}"
      labels:
        component: security
        environment: "{{values.env}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke.git
        targetRevision: HEAD
        path: phase-10-security
      destination:
        server: "{{server}}"
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Apply it:

```bash
kubectl apply -f phase-11-capstone/argocd/security-baseline-appset.yaml -n argocd
```

This generates one ArgoCD Application per cluster (dev, staging, prod) that continuously reconciles the Phase 10 security manifests. If someone deletes a NetworkPolicy directly with kubectl, ArgoCD restores it within 3 minutes because `selfHeal: true` is set.

Verify the security Applications were generated:

```bash
kubectl get applications -n argocd | grep security
```

Expected:

```
security-baseline-dev       Synced   Healthy
security-baseline-staging   Synced   Healthy
security-baseline-prod      Synced   Healthy
```

### Verify NetworkPolicies exist on all clusters

```bash
for ctx in \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-dev \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-prod; do
  echo "=== $ctx ==="
  kubectl --context="$ctx" get networkpolicy
done
```

All three should show the same set of policies from Phase 10.

### Verify Pod Security Standards are enforced

Attempt to create a privileged pod in each environment (should be rejected):

```bash
for ctx in \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-prod; do
  echo "=== Testing $ctx ==="
  kubectl --context="$ctx" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: default
spec:
  containers:
    - name: test
      image: busybox
      securityContext:
        privileged: true
EOF
done
```

Expected: both attempts should fail with a policy violation error.

---

## Step 7 — Verify the Full Platform

Run through the end-to-end test in order. Each step corresponds to a real production scenario.

### 1. Push a feature branch — CI runs, image is built and scanned

```bash
git checkout -b feature/test-capstone-pipeline
echo "# capstone test" >> phase-3-helm/app/backend/app.py
git add phase-3-helm/app/backend/app.py
git commit -m "test: trigger capstone CI pipeline"
git push origin feature/test-capstone-pipeline
```

Open the GitHub Actions tab. The `ci` job should start. Confirm the Trivy scan step passes.

### 2. Merge to main — dev updates automatically

```bash
gh pr create --title "test: capstone pipeline verification" --body "End-to-end capstone test."
gh pr merge --merge
```

Watch ArgoCD detect the values change and sync dev:

```bash
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-dev \
  get pods -w
```

The backend pod should cycle within 2–3 minutes of the merge.

### 3. Trigger staging promotion — manual approval required

```bash
SHA=$(git log --oneline | grep "chore(dev)" | head -1 | grep -oP '(?<=sha )\w+')
gh workflow run platform-pipeline.yml \
  -f image_sha="$SHA" \
  -f target_env=staging
```

GitHub will pause the workflow and request approval from the configured reviewer. After approval:

```bash
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  rollout status deploy/coverline-backend
```

### 4. Verify all services healthy in Grafana

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` and navigate to the **CoverLine Platform Overview** dashboard. Confirm:

- Request rate is non-zero for backend and frontend
- Error rate is 0%
- P95 latency is under 200 ms
- SLO panel shows availability above 99.9%

### 5. Verify RBAC and NetworkPolicies are applied in the new environments

```bash
# RBAC: confirm CI service account has only scoped permissions in staging
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  auth can-i get secrets --as=system:serviceaccount:default:coverline-ci
# Expected: no

# NetworkPolicies: confirm default-deny exists in staging
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-staging \
  get networkpolicy default-deny-all

# NetworkPolicies: confirm frontend cannot reach PostgreSQL in prod
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-gke-prod \
  exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- --timeout=3 http://postgresql:5432 || echo "BLOCKED — policy working"
```

### 6. Open Backstage — confirm all services appear in catalog

```bash
kubectl port-forward -n backstage svc/backstage 7007:7007
```

Open `http://localhost:7007/catalog`. You should see:

- `coverline-backend` — Component, production
- `coverline-frontend` — Component, production
- `coverline-platform` — System
- `coverline-claims-api` — API

Click `coverline-backend` and confirm the TechDocs tab renders the Phase 3 README, and the Grafana link in the links panel opens the platform overview dashboard.

---

## Troubleshooting

### ArgoCD ApplicationSet not generating Applications

Check the ApplicationSet controller logs:

```bash
kubectl logs -n argocd deploy/argocd-applicationset-controller | tail -50
```

The most common cause is the Git generator path not matching any directories. Verify the path pattern in the ApplicationSet against the actual directory structure:

```bash
ls phase-3-helm/charts/
```

If using the cluster generator, confirm the clusters are registered with the expected labels:

```bash
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
```

If no secrets are listed, the clusters were not registered via `argocd cluster add`. Rerun the registration commands from Step 2.

### Terraform workspace state conflicts

If two workspaces share state, Terraform will report resource conflicts on apply. Confirm each workspace has its own state path:

```bash
gsutil ls gs://platform-eng-lab-will-tf-state/terraform/state/
```

You should see separate directories for `env:/dev`, `env:/staging`, and `env:/prod`. If they are missing, the workspace was never initialised. Run:

```bash
terraform -chdir=phase-1-terraform workspace select dev
terraform -chdir=phase-1-terraform init
```

### Backstage catalog not discovering services

The GitHub integration requires a token with `repo` and `read:org` scope. Verify the token is present and has the correct permissions:

```bash
kubectl get secret -n backstage backstage-github-token -o jsonpath='{.data.token}' | base64 -d | xargs -I{} \
  curl -s -H "Authorization: token {}" https://api.github.com/repos/wb-platform-engineering-lab/platform-engineering-lab-gke
```

If the response is `404 Not Found`, the token lacks repo access. Generate a new token and update the secret:

```bash
kubectl create secret generic backstage-github-token \
  --from-literal=token="<new-token>" \
  -n backstage \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/backstage -n backstage
```

Also confirm the `catalog-info.yaml` files exist at the paths referenced in the Backstage values:

```bash
ls phase-3-helm/app/backend/catalog-info.yaml
ls phase-3-helm/app/frontend/catalog-info.yaml
```

### NetworkPolicies blocking ArgoCD sync

ArgoCD syncs resources by reaching out to the API server and creating resources in destination namespaces. If a default-deny NetworkPolicy is applied to the `argocd` namespace, the ArgoCD application controller will lose connectivity.

Add an explicit allow rule for the ArgoCD namespace in your NetworkPolicy set. Add this to `phase-10-security/network-policies.yaml`:

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-argocd-egress
  namespace: argocd
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - {}  # Allow all egress from argocd namespace — ArgoCD needs to reach the API server and all cluster namespaces
```

Apply the fix and trigger a manual sync:

```bash
kubectl apply -f phase-10-security/network-policies.yaml
argocd app sync security-baseline-dev
```

### values-\<env\>.yaml missing causes ApplicationSet sync failure

The ApplicationSet template references `values-{{values.env}}.yaml`. If this file does not exist in the chart directory, Helm will fail with a `no such file` error. Ensure all three override files exist before the ApplicationSet is applied:

```bash
for env in dev staging prod; do
  for chart in backend frontend; do
    touch phase-3-helm/charts/${chart}/values-${env}.yaml
  done
done
```

Empty files are valid — Helm will use the base `values.yaml` for anything not overridden.

---

## Production Considerations

**GitOps for everything.** Every cluster state change goes through Git. No one runs `kubectl apply` by hand in staging or prod. If a fix is urgent enough to skip a PR, it is urgent enough to be reviewed within the hour and reverted if wrong. The audit trail is the PR history.

**Image immutability.** The promotion pipeline always references a 7-character SHA. The strings `:latest` and `:main` never appear in production `values.yaml` files. If a deployment is rolled back, the exact image that was running can be re-deployed by reverting the values commit in Git.

**Separate GCP projects per environment.** The lab uses separate clusters in the same project for cost reasons. In production, dev, staging, and prod should be in separate GCP projects. This provides blast-radius isolation (a misconfigured IAM policy in dev cannot affect prod), separate billing, and separate audit log streams that satisfy compliance requirements.

**Backstage as the single pane of glass.** Every service has a `catalog-info.yaml`. Every service links to its runbook, its Grafana dashboard, and its on-call rotation. When an incident starts, the on-call engineer opens the Backstage service page — not Slack, not a wiki, not a shared Google Doc that was last updated eight months ago.

**Progressive rollout to prod.** The promotion pipeline merges a values change to Git. ArgoCD applies it. All prod replicas update simultaneously via a rolling deployment. For a true production system, replace the rolling update in prod with an Argo Rollout (Phase 5b) configured with a canary strategy: 10% of traffic to the new version for 10 minutes, automated metric analysis against the SLO panel, then full promotion or automatic rollback.

**Vault for all secrets.** No environment-specific passwords, API keys, or tokens appear in `values-<env>.yaml` files. The Vault policies from Phase 7 are scoped per environment — a pod in staging cannot read a secret path that belongs to prod. Verify this after setting up each cluster:

```bash
vault policy read coverline-staging
vault policy read coverline-prod
```

**Regular DR drills.** The Terraform workspace approach means you can provision a fresh prod cluster from scratch with one command. Run a DR drill quarterly: spin up a new cluster, apply the ApplicationSet, restore the database from the latest snapshot, verify all services are healthy. Time it. The target for a platform this size is under 45 minutes to full operational status.

---

[📝 Take the Phase 11 quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-11-capstone/quiz.html)
