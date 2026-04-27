# Phase 10 — Security & Production Hardening

> **Security concepts introduced:** RBAC least privilege, NetworkPolicies, Pod Security Standards, Trivy image scanning, Kubernetes audit logs | **Builds on:** Phase 7 observability cluster

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10-security/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **RBAC least privilege** | Scopes service account permissions to exactly what the workload needs | A `cluster-admin` CI service account can execute arbitrary commands on the cluster |
| **NetworkPolicies** | Default-deny all traffic; explicit allow rules per service pair | A compromised pod cannot reach the database, Redis, or any other service by default |
| **Pod Security Standards** | Enforces non-root execution, read-only filesystem, dropped capabilities at the namespace level | A process escape inside a root container gives an attacker full node access |
| **Trivy image scanning** | Scans container images for known CVEs in CI — blocks deploys with Critical/High findings | Shipping a known-vulnerable image to production is an audit finding and a breach vector |
| **Kubernetes audit logs** | Records every API server request with caller identity and timestamp | Evidence trail for breach investigation — *"who accessed the credentials secret, and when?"* |

---

## The problem

> *CoverLine — 1,000,000 members. Enterprise contracts. Six weeks to the ISO 27001 audit.*
>
> The security team spent a weekend going through the auditor's preliminary questionnaire. What they found was uncomfortable:
>
> - Every backend pod runs as **root**. A process escape gives an attacker full node access.
> - There are **no NetworkPolicies**. A compromised claims pod can reach PostgreSQL, Redis, and every other service directly.
> - Container images are **never scanned**. The base image has 14 known CVEs, including two rated Critical.
> - There is **no audit log** of who accessed what in the cluster.
>
> Then the critical finding:
>
> *"The CI/CD pipeline's service account has `cluster-admin` privileges. Any developer who can push a GitHub Actions workflow can execute arbitrary commands against the production cluster."*
>
> The CISO's response was four words: *"Fix it. All of it."*

---

## Architecture

```
Before Phase 10:
  Every pod → Every pod (no NetworkPolicies)
  CI service account → cluster-admin (full cluster access)
  Backend pod → root user, no limits on filesystem writes
  Images → never scanned, 14 known CVEs

After Phase 10:
  default namespace → default-deny-all ingress + egress
      ├── frontend  → backend:5000       (explicit allow)
      ├── backend   → postgresql:5432    (explicit allow)
      ├── backend   → redis:6379         (explicit allow)
      └── prometheus → *:metrics         (explicit allow)

  CI service account → Role: update deployments, get pods only
  Backend pod → uid=1000, readOnlyRootFilesystem, capabilities: drop ALL
  Every image → Trivy scan in CI — CRITICAL/HIGH CVEs block the pipeline
  Every K8s API call → logged in GCP Cloud Audit Logs
```

---

## Repository structure

```
phase-10-security/
├── rbac.yaml                    ← CI SA scoped Role + RoleBinding, frontend SA no automount
├── network-policies.yaml        ← default-deny + explicit allow rules per service pair
└── security-context-values.yaml ← Helm values: non-root, readOnlyRootFilesystem, emptyDir mounts
```

Trivy scanning is already integrated in `.github/workflows/ci.yml` (Phase 5). Audit logging is enabled by default on GKE via Cloud Audit Logs.

---

## Prerequisites

Cluster running with bootstrap:

```bash
bash bootstrap.sh --phase 10
```

The bootstrap removes any lingering Vault webhook, disables Vault injection on the backend, and sets DB/Redis env vars directly.

Verify apps are running:

```bash
kubectl get pods
kubectl get pods -n argocd
```

Install Trivy locally:

```bash
brew install trivy
```

---

## Architecture Decision Records

- `docs/decisions/adr-034-rbac-scoped-ci-role.md` — Why a scoped Role over cluster-admin for the CI service account
- `docs/decisions/adr-035-default-deny-networkpolicy.md` — Why default-deny-all as the base NetworkPolicy rather than selective deny
- `docs/decisions/adr-036-pod-security-standards-restricted.md` — Why Pod Security Standards `restricted` over OPA Gatekeeper for this lab
- `docs/decisions/adr-037-trivy-ignore-unfixed.md` — Why `--ignore-unfixed` in Trivy rather than a manual CVE allowlist

