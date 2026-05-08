# Phase 10g — Policy as Code (Kyverno)

> **Concepts introduced:** Kyverno validate/mutate/generate rules, PolicyReports, PolicyExceptions, Kyverno CLI in CI | **Builds on:** Phase 10 security hardening, Phase 10b CKS

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10g-kyverno/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **Validate** | Blocks non-compliant resources at admission | Rejects pods without resource limits or missing labels — before they are scheduled |
| **Mutate** | Rewrites resource specs at admission | Injects safe defaults (resource limits, labels) without requiring every team to know the rules |
| **Generate** | Creates new resources when a trigger resource is created | Auto-provisions a default-deny NetworkPolicy and developer RoleBinding for every new namespace |
| **PolicyReport** | Kubernetes resource containing background scan results | Shows which existing workloads violate active policies — catches resources created before a policy was applied |
| **PolicyException** | Grants a named workload an exemption from a specific policy rule | Allows legitimate exceptions without weakening the global policy — every exception is in Git, reviewed, and time-boxed |
| **Kyverno CLI** | `kyverno apply` runs policies against local manifests | Catches policy violations in CI before `kubectl apply` — shifts enforcement left to the PR stage |

---

## The problem

> *CoverLine — 2,000,000 members. Twenty engineering teams. One Kubernetes cluster.*
>
> Scaling the product was straightforward. Scaling the platform team was not.
>
> In six months, CoverLine went from three backend services to thirty-one. Six product teams now deploy independently, each with their own release cadence. The platform team owns the cluster — the product teams own their services.
>
> The problems that started appearing were not security breaches. They were configuration drift:
>
> - A new service deployed without CPU limits. During a traffic spike it consumed 80% of a node's CPU. Three other services on that node went into CrashLoopBackOff. The on-call engineer spent two hours finding the cause.
> - A team created a new namespace for a batch job. No NetworkPolicy. The batch job's pods had unrestricted egress — a compliance finding in the quarterly audit.
> - A cost allocation report came back with 40% of spend labelled "unknown team". The `team` and `cost-centre` labels that Kubecost needs were optional, so half the teams didn't set them.
> - An outage post-mortem asked: who deployed the pod that crashed the node? There was no `team` label. The PagerDuty alert went to the platform team's queue because the routing rule couldn't match it to anyone else.
>
> Each problem had the same root cause: the platform team was relying on documentation and code review to enforce standards that could be enforced automatically.
>
> The fix: encode the rules as policy. Every deployment gets validated. Missing config gets injected. New namespaces get their NetworkPolicy and RBAC automatically. Exceptions are explicit, reviewed, and time-boxed.

---

## Architecture

```
Before phase-10g:
  Developer runs kubectl apply
  → API server admits pod (no policy check)
  → Pod may be missing resource limits, labels, or running as root
  → Platform team finds out via incident or audit

After phase-10g:
  Developer runs kubectl apply
  → API server → Kyverno webhook
        ├── validate: require-resource-limits    → reject if missing
        ├── validate: require-labels             → reject if missing
        ├── validate: require-non-root           → reject if root (from 10b)
        ├── validate: block-hostpath             → reject if hostPath (from 10b)
        ├── mutate:  inject-resource-limits      → add defaults if missing (Audit mode)
        └── mutate:  add-default-labels          → stamp managed-by, namespace labels
  → Pod admitted

  Developer creates new namespace (team=claims, enforce-netpol=true)
  → Kyverno generate rules fire automatically
        ├── generate: default-deny-all NetworkPolicy
        └── generate: developer-view RoleBinding for claims-developers group

  Background scanner runs every 10 minutes
  → PolicyReport updated with all existing violations
  → Prometheus alert fires if violation count > 0

  Developer opens PR with new manifest
  → CI: kyverno apply policies/ --resource manifest.yaml
  → Pipeline fails with policy violation before kubectl apply
```

---

## Repository structure

```
phase-10g-kyverno/
├── policies/
│   ├── validate/
│   │   ├── require-resource-limits.yaml   ← Enforce: block pods without CPU/memory limits
│   │   └── require-labels.yaml            ← Enforce: block pods without team + cost-centre labels
│   ├── mutate/
│   │   ├── inject-resource-limits.yaml    ← Mutate: inject 500m/256Mi defaults if missing
│   │   └── add-default-labels.yaml        ← Mutate: stamp managed-by + namespace labels
│   ├── generate/
│   │   ├── default-networkpolicy.yaml     ← Generate: default-deny NetworkPolicy on namespace create
│   │   └── developer-rolebinding.yaml     ← Generate: view RoleBinding for team group on namespace create
│   └── exceptions/
│       └── legacy-db-migrator.yaml        ← PolicyException: exempt db-migrator Job (ENG-4821, expires 2026-08-08)
```

