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

### Issue 1: The Dockerfile must be updated before applying the security context

The security context sets `runAsUser: 1000`. If you apply it against the original image, the app crashes immediately:

```
ModuleNotFoundError: No module named 'psycopg2'
```

**Why:** The original Dockerfile used `pip install --user`, which installs packages into `/root/.local`. The `/root` directory has mode `700` — readable only by root. When the container runs as uid=1000, Python cannot access the packages at all, even if `PYTHONPATH` is set to point there.

**Fix:** Rewrite the Dockerfile to use a multi-stage build that installs packages system-wide (into `/usr/local/lib/python3.12/site-packages`), and explicitly creates a non-root user:

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 appuser && useradd -u 1000 -g appuser -s /sbin/nologin -M appuser
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin/flask /usr/local/bin/flask
COPY app.py .
RUN chown appuser:appuser /app
ENV PYTHONDONTWRITEBYTECODE=1
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
```

Key points:
- The builder stage installs packages as root into `/usr/local/lib` (system-wide)
- Only the relevant site-packages and the flask binary are copied into the final image — not `/root/.local`
- `PYTHONDONTWRITEBYTECODE=1` prevents Python from writing `.pyc` files, which would fail with a read-only root filesystem

Trigger a CI build by pushing any change to a feature branch, or build manually:
```bash
docker build --platform linux/amd64 -t us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure \
  phase-3-helm/app/backend/
docker push us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure
kubectl set image deployment/coverline-backend backend=us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:secure
```

### Issue 2: Disable the Vault webhook before applying the security context

If Phase 7 (Vault) was previously run, the Vault MutatingWebhookConfiguration may still be registered in the cluster. When Helm applies the security context, it recreates pods — and the webhook intercepts every new pod to inject a Vault sidecar. If Vault is not running, the admission request fails and the pod is never created:

```
Error creating: admission webhook "vault.hashicorp.com" denied the request
```

**Fix:** Delete the webhook configuration before upgrading:
```bash
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || true
```

The bootstrap script (`bash bootstrap.sh --phase 10`) does this automatically.

Also ensure the Helm values override has `vault.enabled: false` so the chart does not re-add Vault annotations on the next upgrade. This is already set in `security-context-values.yaml`.

### Apply security context to the backend Helm chart

Once the new image is built and the Vault webhook is removed:

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

The Helm chart template (`phase-3-helm/charts/backend/templates/deployment.yaml`) was updated to support these values via `podSecurityContext`, `securityContext`, `extraVolumes`, and `extraVolumeMounts`. Two `emptyDir` volumes are mounted at `/tmp` and `/app/.cache` to give the app writable scratch space without relaxing the read-only root filesystem.

Verify:
```bash
kubectl exec -it deploy/coverline-backend -- id
# Expected: uid=1000(appuser)

kubectl exec -it deploy/coverline-backend -- touch /test 2>&1
# Expected: touch: cannot touch '/test': Read-only file system
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

The claims service image includes OS packages the app never uses — and some have known CVEs. Shipping a known-vulnerable image to production is an ISO 27001 finding.

### Scan the current image

```bash
trivy image \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest \
  --severity CRITICAL,HIGH \
  --ignore-unfixed \
  --exit-code 1
```

`--exit-code 1` makes Trivy return a non-zero exit code if any patchable Critical or High CVEs are found — which blocks the CI pipeline.

### What the initial scan found and how we fixed it

The first scan of the original `python:3.12-slim` image returned **9 HIGH CVEs**. Here is what each group needed:

| Package group | CVEs | Fix |
|---|---|---|
| `libexpat1` | HIGH | Fixed by `apt-get upgrade` in the Dockerfile |
| `libgnutls30`, `libgnutls-openssl27` | HIGH | Fixed by `apt-get upgrade` |
| `perl-base` | HIGH | Fixed by `apt-get upgrade` |
| `libsystemd0`, `libudev1` | HIGH — CVE-2026-29111 | No fix available in Debian 13 |
| `libtinfo6`, `ncurses-*` | HIGH — CVE-2025-69720 | No fix available in Debian 13 |