---

## Challenge 1 — RBAC: remove cluster-admin from CI

### Step 1: Verify the current over-privileged binding

```bash
kubectl get clusterrolebindings | grep -i "ci\|github\|deploy"
kubectl auth can-i '*' '*' --as=system:serviceaccount:default:coverline-ci
```

### Step 2: Review `rbac.yaml`

```yaml
# Role: only what the pipeline actually needs
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "update", "patch"]   # update image tag after CI build
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]                       # verify rollout health
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list"]                       # kubectl rollout status
```

Everything else — reading Secrets, creating namespaces, deleting resources — is implicitly denied.

### Step 3: Apply

```bash
kubectl apply -f phase-10-security/rbac.yaml
```

### Step 4: Verify the scope

```bash
# These must succeed — required by the pipeline
kubectl auth can-i update deployments --as=system:serviceaccount:default:coverline-ci
kubectl auth can-i get pods --as=system:serviceaccount:default:coverline-ci

# These must fail — CI has no business reading these
kubectl auth can-i get secrets --as=system:serviceaccount:default:coverline-ci
kubectl auth can-i delete namespaces --as=system:serviceaccount:default:coverline-ci
```

Expected for the last two: `no`

### Step 5: Disable automounting on workload service accounts

Pods that don't call the Kubernetes API should not carry a mounted token — if compromised, that token becomes an attack vector.

```bash
kubectl patch serviceaccount coverline-backend \
  -p '{"automountServiceAccountToken": false}'
kubectl patch serviceaccount coverline-frontend \
  -p '{"automountServiceAccountToken": false}'
```

> **Exception:** If Vault Agent injection is enabled (Phase 3), leave `coverline-backend` automounting enabled — Vault Agent needs the token for Kubernetes auth.

---

## Challenge 2 — NetworkPolicies: default deny

### Step 1: Verify the current open state

```bash
# Before applying policies — this should succeed (no restrictions)
kubectl exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- --timeout=3 postgresql:5432 && echo "OPEN"
```

### Step 2: Apply the policies

```bash
kubectl apply -f phase-10-security/network-policies.yaml
```

Policies applied:

| Policy | Allows |
|---|---|
| `default-deny-all` | Blocks all ingress and egress in `default` namespace |
| `allow-frontend-to-backend` | frontend → backend:5000 |
| `allow-backend-to-db` | backend → postgresql:5432 |
| `allow-backend-to-redis` | backend → redis:6379 |
| `allow-monitoring-scrape` | prometheus (monitoring ns) → any pod:metrics |

### Step 3: Verify allowed paths work

```bash
# frontend → backend (must work)
kubectl exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- http://coverline-backend:5000/health

# backend → PostgreSQL (must work)
kubectl exec -it deploy/coverline-backend -- \
  wget -qO- --timeout=3 postgresql:5432 || echo "Connection refused (DB auth) — network reachable"
```

### Step 4: Verify blocked paths are blocked

```bash
# frontend → PostgreSQL (must be blocked)
kubectl exec -it deploy/coverline-frontend-frontend -- \
  wget -qO- --timeout=3 postgresql:5432 || echo "BLOCKED — policy working"
```

Expected: timeout or connection refused after ~3 seconds — the packet never reaches PostgreSQL.

---

## Challenge 3 — Pod security: non-root, read-only filesystem

### Step 1: Build the hardened image

The security context sets `runAsUser: 1000`. The original Dockerfile used `pip install --user`, which installs packages into `/root/.local` — inaccessible to uid 1000. The image must be rebuilt with system-wide package installation.

The updated Dockerfile at `phase-4-helm/app/backend/Dockerfile` uses a multi-stage build:

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt   # installs to /usr/local/lib

