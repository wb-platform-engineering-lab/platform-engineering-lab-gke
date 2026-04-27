# Phase 11 — Capstone: The Platform You Wish You'd Had From Day One

> **Platform concepts introduced:** multi-environment Terraform, ArgoCD ApplicationSets, GitOps promotion pipeline, Backstage IDP, unified SLO dashboard, security baseline as code | **Builds on:** all previous phases

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-11-capstone/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Multi-environment Terraform** | Separate `dev` / `staging` / `prod` directories sharing common modules | Environment isolation with a single source of truth — changes in one env cannot bleed into another |
| **ArgoCD ApplicationSet** | One manifest that generates one ArgoCD Application per service per environment | Adding a new service or environment no longer requires writing new manifests by hand |
| **Promotion pipeline** | Feature branch → CI → dev auto-deploy → staging manual gate → prod with approver | The same image SHA travels through every environment — no rebuilds, no drift |
| **Backstage IDP** | Service catalog, TechDocs, and Kubernetes plugin pulled from Git | Every service is self-documented and discoverable — onboarding takes minutes, not days |
| **Unified Grafana dashboard** | RED metrics, node utilisation, SLO burn rate, and error budget in one view | On-call engineers see the entire platform in one tab instead of four |
| **Security baseline as code** | RBAC, NetworkPolicies, and Pod Security Standards managed by ArgoCD | New environments inherit security controls automatically on creation |

---

## The problem

> *CoverLine — 2,000,000+ covered members. Series C.*
>
> A new CTO joined from a large-scale platform background and ran a full infrastructure review. The verdict was clear:
>
> The platform works. But it was assembled phase by phase under pressure, and it shows. There is no single place to see the health of the entire system. Onboarding a new engineer still takes three days of Slack messages and manual kubectl commands. Deploying to a new country requires manually duplicating Terraform and hoping every environment-specific variable is correct. Some services still have hardcoded config that nobody dares touch because no one fully understands what it feeds.
>
> The security team fixed the worst gaps in Phase 10. The observability stack landed in Phase 6. The CI/CD pipeline matured through Phases 4 and 5. ArgoCD is syncing. Vault is running. Progressive delivery is wired up.
>
> But the pieces do not talk to each other as a platform. They are components, not a system.
>
> *"Build the platform you wish you'd had from day one. Zero manual steps from code to production. Multi-environment. Fully observable. Secure by default. Every service self-documented and discoverable. Done."*

---

## Architecture

```
Git (main branch)
    │
    ├── phase-1-terraform/envs/{dev,staging,prod}/
    │       └── Shared modules → 3 independent GKE clusters with isolated state
    │
    ├── phase-4-helm/charts/{backend,frontend}/
    │       ├── values.yaml           ← base config
    │       ├── values-dev.yaml       ← dev overrides (patched by CI on merge)
    │       ├── values-staging.yaml   ← staging overrides (patched on approval)
    │       └── values-prod.yaml      ← prod overrides (patched on approval)
    │
    └── phase-11-capstone/argocd/applicationset.yaml
            │
            └── Matrix generator (clusters × chart directories)
                    └── Generates one Application per service per environment
                            └── ArgoCD auto-syncs each cluster on values change

Promotion flow:
    Push → CI (Trivy scan) → push :sha → patch values-dev.yaml
        → ArgoCD syncs dev (automatic)
        → gh workflow run (staging) → 1 approver → patch values-staging.yaml
        → ArgoCD syncs staging (automatic)
        → gh workflow run (prod) → 1 approver → patch values-prod.yaml
        → ArgoCD syncs prod (automatic)
```

---

## Repository structure

```
phase-11-capstone/
├── argocd/
│   ├── applicationset.yaml          ← Matrix generator: clusters × chart dirs
│   └── security-baseline-appset.yaml ← Applies Phase 10 security to all clusters
├── backstage/
│   └── values.yaml                  ← Backstage Helm values
└── grafana/
    └── platform-overview-dashboard.yaml ← ConfigMap provisioned into Grafana
```

---

## Prerequisites

Phases 1 through 10 must be complete. The capstone layer sits on top of everything built so far.

Start with a running dev cluster:

```bash
cd phase-1-terraform/envs/dev
terraform init && terraform apply -var-file=dev.tfvars
gcloud container clusters get-credentials platform-eng-lab-will-dev-gke \
  --region us-central1 --project platform-eng-lab-will
cd ../../.. && bash bootstrap.sh --phase 11
```

