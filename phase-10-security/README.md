# Phase 10 — Security & Production Hardening

---

> **CoverLine — 1,000,000 members. Enterprise contracts. Six weeks to the ISO 27001 audit.**
>
> CoverLine is now processing health insurance claims for one million people across 200 corporate clients. A bank and a hospital network — two of the largest enterprise deals — have made ISO 27001 certification a contractual condition. The audit starts in six weeks.
>
> The auditor sent a preliminary questionnaire. The security team spent a weekend going through the answers. What they found was uncomfortable:
>
> - Every backend pod runs as **root**. A process escape gives an attacker full node access.
> - There are **no NetworkPolicies**. A compromised claims pod can reach the PostgreSQL database, Redis, and every other service directly — no restrictions.
> - Container images are **never scanned**. The base image for the claims service has 14 known CVEs, including two rated Critical.
> - There is **no audit log** of who accessed what in the cluster. If credentials are stolen, the team has no way to know what was accessed or when.
>
> Then the critical finding:
>
> *"The CI/CD pipeline's service account has* `cluster-admin` *privileges. Any developer who can push a GitHub Actions workflow can execute arbitrary commands against the production cluster."*
>
> The CISO's response was four words: *"Fix it. All of it."*

---

## What we'll build

| Component | What it does |
|-----------|-------------|
| **RBAC — least privilege** | Remove `cluster-admin` from the CI/CD SA; define scoped roles per workload |
| **NetworkPolicies** | Default-deny all traffic; explicitly allow only required service-to-service paths |
| **Pod Security** | Non-root user, read-only filesystem, dropped capabilities, no privilege escalation |
| **Image scanning (Trivy)** | Scan every image in CI — block deploys with Critical/High CVEs |
| **Kubernetes audit logs** | Enable API server audit logging; query for privilege escalation and secret access |

---

## Prerequisites

Cluster running with bootstrap:
```bash
cd phase-1-terraform && terraform apply
gcloud container clusters get-credentials platform-eng-lab-will-gke \
  --region us-central1 --project platform-eng-lab-will
bash bootstrap.sh --phase 10
```

The bootstrap installs PostgreSQL, Redis, ArgoCD, and the observability stack. It also removes any lingering Vault webhook, disables Vault injection on the backend deployment, and sets DB/Redis env vars directly.

Verify the apps are running:
```bash
kubectl get pods
kubectl get pods -n argocd
```

Install Trivy locally:
```bash
brew install trivy
```

---

## Step 1 — RBAC: Least Privilege

### The problem

The CI/CD service account was granted `cluster-admin` to make the initial setup easy. This means any job running in GitHub Actions can do anything to the cluster — create, delete, or read any resource, including Secrets.

Check the current binding:
```bash
kubectl get clusterrolebindings | grep -i "ci\|github\|deploy"
kubectl auth can-i '*' '*' --as=system:serviceaccount:default:coverline-ci
```

### Fix: scoped role for the CI/CD service account

The pipeline only needs to update Deployment images and read pod status. Nothing else.

```bash
kubectl apply -f phase-10-security/rbac.yaml
```

Verify the new permissions are correct:
```bash
# Should succeed — these are the only things CI needs
kubectl auth can-i update deployments --as=system:serviceaccount:default:coverline-ci
kubectl auth can-i get pods --as=system:serviceaccount:default:coverline-ci

# Should fail — CI no longer has these
kubectl auth can-i get secrets --as=system:serviceaccount:default:coverline-ci
kubectl auth can-i delete namespaces --as=system:serviceaccount:default:coverline-ci
```

Expected for the last two: `no`

### Fix: disable automounting for workload service accounts

By default, every pod gets a mounted ServiceAccount token it never uses. If a pod is compromised, that token can be used to query the Kubernetes API.

```bash
kubectl patch serviceaccount coverline-backend \
  -p '{"automountServiceAccountToken": false}'
kubectl patch serviceaccount coverline-frontend \
  -p '{"automountServiceAccountToken": false}'
```

> **Exception:** The Vault Agent sidecar requires the ServiceAccount token for Kubernetes auth. If using Vault injection (Phase 7), leave automounting enabled on the `coverline-backend` SA and disable it only on the frontend.

---

## Step 2 — NetworkPolicies: Default Deny

### The problem

Without NetworkPolicies, every pod in the cluster can reach every other pod on any port. A compromised frontend pod can directly query PostgreSQL on port 5432 — bypassing the application layer entirely.

### Apply default-deny and explicit allow rules

```bash
kubectl apply -f phase-10-security/network-policies.yaml
```

This creates:
- `default-deny-all` — blocks all ingress and egress in the `default` namespace by default
- `allow-backend-to-db` — allows backend pods to reach PostgreSQL on 5432
- `allow-backend-to-redis` — allows backend pods to reach Redis on 6379
- `allow-frontend-to-backend` — allows frontend pods to reach backend on 5000
- `allow-monitoring-scrape` — allows Prometheus (monitoring namespace) to scrape pod metrics