FROM python:3.12-slim
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 appuser && useradd -u 1000 -g appuser -s /sbin/nologin -M appuser
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin/flask /usr/local/bin/flask
COPY app.py .
ENV PYTHONDONTWRITEBYTECODE=1   # no .pyc files — incompatible with readOnlyRootFilesystem
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
```

Push to a feature branch to trigger CI and build the hardened image, or build manually:

```bash
docker build --platform linux/amd64 \
  -t us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure \
  phase-4-helm/app/backend/
docker push us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure
```

### Step 2: Review `security-context-values.yaml`

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]

# Writable scratch space without relaxing the read-only root filesystem
extraVolumes:
  - name: tmp
    emptyDir: {}
  - name: app-cache
    emptyDir: {}
extraVolumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: app-cache
    mountPath: /app/.cache
```

### Step 3: Apply via Helm

```bash
helm upgrade coverline phase-4-helm/charts/backend/ \
  -f phase-10-security/security-context-values.yaml
```

### Step 4: Verify the security context

```bash
# Must return uid=1000
kubectl exec -it deploy/coverline-backend -- id

# Must fail — filesystem is read-only
kubectl exec -it deploy/coverline-backend -- touch /test 2>&1
```

Expected:
```
uid=1000(appuser) gid=1000(appuser)
touch: cannot touch '/test': Read-only file system
```

### Step 5: Apply Pod Security Standards at the namespace level

```bash
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

Any new pod that violates the `restricted` policy (root execution, privilege escalation, hostPath mounts) is rejected at admission — before it can run.

---

## Challenge 4 — Image scanning with Trivy

### Step 1: Scan the current image

```bash
trivy image \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest \
  --severity CRITICAL,HIGH \
  --ignore-unfixed \
  --exit-code 1
```

`--ignore-unfixed` skips CVEs that have no available patch — the only ones you can act on. `--exit-code 1` fails the command if any patchable Critical or High CVEs remain.

### Step 2: Understand the CVE remediation

The first scan of the original `python:3.12-slim` image found **9 HIGH CVEs**:

| Package | CVEs | Fix |
|---|---|---|
| `libexpat1`, `libgnutls30`, `perl-base` | HIGH — patchable | `apt-get upgrade -y` in the Dockerfile |
| `libsystemd0`, `libtinfo6` | HIGH — no fix in Debian 13 | Skipped with `--ignore-unfixed` |

The `apt-get upgrade` line in the hardened Dockerfile resolves all patchable CVEs at build time. The remaining unfixed CVEs belong to packages (`systemd IPC`, `ncurses terminal handling`) that the Flask app never uses at runtime.

### Step 3: Verify CI blocks bad images

The Trivy scan step already exists in `.github/workflows/ci.yml`. If a new dependency introduces a patchable Critical CVE, the workflow fails after the build step — the image is never tagged `:latest` and ArgoCD never syncs it.

```bash
# Check the scan configuration in CI
grep -A8 "Scan backend" .github/workflows/ci.yml
```

### Step 4: Compare base image surface areas

```bash
# Full image — large CVE surface
trivy image python:3.12 --severity CRITICAL,HIGH --ignore-unfixed | tail -5

# Slim image — significantly smaller surface
trivy image python:3.12-slim --severity CRITICAL,HIGH --ignore-unfixed | tail -5
```

---

## Challenge 5 — Kubernetes audit logs

### Step 1: Verify Cloud Audit Logs are active

GKE enables audit logging via GCP Cloud Audit Logs by default:

```bash
gcloud logging logs list --project=platform-eng-lab-will | grep cloudaudit
```

Expected:
```
cloudaudit.googleapis.com/activity
cloudaudit.googleapis.com/data_access
```

### Step 2: Query for Secret access

```bash
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.methodName=~".*secrets.*get.*"' \
  --project=platform-eng-lab-will \
  --limit=20 \
  --format=json | jq '.[] | {
    time: .timestamp,
    user: .protoPayload.authenticationInfo.principalEmail,
    resource: .protoPayload.resourceName
  }'
```

### Step 3: Simulate a suspicious event and find it in the logs

```bash
# Deliberately read a Secret
kubectl get secret postgresql -o yaml

