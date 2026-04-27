# Phase 6 — GitOps with ArgoCD

> **GitOps concepts introduced:** ArgoCD, Application, Sync Policy, Self-Heal, Prune | **Builds on:** Phase 5 CI/CD pipeline

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-6-gitops/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **ArgoCD** | GitOps controller that continuously reconciles cluster state to Git | Replaces `helm upgrade` in CI — the cluster drives itself from Git |
| **Application** | ArgoCD CRD that defines what to deploy, from where, and to which cluster | Declarative deployment config versioned in Git like any other resource |
| **Automated sync** | ArgoCD polls the repo and applies changes without human action | A push to main reaches the cluster automatically — no manual deploy step |
| **Self-heal** | Reverts any manual change made directly to the cluster | Makes drift impossible — the cluster always converges back to Git |
| **Prune** | Removes resources that exist in the cluster but not in Git | Prevents stale resources accumulating from deleted manifests |

---

## The problem

> *CoverLine — 15,000 members. September.*
>
> A developer pushed a config change to the Helm chart at 4 PM on a Friday. The CI pipeline passed. The deploy pipeline passed. But at 4:47 PM, a second developer — working on a different branch — merged a conflicting values change. The CD pipeline ran again and silently overwrote the first deploy with a broken config.
>
> By 5 PM, the claims API was returning 500s. Neither developer knew the other had deployed. There was no single record of what was running in the cluster. The on-call engineer spent two hours diffing YAML files and running `helm history` before finding the cause.
>
> *"The cluster is the source of truth,"* the on-call engineer wrote in the post-mortem. *"But it shouldn't be. Git should be."*

The decision: GitOps with ArgoCD. The cluster state is driven entirely from Git. Every change is a commit. The cluster self-heals if someone touches it directly. Drift is impossible.

---

## Architecture

```
Developer merges PR to main
    │
    ├── CD workflow (Phase 5)
    │       └── Builds image → pushes to Artifact Registry
    │               └── Updates values.yaml with new SHA → commits to main
    │
    └── ArgoCD (polls every 3 minutes)
            └── Detects diff between main and cluster state
                    └── Applies Helm chart with updated values.yaml
                            └── Cluster matches Git — sync complete

ArgoCD Applications:
  coverline-backend  → phase-4-helm/charts/backend   selfHeal: true   prune: true
  coverline-frontend → phase-4-helm/charts/frontend  selfHeal: true   prune: true

Self-heal in action:
  kubectl scale deployment backend --replicas=5   ← manual change
      └── ArgoCD detects drift within 3 minutes
              └── Reverts to replicas: 2 (from values.yaml)
```

---

## Repository structure

```
phase-6-gitops/
├── argocd-app-backend.yaml    ← Application pointing to phase-4-helm/charts/backend
└── argocd-app-frontend.yaml   ← Application pointing to phase-4-helm/charts/frontend
```

ArgoCD watches `phase-4-helm/charts/` — the same charts managed by Phase 4. The CD pipeline from Phase 5 updates `values.yaml` in those charts, triggering an ArgoCD sync.

---

## Prerequisites

- GKE cluster from Phase 1
- Helm charts from Phase 4 deployed
- CI/CD pipeline from Phase 5 running
- PostgreSQL and Redis running (required by the backend):

```bash
helm install postgresql bitnami/postgresql \
  --set auth.username=coverline \
  --set auth.password=coverline123 \
  --set auth.database=coverline \
  --set primary.persistence.size=1Gi

helm install redis bitnami/redis \
  --set auth.enabled=false \
  --set master.persistence.size=1Gi
```

---

## Architecture Decision Records

- `docs/decisions/adr-018-argocd-over-fluxcd.md` — Why ArgoCD over FluxCD as the GitOps controller
- `docs/decisions/adr-019-selfheal-and-prune.md` — Why self-heal and prune are enabled by default in this lab
- `docs/decisions/adr-020-polling-over-webhook.md` — Why polling is acceptable in this lab (webhook recommended for production)

---

## Challenge 1 — Install ArgoCD

### Step 1: Create the namespace and apply the official manifests

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

- if it fails with this error `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`, run this command :

```bash
kubectl apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --force-conflicts
```

### Step 2: Wait for all ArgoCD pods to be ready

```bash
kubectl get pods -n argocd -w
```

Expected — all pods `Running`:
```
NAME                                      READY   STATUS    RESTARTS
argocd-application-controller-0          1/1     Running   0
argocd-repo-server-xxxx                  1/1     Running   0
argocd-server-xxxx                       1/1     Running   0
argocd-dex-server-xxxx                   1/1     Running   0
argocd-redis-xxxx                        1/1     Running   0
```

### Step 3: Retrieve the initial admin password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Challenge 2 — Access the ArgoCD UI

### Step 1: Port-forward the ArgoCD server

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Step 2: Open the UI

Navigate to `https://localhost:8080` (accept the self-signed certificate warning).

Login: `admin` / password from Challenge 1.

### Step 3: Explore the interface

The UI shows all Applications, their sync status, and a resource graph for each. At this point the Applications list is empty — you will create them in Challenge 3.

---

## Challenge 3 — Deploy the ArgoCD Applications

### Step 1: Review `argocd-app-backend.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coverline-backend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/wb-platform-engineering-lab/platform-engineering-lab-gke
    targetRevision: main
    path: phase-4-helm/charts/backend
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

| Field | Value | Why |
|---|---|---|
| `targetRevision: main` | Tracks the main branch | Every merge triggers a potential sync |
| `path` | `phase-4-helm/charts/backend` | The same chart managed by Phase 4 |
| `automated.prune: true` | Deletes resources removed from Git | No stale objects accumulating in the cluster |
| `automated.selfHeal: true` | Reverts manual cluster changes | Git is always the authority |