**Fix for the patchable CVEs:** Add `apt-get upgrade` to the Dockerfile runtime stage. This pulls in all available OS security patches at build time, resolving the 7 CVEs that had fixes:

```dockerfile
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*
```

**Fix for the no-fix CVEs:** The remaining 2 CVEs (`CVE-2026-29111` for systemd IPC, `CVE-2025-69720` for ncurses terminal handling) have no upstream fix in Debian 13. These packages are included in the base image but are never used by the Flask app at runtime.

Rather than maintaining a manual ignore list, use `--ignore-unfixed` in the Trivy command. This flag tells Trivy to skip any CVE that has no available fix — the only kind we could realistically act on. The scan then only fails CI for CVEs we *can* patch.

### Add scanning to the CI pipeline

The scan runs automatically in GitHub Actions after the image is built. Check `.github/workflows/ci.yml` for the Trivy steps:

```yaml
- name: Install Trivy
  run: |
    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

- name: Scan backend image for CVEs
  run: |
    trivy image \
      --severity CRITICAL,HIGH \
      --exit-code 1 \
      --ignore-unfixed \
      ${{ env.REGISTRY }}/backend:${{ github.sha }}
```

> **Why not use the `aquasecurity/trivy-action`?** The official GitHub Action does not reliably pass the ignore file path when scanning images from private registries using credential helpers (as GCP Artifact Registry requires). Running Trivy directly as a shell command gives identical behavior to a local scan and avoids the authentication complexity.

If the scan finds a patchable Critical or High CVE, the workflow fails — the image is never tagged `:latest` and can never reach the cluster via ArgoCD.

### Choosing the right base image

```bash
# python:3.12 (full) — large attack surface, many packages
trivy image python:3.12 --severity CRITICAL,HIGH | head -30

# python:3.12-slim — fewer packages, much smaller CVE surface
trivy image python:3.12-slim --severity CRITICAL,HIGH | head -30
```

The `slim` variant removes build tools, compilers, and most system packages. Combined with `apt-get upgrade` at build time, it reduces the patchable CVE count to zero.

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

### Pod crashes with `ModuleNotFoundError` after applying security context

**Cause:** The image was built with `pip install --user`, which installs packages into `/root/.local`. The `/root` directory has mode `700` — inaccessible to any user other than root. When `runAsUser: 1000` is enforced, Python cannot find the packages.

**Fix:** Rebuild the image using a multi-stage Dockerfile that installs packages system-wide (`pip install --no-cache-dir` without `--user`). See the updated `phase-3-helm/app/backend/Dockerfile`. Verify the fix by checking where packages land:
```bash
# Should show /usr/local/lib/python3.12/site-packages — not /root/.local
docker run --rm <image> python -c "import psycopg2; print(psycopg2.__file__)"
```

### Pod stuck at `Init:0/1` or admission webhook error after helm upgrade

**Cause:** The Vault MutatingWebhookConfiguration from Phase 7 is still registered. Every new pod creation is intercepted by the Vault webhook, which tries to inject a sidecar. If Vault is not running, the admission request fails and the pod is never created.

```
Error creating: admission webhook "vault.hashicorp.com" denied the request
```

**Fix:**
```bash
kubectl delete mutatingwebhookconfiguration vault-agent-injector-cfg 2>/dev/null || true
```

Also ensure `security-context-values.yaml` sets `vault.enabled: false` so the Helm chart does not re-add Vault annotations on the next upgrade.

### Trivy scan fails in CI but passes locally

**Cause:** The exit code behavior differs depending on which flags are passed. Running trivy locally without `--exit-code 1` always exits 0 regardless of findings. In CI, `--exit-code 1` causes a non-zero exit when unfixed CVEs are present — unless `--ignore-unfixed` is also set.

**Fix:** Always use `--ignore-unfixed` together with `--exit-code 1`. This ensures CI only fails for CVEs that actually have a patch available:
```bash
trivy image --severity CRITICAL,HIGH --exit-code 1 --ignore-unfixed <image>
```

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