# Wait 30 seconds, then find it
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.resourceName=~".*secrets/postgresql.*"' \
  --project=platform-eng-lab-will \
  --limit=5 \
  --format=json | jq '.[0] | {
    time: .timestamp,
    user: .protoPayload.authenticationInfo.principalEmail
  }'
```

### Step 4: Query for privilege escalation attempts

```bash
gcloud logging read \
  'resource.type="k8s_cluster" AND protoPayload.methodName=~".*clusterrolebindings.*"' \
  --project=platform-eng-lab-will \
  --limit=10 \
  --format=json | jq '.[] | {
    time: .timestamp,
    user: .protoPayload.authenticationInfo.principalEmail,
    method: .protoPayload.methodName
  }'
```

This is the exact query a security team runs when investigating a breach — *"did anyone modify RBAC bindings?"*

---

## Teardown

```bash
# Remove NetworkPolicies (restores open communication)
kubectl delete -f phase-10-security/network-policies.yaml

# Remove RBAC resources
kubectl delete -f phase-10-security/rbac.yaml

# Remove Pod Security Standards label
kubectl label namespace default \
  pod-security.kubernetes.io/enforce- \
  pod-security.kubernetes.io/warn-
```

---

## Cost breakdown

Phase 10 adds no GCP costs — all changes are configuration applied to existing resources.

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| **Phase 10 additional cost** | **$0** |

---

## Security concept: defence in depth

Each control in this phase addresses a different attack vector. None is sufficient alone:

| Control | What it stops |
|---|---|
| RBAC scoped CI role | Compromised CI cannot delete production resources or read Secrets |
| NetworkPolicies | Compromised pod cannot reach the database directly |
| Non-root + read-only FS | Process escape does not give the attacker root on the node |
| Trivy in CI | Known-vulnerable images never reach the cluster |
| Audit logs | Breach is detectable after the fact — evidence survives the incident |

A determined attacker can potentially bypass any single control. The combination means each layer must be broken independently — and each layer leaves evidence in the audit log.

---

## Production considerations

### 1. Adopt OPA Gatekeeper or Kyverno for policy-as-code
This lab applies security contexts manually. In production with 50+ services, enforce security policies centrally via admission webhooks — reject non-compliant pods at deploy time before they reach the cluster. Policies live in Git and are reviewed like code.

### 2. Sign images with Cosign and enforce with Binary Authorization
Trivy catches known CVEs but does not verify image integrity. Cosign signs the image digest at build time; Binary Authorization on GKE enforces that only signed images built by the official pipeline can be deployed — an attacker who gains registry write access cannot push a backdoored image.

### 3. Implement mTLS between services
NetworkPolicies restrict traffic at the IP layer. mTLS (via Istio or Linkerd) verifies identity at the application layer — even if a pod is compromised, it cannot impersonate a different service. Required for SOC 2 Type II and many enterprise security contracts.

### 4. Run kube-bench after every cluster upgrade
`kube-bench` runs the CIS Kubernetes Benchmark against your cluster — API server flags, kubelet settings, RBAC defaults. Run it after every upgrade to catch regressions before they become audit findings:

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl logs job/kube-bench
```

### 5. Separate Vault clusters per environment
A dev Vault token should never have any access to production secrets. Run separate Vault clusters per environment with strict IAM boundaries — not just separate paths within one cluster.

### 6. Set `automountServiceAccountToken: false` on the default service account
This prevents every pod in the namespace from getting a token by default:

```bash
kubectl patch serviceaccount default \
  -p '{"automountServiceAccountToken": false}'
```

Opt in explicitly only for workloads that need Kubernetes API access (Vault Agent, ArgoCD, etc.).

---

## Outcome

The cluster now passes the ISO 27001 preliminary findings. The CI service account can no longer execute arbitrary cluster commands. A compromised pod cannot reach the database. The backend runs as a non-root user with a read-only filesystem. Every image is scanned before it reaches the registry. Every access to a Kubernetes Secret is logged with caller identity and timestamp.

---

[Back to main README](../README.md) | [Next: Phase 11 — Capstone](../phase-11-capstone/README.md)