Verify the foundation is in place:

```bash
kubectl get pods
kubectl get pods -n argocd
kubectl get pods -n monitoring
```

Local tools required:

```bash
brew install terraform helm argocd
npm install -g @backstage/create-app
```

---

## Architecture Decision Records

- `docs/decisions/adr-043-env-dirs-over-tf-workspaces.md` — Why separate environment directories over Terraform workspaces for stronger blast-radius isolation
- `docs/decisions/adr-044-applicationset-matrix-generator.md` — Why the Matrix generator over App of Apps for scaling to multiple environments
- `docs/decisions/adr-045-backstage-over-internal-wiki.md` — Why Backstage over a Confluence/Notion wiki for service documentation
- `docs/decisions/adr-046-github-environments-for-promotion-gates.md` — Why GitHub Environments over ArgoCD sync windows for manual promotion approval

---

## Challenge 1 — Verify multi-environment Terraform

The Terraform in `phase-1-terraform` uses **separate directories per environment** under `envs/`. Each directory has its own `backend.tf` pointing to a different GCS prefix, its own `*.tfvars`, and calls the same shared modules in `modules/`. This gives stronger isolation than workspaces — a `terraform apply` in `envs/dev/` cannot accidentally affect staging state.

### Step 1: Review the environment structure

```
phase-1-terraform/
├── modules/
│   ├── gke/
│   └── networking/
└── envs/
    ├── dev/      backend prefix: dev/terraform/state
    ├── staging/  backend prefix: staging/terraform/state
    └── prod/     backend prefix: prod/terraform/state
```

Each environment's `main.tf` calls the shared modules with a naming prefix that includes the environment:

```hcl
locals {
  naming_prefix = "${var.project_id}-${var.environment}"
}
```

| Variable | dev | staging | prod |
|---|---|---|---|
| `machine_type` | `e2-medium` | `e2-standard-2` | `e2-medium` |
| `max_node_count` | 1 | 2 | 2 |
| `subnetwork_cidr` | `10.10.0.0/16` | `10.40.0.0/16` | `10.70.0.0/16` |

Non-overlapping CIDRs matter if you ever peer the VPCs or run a shared VPN.

### Step 2: Provision staging and prod clusters

```bash
# Staging
cd phase-1-terraform/envs/staging
terraform init
terraform apply -var-file=staging.tfvars

# Prod
cd ../prod
terraform init
terraform apply -var-file=prod.tfvars
```

### Step 3: Verify all three clusters exist

```bash
gcloud container clusters list --project=platform-eng-lab-will
```

Expected:

```
NAME                                   LOCATION     STATUS
platform-eng-lab-will-dev-gke          us-central1  RUNNING
platform-eng-lab-will-staging-gke      us-central1  RUNNING
platform-eng-lab-will-prod-gke         us-central1  RUNNING
```

### Step 4: Fetch credentials for all three

```bash
for env in dev staging prod; do
  gcloud container clusters get-credentials "platform-eng-lab-will-${env}-gke" \
    --region us-central1 --project platform-eng-lab-will
done
kubectl config get-contexts | grep platform-eng-lab-will
```

---

## Challenge 2 — Deploy the ArgoCD ApplicationSet

With three environments and multiple services, the Phase 6 approach of writing one ArgoCD Application manifest per service per environment does not scale. An **ApplicationSet** uses a Matrix generator to produce one Application per combination of cluster and chart directory automatically.

### Step 1: Register staging and prod clusters with ArgoCD

Run these commands against the cluster where ArgoCD is installed (dev):

```bash
kubectl config use-context gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-dev-gke

argocd login --insecure --grpc-web localhost:8080 \
  --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d)"

argocd cluster add \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-staging-gke \
  --name staging

argocd cluster add \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-prod-gke \
  --name prod
```

Verify:

```bash
argocd cluster list
```

### Step 2: Create per-environment Helm values files

The ApplicationSet template references `values-{{env}}.yaml`. Each chart needs one per environment:

```bash
for env in dev staging prod; do
  for chart in backend frontend; do
    touch "phase-4-helm/charts/${chart}/values-${env}.yaml"
  done
done
```

Populate `phase-4-helm/charts/backend/values-staging.yaml`:

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

### Step 3: Apply the ApplicationSet

```bash
kubectl apply -f phase-11-capstone/argocd/applicationset.yaml -n argocd
```