---

## Prerequisites

Phase 10b complete (Kyverno installed from Challenge 4):

```bash
kubectl get pods -n kyverno
# Expected: kyverno-* Running
```

If not installed:

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace --wait
```

Install the Kyverno CLI:

```bash
brew install kyverno
kyverno version
```

---

## Step 1 — Apply the validate policies

### Require resource limits

Without CPU and memory limits, a single pod can starve the entire node. This policy blocks any pod in the `coverline` or `default` namespace that omits `resources.limits`:

```bash
kubectl apply -f phase-10g-kyverno/policies/validate/require-resource-limits.yaml
```

Test — this pod should be rejected:

```bash
kubectl run no-limits --image=nginx --namespace=coverline \
  --labels="team=test,cost-centre=test"
# Expected: Error from server: admission webhook denied — Container must declare resources.limits
```

Test — this pod should be admitted:

```bash
kubectl run with-limits --image=nginx --namespace=coverline \
  --labels="team=test,cost-centre=test" \
  --requests='cpu=100m,memory=128Mi' \
  --limits='cpu=500m,memory=256Mi'
kubectl delete pod with-limits -n coverline
```

### Require team and cost-centre labels

```bash
kubectl apply -f phase-10g-kyverno/policies/validate/require-labels.yaml
```

Test — rejected (missing labels):

```bash
kubectl run no-labels --image=nginx --namespace=coverline \
  --limits='cpu=500m,memory=256Mi'
# Expected: Error from server: admission webhook denied — Pod must have labels 'team' and 'cost-centre'
```

### Verify both policies are active

```bash
kubectl get clusterpolicy
```

Expected:

```
NAME                    ADMISSION   BACKGROUND   READY   AGE
block-hostpath          true        true         True    ...
require-labels          true        true         True    30s
require-non-root        true        true         True    ...
require-resource-limits true        true         True    45s
```

---

## Step 2 — Apply the mutate policies

Mutating policies rewrite the pod spec at admission — they run before validate policies. The pattern `+(key): value` means "set this only if the key is absent".

### Inject default resource limits

```bash
kubectl apply -f phase-10g-kyverno/policies/mutate/inject-resource-limits.yaml
```

Apply a pod without limits and inspect what was admitted:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mutation-test
  namespace: coverline
  labels:
    team: platform
    cost-centre: engineering
spec:
  containers:
    - name: app
      image: nginx
EOF

kubectl get pod mutation-test -n coverline \
  -o jsonpath='{.spec.containers[0].resources}' | jq
```

Expected — limits injected by Kyverno:

```json
{
  "limits": { "cpu": "500m", "memory": "256Mi" },
  "requests": { "cpu": "100m", "memory": "128Mi" }
}
```

```bash
kubectl delete pod mutation-test -n coverline
```

### Add default labels

```bash
kubectl apply -f phase-10g-kyverno/policies/mutate/add-default-labels.yaml
```

Verify labels are stamped:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: label-test
  namespace: coverline
  labels:
    team: platform
    cost-centre: engineering
spec:
  containers:
    - name: app
      image: nginx
      resources:
        limits:
          cpu: 200m
          memory: 128Mi
EOF

kubectl get pod label-test -n coverline --show-labels
# Expected: ... managed-by=platform-team,namespace=coverline,...
kubectl delete pod label-test -n coverline
```

---

## Step 3 — Apply the generate policies

Generate rules watch for a trigger resource and automatically create dependent resources. The `synchronize: true` flag means Kyverno will recreate the generated resource if it is deleted — it acts as a controller, not a one-shot job.

### Auto-create default-deny NetworkPolicy

```bash
kubectl apply -f phase-10g-kyverno/policies/generate/default-networkpolicy.yaml
```

Create a test namespace with the trigger label:

```bash
kubectl create namespace team-payments \
  --dry-run=client -o yaml | \
  kubectl label --local -f - enforce-netpol=true team=payments -o yaml | \
  kubectl apply -f -