### Verify the policies work

```bash
# Test: frontend → backend (should work)
kubectl exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- http://coverline:5000/health

# Test: frontend → PostgreSQL (should be blocked)
kubectl exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- --timeout=3 http://postgresql:5432 || echo "BLOCKED — policy working"

# Test: backend → PostgreSQL (should work)
kubectl exec -it deploy/coverline-backend -- \
  wget -qO- --timeout=3 http://postgresql:5432 || echo "Connection refused (DB auth) — network reachable"
```

---

## Step 3 — Pod Security: Non-Root, Read-Only Filesystem

### The problem

The claims service runs as `root` inside the container. If the app is exploited (e.g. via a deserialization vulnerability), the attacker immediately has root access inside the pod — and potentially the node.

### Build the updated image first

The security context sets `runAsUser: 1000`. The original Dockerfile installed Python packages with `pip install --user` into `/root/.local` — a directory that uid=1000 cannot access (mode 700). The updated Dockerfile installs packages system-wide and creates the `appuser` (uid=1000) explicitly.

Trigger a CI build by pushing any change to a feature branch. CI builds and pushes the new image automatically. Once the CD pipeline runs and updates `values.yaml` with the new image tag, you're ready to apply the security context.

Alternatively, build and push manually:
```bash
docker build --platform linux/amd64 -t us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure \
  phase-3-helm/app/backend/
docker push us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure
kubectl set image deployment/coverline-backend backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure
```

### Apply security context to the backend Helm chart

```bash
helm upgrade coverline phase-3-helm/charts/backend/ \
  -f phase-10-security/security-context-values.yaml
```

What the security context enforces:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

Verify:
```bash
kubectl exec -it deploy/coverline-backend -- id
# Expected: uid=1000 (not 0)

kubectl exec -it deploy/coverline-backend -- touch /test 2>&1
# Expected: touch: /test: Read-only file system
```

### Apply Pod Security Standards at the namespace level

```bash
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

> **Note:** `restricted` mode blocks privileged containers, hostPath mounts, and root execution cluster-wide in the namespace. Any new pod that violates these rules is rejected at admission. Existing pods are not affected until they are recreated.

---

## Step 4 — Image Scanning with Trivy

### The problem

The claims service image is built on `python:3.11` which includes packages the app never uses — and some of those packages have known CVEs. Shipping a known-vulnerable image to production is an ISO 27001 finding.

### Scan the current image

```bash
trivy image \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest \
  --severity CRITICAL,HIGH \
  --exit-code 1
```

`--exit-code 1` makes Trivy return a non-zero exit code if any Critical or High CVEs are found — which blocks the CI pipeline if added as a build step.

### Add scanning to the CI pipeline

The scan runs automatically in GitHub Actions after the image is built. Check `.github/workflows/ci.yml` for the Trivy step:

```yaml
- name: Install Trivy
  run: |
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

- name: Scan backend image for CVEs
  run: |
    trivy image \
      --severity CRITICAL,HIGH \
      --exit-code 1 \
      --ignorefile phase-3-helm/app/backend/.trivyignore \
      ${{ env.REGISTRY }}/backend:${{ github.sha }}
```

If the scan finds Critical or High CVEs, the workflow fails and the image is never pushed to Artifact Registry. The broken image can never reach the cluster.

### Scan the base image and find a safer alternative

```bash
# Scan the current base image
trivy image python:3.11 --severity CRITICAL,HIGH | head -30

# Scan the slim variant — significantly smaller attack surface
trivy image python:3.11-slim --severity CRITICAL,HIGH | head -30
```

The `slim` variant removes build tools, compilers, and most system packages — reducing the CVE surface substantially.

---

## Step 5 — Kubernetes Audit Logs

### What audit logs capture

The Kubernetes API server logs every request: who called what API, when, from which IP, and what the response was. This is the evidence an auditor needs to answer: *"Did anyone access the database credentials secret on the night of the breach?"*

### Enable audit logging on GKE

GKE enables audit logging via Cloud Audit Logs by default. Verify it is active:

```bash
gcloud logging logs list --project=platform-eng-lab-will | grep cloudaudit
```

You should see:
```
cloudaudit.googleapis.com/activity
cloudaudit.googleapis.com/data_access
```

### Query audit logs for security-relevant events

```bash
# Who read Kubernetes Secrets in the last 24 hours?
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.methodName=~".*secrets.*" AND protoPayload.methodName=~".*get.*"' \
  --project=platform-eng-lab-will \
  --limit=20 \
  --format=json | jq '.[] | {time: .timestamp, user: .protoPayload.authenticationInfo.principalEmail, resource: .protoPayload.resourceName}'