The ApplicationSet at `phase-11-capstone/argocd/applicationset.yaml` uses a Matrix generator combining registered clusters with chart directories in `phase-4-helm/charts/*`. For each combination it generates one Application named `coverline-{chart}-{env}`.

### Step 4: Verify Applications are generated

```bash
kubectl get applications -n argocd -w
```

Expected within two minutes:

```
NAME                          SYNC STATUS   HEALTH STATUS
coverline-backend-staging     Synced        Healthy
coverline-backend-prod        Synced        Healthy
coverline-frontend-staging    Synced        Healthy
coverline-frontend-prod       Synced        Healthy
```

---

## Challenge 3 — Configure the promotion pipeline

The `.github/workflows/platform-pipeline.yml` workflow covers the full path from code change to production with Trivy scan gates and GitHub Environment approval controls.

### Step 1: Review the pipeline flow

| Stage | Trigger | Gate | Mechanism |
|---|---|---|---|
| CI | Every push to `phase-4-helm/app/**` | Trivy scan must pass (CRITICAL/HIGH) | Image only pushed if clean |
| Dev deploy | Merge to `main` | None (automatic) | Patches `values-dev.yaml` → ArgoCD syncs |
| Staging | `workflow_dispatch` | 1 approver | Patches `values-staging.yaml` → ArgoCD syncs |
| Prod | `workflow_dispatch` | 1 approver | Patches `values-prod.yaml` → ArgoCD syncs |

### Step 2: Configure GitHub Environment protection rules

Navigate to **Settings → Environments** in the GitHub repository.

For `staging`:
- Required reviewers: 1 (tech lead)
- Deployment branches: `main` only

For `prod`:
- Required reviewers: 1 (tech lead or SRE lead)
- Deployment branches: `main` only

### Step 3: Trigger the first deployment

Push a change to trigger CI and auto-deploy to dev:

```bash
git checkout -b feature/capstone-test
echo "# capstone" >> phase-4-helm/app/backend/app.py
git add phase-4-helm/app/backend/app.py
git commit -m "test: trigger capstone pipeline"
git push origin feature/capstone-test
```

Open the GitHub Actions tab and confirm the `ci` job passes the Trivy scan step. After merging to `main`, the `deploy-dev` job patches `values-dev.yaml` and ArgoCD syncs automatically.

### Step 4: Promote to staging

```bash
SHA=$(git log --pretty=format:"%s" | grep "chore(dev): deploy image" | head -1 | awk '{print $NF}')
gh workflow run platform-pipeline.yml \
  -f image_sha="$SHA" \
  -f target_env=staging
```

GitHub pauses and sends a review request to the configured approver. After approval:

```bash
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-staging-gke \
  rollout status deploy/coverline-backend
```

---

## Challenge 4 — Install Backstage

Backstage is an Internal Developer Portal. It pulls service documentation, API definitions, and Kubernetes status directly from Git and the cluster, making every service self-documented and discoverable without maintaining a separate wiki.

### Step 1: Create the namespace and install via Helm

```bash
helm repo add backstage https://backstage.github.io/charts
helm repo update
kubectl create namespace backstage

K8S_CA=$(kubectl config view --raw --minify \
  --output jsonpath='{.clusters[0].cluster.certificate-authority-data}')
K8S_TOKEN=$(kubectl create token backstage-sa -n backstage --duration=8760h 2>/dev/null || \
  kubectl get secret -n backstage -o jsonpath='{.items[0].data.token}' | base64 -d)

kubectl create secret generic backstage-github-token \
  --namespace backstage \
  --from-literal=GITHUB_TOKEN="$(gh auth token)" \
  --from-literal=K8S_SA_TOKEN="${K8S_TOKEN}"

helm upgrade --install backstage backstage/backstage \
  --namespace backstage \
  --values phase-11-capstone/backstage/values.yaml \
  --set postgresql.auth.password="backstage-local-dev-only" \
  --set "backstage.appConfig.kubernetes.clusterLocatorMethods[0].clusters[0].caData=${K8S_CA}"
```

> Pin the Backstage image to `1.30.2`. The `latest` tag ships with a broken notifications frontend binding that causes a `NotImplementedError` on startup.

### Step 2: Access the portal

```bash
kubectl port-forward -n backstage svc/backstage 7007:7007
# Open http://localhost:7007
```

### Step 3: Add catalog-info.yaml to each service