```

Verify the NetworkPolicy was auto-generated:

```bash
kubectl get networkpolicy -n team-payments
# Expected: default-deny-all   ... generated-by=kyverno
```

Test that Kyverno recreates it if deleted:

```bash
kubectl delete networkpolicy default-deny-all -n team-payments
sleep 5
kubectl get networkpolicy -n team-payments
# Expected: default-deny-all is back (synchronize: true)
```

### Auto-create developer RoleBinding

```bash
kubectl apply -f phase-10g-kyverno/policies/generate/developer-rolebinding.yaml
```

```bash
kubectl get rolebinding developer-view -n team-payments -o yaml
# Expected: subjects: [{kind: Group, name: payments-developers}]
```

```bash
kubectl delete namespace team-payments
```

---

## Step 4 — PolicyReports: query background scan results

Kyverno runs a background controller that continuously evaluates existing resources against active policies. Results are written to `PolicyReport` (namespace-scoped) and `ClusterPolicyReport` (cluster-wide) resources.

```bash
# All policy reports in the coverline namespace
kubectl get policyreport -n coverline

# Detailed violations
kubectl get policyreport -n coverline -o json | \
  jq '.items[].results[] | select(.result == "fail") |
    {policy: .policy, rule: .rule, resource: .resources[0].name, message: .message}'
```

Get a count of violations per policy across all namespaces:

```bash
kubectl get policyreport -A -o json | \
  jq '[.items[].results[] | select(.result == "fail")] |
    group_by(.policy) |
    map({policy: .[0].policy, violations: length}) |
    sort_by(.violations) | reverse'
```

Expected output (before fixing existing pods):

```json
[
  { "policy": "require-resource-limits", "violations": 3 },
  { "policy": "require-labels",          "violations": 7 }
]
```

> PolicyReports surface violations in resources that existed *before* a policy was applied. They are the retrospective view — admission enforcement catches new resources going forward.

### Alert on violations with Prometheus

Kyverno exposes a `/metrics` endpoint. Scrape it to alert when violation counts increase:

```bash
# Port-forward Kyverno metrics
kubectl port-forward svc/kyverno-svc -n kyverno 8000:8000 &

# Check violation count metric
curl -s http://localhost:8000/metrics | grep kyverno_policy_results_total | grep fail
```

In your `PrometheusRule`:

```yaml
- alert: KyvernoViolationsIncreasing
  expr: increase(kyverno_policy_results_total{policy_result="fail"}[10m]) > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Kyverno policy violations detected in {{ $labels.policy }}"
```

---

## Step 5 — PolicyExceptions: explicit, time-boxed exemptions

The legacy `db-migrator` Job runs as root — it requires superuser privileges for `pg_restore`. It violates `require-non-root`. Instead of weakening the global policy, create a `PolicyException`:

```bash
kubectl apply -f phase-10g-kyverno/policies/exceptions/legacy-db-migrator.yaml
```

Verify the exception is active:

```bash
kubectl get policyexception -n coverline
# Expected: legacy-db-migrator-exception
```

Test — db-migrator pod (root) is now admitted:

```bash
kubectl run db-migrator --image=alpine --namespace=coverline \
  --labels="app=db-migrator,team=platform,cost-centre=engineering" \
  --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"db-migrator","image":"alpine","resources":{"limits":{"cpu":"200m","memory":"128Mi"}}}]}}' \
  --restart=Never
kubectl get pod db-migrator -n coverline
kubectl delete pod db-migrator -n coverline
```

Key properties of this exception model:
- The exception is a Kubernetes resource — it lives in Git, goes through PR review, and is audited by ArgoCD
- `approved-by`, `ticket`, and `review-date` annotations are enforced by convention — add a Kyverno validate policy on `PolicyException` resources to require them
- The `review-date` annotation is the signal for the platform team's quarterly exception audit

---

## Step 6 — Kyverno CLI: enforce policies in CI

The Kyverno CLI evaluates policies against local YAML files without a running cluster. Add it to the CI pipeline to catch violations at PR time — before `kubectl apply`.

```bash
# Test a manifest against all validate policies
kyverno apply phase-10g-kyverno/policies/validate/ \
  --resource phase-4-helm/charts/backend/templates/deployment.yaml

# Expected output for a compliant manifest:
# pass: 2, fail: 0, warn: 0, error: 0, skip: 0

# Test with a non-compliant manifest
cat <<EOF > /tmp/bad-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: coverline
spec:
  containers:
    - name: app
      image: nginx
EOF