# Any cluster-admin binding changes?
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.methodName=~".*clusterrolebindings.*"' \
  --project=platform-eng-lab-will \
  --limit=10 \
  --format=json | jq '.[] | {time: .timestamp, user: .protoPayload.authenticationInfo.principalEmail, method: .protoPayload.methodName}'
```

### Simulate a suspicious event and find it in the logs

```bash
# Deliberately read a Secret as a test
kubectl get secret postgresql -o yaml

# Wait 30 seconds, then query the logs
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.resourceName=~".*secrets/postgresql.*"' \
  --project=platform-eng-lab-will \
  --limit=5 \
  --format=json | jq '.[0] | {time: .timestamp, user: .protoPayload.authenticationInfo.principalEmail}'
```

This is the exact query a security team runs during a breach investigation.

---

## Step 6 — Verify & Screenshot

```bash
# RBAC: confirm CI service account is scoped
kubectl auth can-i --list --as=system:serviceaccount:default:coverline-ci

# NetworkPolicy: list all policies in default namespace
kubectl get networkpolicy

# Pod Security: confirm non-root
kubectl exec -it deploy/coverline-backend -- id

# Image scan: clean report
trivy image us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest \
  --severity CRITICAL,HIGH

# Audit logs: confirm Secret access is logged
gcloud logging read 'resource.type="k8s_cluster"' \
  --project=platform-eng-lab-will --limit=5
```

Take screenshots for the README:
- `rbac-scoped.png` — `kubectl auth can-i --list` showing restricted permissions
- `network-policy-blocked.png` — frontend blocked from reaching PostgreSQL
- `trivy-scan.png` — Trivy scan output (clean or with findings)
- `audit-log.png` — Cloud Audit Log entry for a Secret read

---

## Troubleshooting

### NetworkPolicy blocked a service that should be allowed

**Cause:** Missing allow rule — NetworkPolicies are additive, a missing rule means deny.

```bash
# Check which policies apply to the affected pod
kubectl get networkpolicy -o yaml | grep -A5 "podSelector"

# Test connectivity step by step
kubectl exec -it <source-pod> -- wget -qO- --timeout=3 <target>:<port>
```

Add a specific allow rule in `network-policies.yaml` for the missing path.

### Pod rejected after applying Pod Security Standards

**Cause:** The pod spec violates the `restricted` policy (e.g. running as root, privilege escalation).

```bash
kubectl describe pod <pod-name> | grep -A5 "Warning\|Error"
```

Common fixes: set `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drop all capabilities.

### Trivy scan times out in CI

**Cause:** Pulling a large image over the network in GitHub Actions.

**Fix:** Cache the Trivy vulnerability database between runs:
```yaml
- uses: actions/cache@v3
  with:
    path: ~/.cache/trivy
    key: trivy-${{ github.run_id }}
    restore-keys: trivy-
```

### `kubectl auth can-i` returns unexpected results

**Cause:** Multiple RoleBindings or ClusterRoleBindings may be granting access from different sources.

```bash
# List all bindings for a service account
kubectl get rolebindings,clusterrolebindings -A \
  -o json | jq '.items[] | select(.subjects[]?.name=="coverline-ci") | .metadata.name'
```

---

## Production Considerations

### 1. Adopt OPA Gatekeeper for policy-as-code
This lab applies security context manually. In production with 50+ services, enforce security policies centrally via OPA Gatekeeper or Kyverno — admission webhooks that reject non-compliant pods at deploy time, before they ever reach the cluster.

### 2. Sign images with Cosign
Trivy scans for known CVEs but does not verify image integrity. Cosign signs the image digest at build time and Kyverno/Gatekeeper enforces that only signed images run in production. This prevents an attacker who gains registry access from pushing a backdoored image.

### 3. Enable Workload Identity for all GCP API access
Any pod that accesses GCP APIs (GCS, Pub/Sub, BigQuery) should use Workload Identity — a GKE SA mapped to a GCP SA — instead of a mounted JSON key file. This is the GKE equivalent of Vault dynamic credentials: no static secrets, automatic rotation.

### 4. Implement mutual TLS between services
NetworkPolicies restrict which pods can talk to each other at the IP level. mTLS (via Istio or Linkerd) verifies the identity of both sides at the application layer — even if a pod is compromised, it cannot impersonate a different service. Required for SOC 2 Type II and many enterprise contracts.

### 5. Run kube-bench on every new cluster
`kube-bench` runs the CIS Kubernetes Benchmark against your cluster configuration — API server flags, kubelet settings, RBAC defaults. Run it after every cluster upgrade to catch regressions before they become audit findings.

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

### 6. Set `automountServiceAccountToken: false` globally
Add it to the namespace default service account to prevent every pod from getting a token they don't need:
```bash
kubectl patch serviceaccount default \
  -p '{"automountServiceAccountToken": false}'
```
Opt in explicitly for the workloads that need it (Vault Agent, ArgoCD, etc.).

---

[📝 Take the Phase 10 quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10-security/quiz.html)