### Step 2: Apply both Applications

```bash
kubectl apply -f phase-6-gitops/argocd-app-backend.yaml
kubectl apply -f phase-6-gitops/argocd-app-frontend.yaml
```

### Step 3: Verify both Applications are synced

```bash
kubectl get applications -n argocd
```

Expected:
```
NAME                 SYNC STATUS   HEALTH STATUS
coverline-backend    Synced        Healthy
coverline-frontend   Synced        Healthy
```

If status shows `Progressing`, wait 30–60 seconds for pods to become ready.

---

## Challenge 4 — Verify the GitOps loop

This challenge confirms that a Git push reaches the cluster without any manual deploy step.

### Step 1: Scale the backend via Git

Edit `phase-4-helm/charts/backend/values.yaml` and change `replicaCount` to `3`:

```bash
sed -i 's/replicaCount: 2/replicaCount: 3/' phase-4-helm/charts/backend/values.yaml
git add phase-4-helm/charts/backend/values.yaml
git commit -m "scale backend to 3 replicas"
git push origin main
```

### Step 2: Watch ArgoCD detect the change

```bash
kubectl get applications -n argocd -w
```

Within 3 minutes, `coverline-backend` transitions from `Synced` → `OutOfSync` → `Synced`.

### Step 3: Confirm the cluster updated

```bash
kubectl get pods -l app.kubernetes.io/instance=coverline
```

You should see 3 backend pods running.

### Step 4: Revert via Git

```bash
sed -i 's/replicaCount: 3/replicaCount: 2/' phase-4-helm/charts/backend/values.yaml
git add phase-4-helm/charts/backend/values.yaml
git commit -m "revert backend to 2 replicas"
git push origin main
```

---

## Challenge 5 — Test self-heal

This challenge demonstrates that ArgoCD reverts manual changes made directly to the cluster.

### Step 1: Make a manual change outside of Git

```bash
kubectl scale deployment coverline-backend --replicas=5
kubectl get pods -l app.kubernetes.io/instance=coverline
```

You should briefly see 5 pods.

### Step 2: Watch ArgoCD detect and revert the drift

```bash
kubectl get applications -n argocd -w
```

Within 3 minutes, ArgoCD detects the cluster state (5 replicas) differs from Git (2 replicas), marks the Application `OutOfSync`, and reverts to 2 replicas automatically.

### Step 3: Confirm the revert

```bash
kubectl get pods -l app.kubernetes.io/instance=coverline
```

Back to 2 pods — without any manual intervention.

> This is the core guarantee of GitOps: the cluster cannot diverge from Git for more than the polling interval. A runbook that says "scale to 5 replicas in an emergency" must go through a Git commit, not `kubectl`.

---

## Teardown

```bash
kubectl delete -f phase-6-gitops/
kubectl delete namespace argocd
```

---

## Cost breakdown

ArgoCD runs as pods on the existing GKE cluster. No additional GCP resources are created.

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| ArgoCD pods | included in node cost |
| **Phase 6 additional cost** | **$0** |

---

## GitOps concept: reconciliation vs. imperative deploys

Phase 5 used `helm upgrade` inside a CI job — an imperative command executed once. If the job fails halfway, the cluster is in an unknown state. If two jobs run concurrently, they race.

ArgoCD uses a **reconciliation loop**: it continuously compares desired state (Git) to actual state (cluster) and closes any gap it finds. This loop runs regardless of whether a pipeline triggered it. The cluster converges to Git even if:
- A CI job fails mid-deploy
- A developer scales a Deployment manually
- A pod crashes and Kubernetes restarts it with stale config

The shift is conceptual: you stop *executing deploys* and start *declaring state*. The controller handles the rest.

---

## Production considerations

### 1. Adopt the App of Apps pattern
This lab applies each Application manifest manually. In production with many services, a parent ArgoCD Application manages all others — a single entry point for the entire cluster:

```yaml
spec:
  source:
    path: apps/   # contains backend.yaml, frontend.yaml, monitoring.yaml...
```

### 2. Configure ArgoCD notifications
This lab does not alert on sync failures or drift. In production, ArgoCD Notifications sends alerts to Slack or PagerDuty as soon as an Application becomes `OutOfSync` or `Degraded` — before users notice.

### 3. Replace polling with GitHub webhooks
ArgoCD polls every 3 minutes by default. A GitHub webhook notifies ArgoCD immediately on every push, reducing sync delay from minutes to seconds.

### 4. Separate the application and config repositories
This lab stores source code and Helm values in the same repo. The strict GitOps pattern uses two repos: one for application code (triggers CI and image build), one for cluster config (ArgoCD watches it). CI opens a PR against the config repo with the new image tag — it never pushes directly to main.

### 5. Use sync windows for production safety
`selfHeal: true` reverts any manual cluster change automatically — including emergency hotfixes. ArgoCD Sync Windows allow disabling auto-sync during maintenance windows or on-call hours, giving operators time to apply a fix without ArgoCD immediately reverting it.

### 6. Manage multiple clusters from a single ArgoCD instance
This lab targets a single cluster. In production, a centralised ArgoCD instance (hub-and-spoke) manages dev, staging, and prod clusters with RBAC policies scoped per team and environment.

---

## Outcome

The cluster no longer needs a human to deploy. A merge to main updates `values.yaml` (via the CD pipeline), ArgoCD detects the diff within 3 minutes, and the cluster converges. Manual changes to the cluster are automatically reverted. The Git history is the complete audit trail of every change that has ever reached production.

---

[Back to main README](../README.md) | [Next: Phase 6b — Progressive Delivery](../phase-6b-progressive-delivery/README.md)