Add `phase-4-helm/app/backend/catalog-info.yaml`:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: coverline-backend
  description: CoverLine claims processing API
  annotations:
    github.com/project-slug: wb-platform-engineering-lab/platform-engineering-lab-gke
    backstage.io/techdocs-ref: dir:.
  tags: [python, flask, api, claims]
spec:
  type: service
  lifecycle: production
  owner: platform-team
  system: coverline-platform
  dependsOn:
    - resource:default/postgresql
    - resource:default/redis
```

### Step 4: Verify the catalog discovered the services

```bash
kubectl logs -n backstage deploy/backstage | grep -i "catalog\|discovered"
```

Open `http://localhost:7007/catalog` — you should see `coverline-backend`, `coverline-frontend`, and the system entity.

---

## Challenge 5 — Deploy the unified Grafana dashboard

The platform overview dashboard consolidates all signal into one view: RED metrics per service, node utilisation, SLO availability, burn rate, and error budget remaining.

### Step 1: Add the backend metrics endpoint

Add `prometheus-flask-exporter==0.23.1` to `phase-4-helm/app/backend/requirements.txt` and initialise it in `app.py`:

```python
from prometheus_flask_exporter import PrometheusMetrics
metrics = PrometheusMetrics(app, default_labels={"service": "coverline-backend"})
```

The backend Service must expose a named port (`name: http`) so the ServiceMonitor can reference it. Without the named port, Prometheus silently fails to scrape the backend and all app-level panels show "No data".

### Step 2: Apply the dashboard ConfigMap

```bash
kubectl apply -f phase-11-capstone/grafana/platform-overview-dashboard.yaml
```

The ConfigMap has label `grafana_dashboard: "1"` — Grafana's sidecar picks it up automatically within 30 seconds.

### Step 3: Verify the dashboard loaded

```bash
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard | tail -20
```

Look for a log line confirming `platform-overview.json` was imported.

### Step 4: Open and verify

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000` → **Dashboards → CoverLine Platform Overview**. Confirm:

- Request rate and error rate panels show data for backend and frontend
- Node CPU and memory utilisation panels are populated
- SLO availability panel shows a percentage (green ≥ 99.9%)
- Burn rate and error budget panels are visible

---

## Challenge 6 — Security baseline as code

The RBAC, NetworkPolicies, and Pod Security contexts from Phase 10 were applied manually to dev. They do not exist in staging or prod yet. A dedicated ApplicationSet continuously reconciles the Phase 10 security manifests to every registered cluster.

### Step 1: Add an .argocdignore to the security directory

The `phase-10-security/` directory contains files that are not Kubernetes manifests (README, quiz, screenshots). ArgoCD errors if it tries to apply these:

```
# phase-10-security/.argocdignore
README.md
quiz.html
screenshots/
security-context-values.yaml
```

### Step 2: Apply the security baseline ApplicationSet

```bash
kubectl apply -f phase-11-capstone/argocd/security-baseline-appset.yaml -n argocd
```

This generates one Application per cluster that continuously reconciles the Phase 10 security manifests. If someone deletes a NetworkPolicy directly with kubectl, ArgoCD restores it within 3 minutes because `selfHeal: true` is set.

### Step 3: Verify security Applications are generated

```bash
kubectl get applications -n argocd | grep security
```

Expected:

```
security-baseline-dev       Synced   Healthy
security-baseline-staging   Synced   Healthy
security-baseline-prod      Synced   Healthy
```

### Step 4: Confirm NetworkPolicies exist on all clusters

```bash
for ctx in \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-dev-gke \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-staging-gke \
  gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-prod-gke; do
  echo "=== $ctx ==="
  kubectl --context="$ctx" get networkpolicy
done
```

---

## Challenge 7 — End-to-end verification

### Step 1: Merge to main and confirm dev updates automatically

After a merge, the `deploy-dev` job should update `values-dev.yaml` and ArgoCD should sync within 2–3 minutes:

```bash
kubectl get pods -w
```

### Step 2: Verify staging has RBAC and NetworkPolicies

```bash
# CI service account should not be able to read secrets
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-staging-gke \
  auth can-i get secrets --as=system:serviceaccount:default:coverline-ci
# Expected: no

# default-deny NetworkPolicy should exist
kubectl --context=gke_platform-eng-lab-will_us-central1_platform-eng-lab-will-staging-gke \
  get networkpolicy default-deny-all