kyverno apply phase-10g-kyverno/policies/validate/ --resource /tmp/bad-pod.yaml
# Expected: fail: 2 (require-labels, require-resource-limits)
```

### Add to the GitHub Actions pipeline

In `.github/workflows/platform-pipeline.yml`, add a policy check job before the deploy job:

```yaml
policy-check:
  name: Kyverno policy check
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4

    - name: Install Kyverno CLI
      run: |
        curl -LO https://github.com/kyverno/kyverno/releases/latest/download/kyverno-cli_linux_amd64.tar.gz
        tar -xzf kyverno-cli_linux_amd64.tar.gz
        sudo mv kyverno /usr/local/bin/

    - name: Run Kyverno policy checks
      run: |
        kyverno apply phase-10g-kyverno/policies/validate/ \
          --resource phase-4-helm/charts/backend/templates/ \
          --detailed-results
```

---

## Step 7 — Final posture check

```bash
# All policies active and ready
kubectl get clusterpolicy

# No critical violations in coverline namespace
kubectl get policyreport -n coverline -o json | \
  jq '[.items[].results[] | select(.result == "fail")] | length'
# Target: 0

# Exceptions are documented
kubectl get policyexception -A

# Generate policies are synchronising
kubectl get networkpolicy -A -l generated-by=kyverno
kubectl get rolebinding -A -l generated-by=kyverno
```

---

## Architecture Decision Records

- `docs/decisions/adr-023-kyverno-mutate-before-enforce.md` — Why mutate policies run before validate, and when to use each
- `docs/decisions/adr-024-policyexception-governance.md` — Why PolicyExceptions require a ticket reference and review date

---

## Teardown

```bash
kubectl delete -f phase-10g-kyverno/policies/validate/
kubectl delete -f phase-10g-kyverno/policies/mutate/
kubectl delete -f phase-10g-kyverno/policies/generate/
kubectl delete -f phase-10g-kyverno/policies/exceptions/
# Kyverno itself stays — it is used by Phase 10b policies
```

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Kyverno webhook pods (already running from Phase 10b) | included in node cost |
| **Phase 10g additional cost** | **~$0.00** |

---

## Production considerations

### 1. Start all new validate policies in Audit mode
Set `validationFailureAction: Audit` when first applying a policy. Run for 48 hours, review the PolicyReport, fix existing violations, then switch to `Enforce`. Jumping straight to `Enforce` on a live cluster will break workloads that pre-date the policy.

### 2. Require annotations on PolicyExceptions
Apply a Kyverno validate policy to `PolicyException` resources themselves:

```yaml
validate:
  message: "PolicyException must have ticket, approved-by, and review-date annotations"
  pattern:
    metadata:
      annotations:
        ticket: "?*"
        approved-by: "?*"
        review-date: "?*"
```

This makes the exception audit self-enforcing — a `PolicyException` without governance metadata is itself rejected.

### 3. Manage all policies via ArgoCD
Kyverno policies are Kubernetes resources. Manage them through the same GitOps pipeline as application manifests — PRs, code review, ArgoCD sync. A policy change that blocks legitimate workloads will cause an outage. Treat it like a firewall rule change.

### 4. Pin Kyverno minor versions
Kyverno's policy language evolves between minor versions. Pin the Helm chart version in ArgoCD and test policy behaviour after every upgrade against a staging cluster before rolling to production.

### 5. Monitor Kyverno webhook latency
Kyverno sits in the admission path — every `kubectl apply` waits for the webhook response. Scrape `kyverno_admission_review_duration_seconds` and alert if p99 exceeds 500ms. A slow Kyverno webhook degrades all cluster operations.

---

## Outcome

| Problem | Fixed by |
|---|---|
| Pod without limits crashes node | `require-resource-limits` validate policy — rejected at admission |
| Missing `team`/`cost-centre` labels break cost allocation | `require-labels` validate policy — rejected at admission |
| New namespace has no NetworkPolicy | `generate-default-networkpolicy` — auto-generated on namespace create |
| New namespace has no RBAC | `generate-developer-rolebinding` — auto-generated on namespace create |
| Legacy workload violates policy | `PolicyException` with ticket, owner, review-date — in Git, auditable |
| Policy violations reach the cluster | Kyverno CLI in CI — caught at PR time |

The platform team no longer manually reviews Kubernetes manifests for compliance. The rules are in Git. The cluster enforces them.

---

[Back to main README](../README.md) | [Previous: Phase 10f — Chaos Engineering](../phase-10f-chaos/README.md)