```

### Step 3: Verify the Grafana SLO panel

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Open the **CoverLine Platform Overview** dashboard and confirm:
- Error rate is 0%
- P95 latency is under 200 ms
- SLO availability is above 99.9%

### Step 4: Verify Backstage shows all services

```bash
kubectl port-forward -n backstage svc/backstage 7007:7007
```

Open `http://localhost:7007/catalog`. You should see `coverline-backend`, `coverline-frontend`, `coverline-platform` (System), and `coverline-claims-api` (API).

---

## Teardown

```bash
# Remove capstone resources
kubectl delete -f phase-11-capstone/argocd/
kubectl delete -f phase-11-capstone/grafana/
helm uninstall backstage -n backstage
kubectl delete namespace backstage

# Destroy staging and prod clusters (dev cluster remains)
cd phase-1-terraform/envs/staging && terraform destroy -var-file=staging.tfvars
cd ../prod && terraform destroy -var-file=prod.tfvars
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| Dev GKE cluster (Phase 1) | ~$0.66 |
| Staging GKE cluster | ~$0.66 |
| Prod GKE cluster | ~$0.66 |
| Backstage pods | included in node cost |
| **Phase 11 total (3 clusters)** | **~$2.00** |

> Use the nightly `auto-destroy.yml` workflow to destroy all three clusters at 8 PM UTC and rebuild on demand. With auto-destroy enabled, the daily cost for a session covering one working day is under $0.50 per cluster.

---

## Platform concept: GitOps as the control plane

Every capability in this phase relies on the same underlying principle: **Git is the source of truth, not the cluster**. When you change a `values-prod.yaml` file, you are not deploying software — you are declaring the desired state. ArgoCD is the reconciliation loop that makes the cluster match the declaration. The cluster is disposable; the Git history is not.

This principle extends to security. The NetworkPolicies and RBAC rules in Phase 10 are not "applied once and hoped to remain." They are continuously reconciled by ArgoCD. If an engineer accidentally deletes a policy directly with kubectl, the cluster self-heals within 3 minutes. Security controls become audit-trail-backed, code-reviewed, and automatically enforced across every environment — without anyone having to remember to run `kubectl apply`.

The promotion pipeline adds one more layer: the same image SHA travels unchanged from dev through staging to prod. There are no rebuilds, no environment-specific build flags, no "it worked in dev" mysteries. If staging is healthy, prod will behave identically — because it is the same binary.

---

## Production considerations

**GitOps for everything.** No one runs `kubectl apply` by hand in staging or prod. If a fix is urgent enough to skip a PR, it is urgent enough to be reviewed within the hour and reverted if wrong.

**Image immutability.** The promotion pipeline always references a 7-character SHA. The strings `:latest` and `:main` never appear in production `values.yaml` files.

**Separate GCP projects per environment.** The lab uses separate clusters in the same project for cost reasons. In production, dev, staging, and prod should be in separate GCP projects — separate blast radius, separate billing, separate audit log streams.

**Backstage as the single pane of glass.** Every service has a `catalog-info.yaml`. Every service links to its runbook, its Grafana dashboard, and its on-call rotation. When an incident starts, the on-call engineer opens the Backstage service page — not Slack or a shared doc that was last updated eight months ago.

**Progressive rollout to prod.** Replace the rolling update in prod with an Argo Rollout (Phase 6b) configured with a canary strategy: 10% of traffic to the new version for 10 minutes, automated metric analysis against the SLO panel, then full promotion or automatic rollback.

**Regular DR drills.** The Terraform directory approach means you can provision a fresh prod cluster with one command. Run a DR drill quarterly: spin up a new cluster, apply the ApplicationSet, restore the database from the latest snapshot, verify all services are healthy. Time it. Target: under 45 minutes to full operational status.

---

## Outcome

The platform is now a system, not a collection of components. Three environments are provisioned from a shared module with isolated state. One ApplicationSet manifest generates every Application in every cluster — adding a service takes one new chart directory, not four new manifests. The same image SHA travels from a feature branch through dev, staging, and prod with explicit human approval gates. Every service is discoverable in Backstage. The entire platform is visible in one Grafana dashboard. The security baseline is code — it is reviewed, versioned, and enforced on every cluster without manual intervention.

The CTO's mandate is complete.

---

[Back to main README](../README.md) | [Next: Phase 12 — GenAI](../phase-12-genai/README.md)
