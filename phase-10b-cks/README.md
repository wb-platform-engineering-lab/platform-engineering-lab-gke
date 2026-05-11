# Phase 10b — CKS Exam Preparation (Certified Kubernetes Security Specialist)

> **CKS concepts introduced:** kube-bench, AppArmor, seccomp, Kyverno, Cosign, Falco, Kubernetes Audit Policy | **Builds on:** Phase 10 security hardening

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10b-cks/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **kube-bench** | Runs CIS Kubernetes Benchmark checks against the API server, kubelet, and node config | Surfaces misconfigurations against industry hardening standards — each finding maps to a CKS exam domain |
| **AppArmor / seccomp** | Restricts kernel syscalls and filesystem access per container | The red team escaped a namespace via an unrestricted syscall surface — kernel hardening closes this |
| **Kyverno** | Admission controller enforcing YAML-native policies on every resource creation | Rejects non-compliant pods before they start; policies are Kubernetes resources — no Rego required |
| **Cosign** | Signs container images; Policy Controller verifies signatures at admission | Images with no provenance are a supply chain risk — signing creates a verifiable build chain |
| **Falco** | eBPF runtime threat detection; fires alerts when syscall patterns match threat rules | Admission controllers protect at create time; Falco detects malicious behaviour in running containers |
| **Audit Policy** | Records every API server request at a configurable verbosity level | Without it, a secret can be read 1,000 times with no trace — required for SOC 2 compliance |

---

## The problem

> *CoverLine — 1,200,000 members. ISO 27001 certified. Now targeting SOC 2 Type II.*
>
> The ISO 27001 audit passed. Two enterprise clients renewed with expanded contracts. The CISO called it a good quarter.
>
> Then the penetration test came back.
>
> An external red team spent three days against a staging cluster that mirrored production. Their report landed on a Friday afternoon. By Monday morning, it had been forwarded to the board.
>
> The findings were not about firewalls or S3 buckets. They were inside the cluster:
> - A compromised container escaped its namespace using a `hostPath` volume mount. NetworkPolicies were in place — but not AppArmor profiles. The kernel syscall surface was wide open.
> - The `default` service account in two namespaces had automounted tokens. An attacker who reached either pod could enumerate the entire cluster API.
> - Three container images used base images with no provenance — no signatures, no SBOMs, no verified build chain.
> - The API server had no meaningful audit policy. There was no record of which service accounts had queried secrets in the 30 days prior to the test.
>
> *"We hardened the application. We didn't harden the platform. There's a difference."*

The decision: close every red team finding systematically, domain by domain, following the CKS curriculum. Each challenge maps to one of the six CKS exam domains.

---

## Architecture

```
Admission chain (every kubectl apply / pod create):
    └── API Server
            ├── RBAC authorisation           ← Challenge 2: least-privilege roles, no automount
            ├── Pod Security Admission        ← namespace labels enforce baseline/restricted
            └── Kyverno webhook              ← Challenge 4: require-non-root, block-hostpath
                    └── Rejects non-compliant pods before they are scheduled

Node-level hardening (per running pod):
    └── AppArmor profile → runtime/default   ← Challenge 3: syscall surface reduced
    └── seccomp RuntimeDefault               ← Challenge 3: dangerous syscalls blocked
    └── capabilities: drop ALL               ← Challenge 3: no SYS_ADMIN, NET_ADMIN, SYS_PTRACE

Runtime threat detection (per syscall):
    └── Falco eBPF probe (DaemonSet)         ← Challenge 6
            ├── Terminal shell in container → WARNING
            ├── Write below binary dir → ERROR
            └── Suspicious env read (DB_PASSWORD) → WARNING → Slack

Supply chain (before images enter the cluster):
    └── CI pipeline
            ├── Trivy scan (Phase 10)
            ├── cosign sign → Artifact Registry
            └── syft SBOM + cosign attest     ← Challenge 5
                    └── Policy Controller: unsigned images rejected at admission

Audit trail:
    └── API Server → Cloud Logging            ← Challenge 6
            ├── Secrets: RequestResponse level
            ├── Pod exec: Metadata level
            └── RBAC changes: RequestResponse level
```

---

## Repository structure

```
phase-10b-cks/
├── security-context-values.yaml  ← Helm values: seccomp, AppArmor, capabilities
├── policies/
│   ├── require-non-root.yaml     ← Kyverno ClusterPolicy: enforce runAsNonRoot on all pods
│   ├── block-hostpath.yaml       ← Kyverno ClusterPolicy: deny hostPath volume mounts
│   └── image-policy.yaml         ← Sigstore Policy Controller: signed images only
├── falco/
│   └── coverline-rules.yaml      ← Custom Falco rule: suspicious DB credential access
├── audit/
│   └── audit-policy.yaml         ← Kubernetes audit policy (kubeadm reference)
└── scenarios/
    └── backend-netpol.yaml       ← NetworkPolicy answer for exam Scenario 2
```

---

## Prerequisites

Phase 10 security hardening complete (RBAC, NetworkPolicies, Pod Security, Trivy in CI):

```bash
bash bootstrap.sh --phase 10
kubectl apply -f phase-10-security/rbac.yaml
kubectl apply -f phase-10-security/network-policies.yaml
```

Install local tools:

```bash
brew install kube-bench cosign syft
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo add sigstore https://sigstore.github.io/helm-charts
helm repo update
```

---

## Architecture Decision Records

- `docs/decisions/adr-018-kyverno-over-gatekeeper.md` — Why Kyverno over OPA Gatekeeper for policy enforcement
- `docs/decisions/adr-019-cosign-supply-chain.md` — Why Cosign + Sigstore for image signing over Notary/notation
- `docs/decisions/adr-020-falco-ebpf-over-kernel-module.md` — Why eBPF driver over the kernel module for Falco on GKE

---

## Challenge 1 — Cluster Setup: CIS benchmark audit

**CKS domain: Cluster Setup (10%)**

### Step 1: Run kube-bench

kube-bench runs CIS checks as a Job inside the cluster — it has access to the node filesystem and kubelet config:

```bash
# Use the GKE-specific manifest — the generic job.yaml uses kubeadm paths
# (/usr/bin/kubelet) which don't exist on GKE nodes (/home/kubernetes/bin/kubelet)
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job-gke.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=120s
kubectl logs job/kube-bench
```

### Step 2: Identify the key findings

| Check | Flag / setting | What it enforces |
|---|---|---|
| `1.2.1` | `--anonymous-auth=false` | Disallow unauthenticated API requests |
| `1.2.6` | `--insecure-port=0` | Disable HTTP endpoint |
| `1.2.20` | `--audit-log-path` set | Audit logging enabled |
| `4.2.1` | `--anonymous-auth=false` on kubelet | No anonymous kubelet access |
| `4.2.6` | `--protect-kernel-defaults=true` | Kubelet cannot change kernel parameters |

On GKE some checks are managed by Google and appear as `INFO` — they still map to CKS objectives.

### Step 3: Practice editing the API server manifest (kubeadm reference)

On the exam you will be on a kubeadm cluster where API server flags live in a static pod manifest:

```bash
# View the current config
cat /etc/kubernetes/manifests/kube-apiserver.yaml

# Add or modify a flag — the API server restarts automatically on save
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml

# Verify the component restarted
kubectl get pods -n kube-system | grep apiserver
```

Key flags to know: `--anonymous-auth=false`, `--authorization-mode=Node,RBAC`, `--enable-admission-plugins=NodeRestriction`, `--tls-min-version=VersionTLS12`, `--insecure-port=0`.

---

## Challenge 2 — Cluster Hardening: RBAC and service account tokens

**CKS domain: Cluster Hardening (15%)**

### Step 1: Disable service account token automounting

By default every pod gets a mounted SA token. An attacker who reaches any pod can use it to query the Kubernetes API. Disable it on the `default` SA in each namespace:

```bash
for ns in default monitoring; do
  kubectl patch serviceaccount default -n "$ns" \
    -p '{"automountServiceAccountToken": false}'
done
```

Verify:

```bash
kubectl get serviceaccount default -n default -o yaml | grep automount
# Expected: automountServiceAccountToken: false
```

### Step 2: Audit existing ClusterRoleBindings

Find any service account with cluster-wide permissions:

```bash
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.subjects[]?.kind=="ServiceAccount") |
    "\(.metadata.name): \(.roleRef.name) → \(.subjects[].name)"'
```

Flag anything with `cluster-admin`. The CI service account was already scoped in Phase 10.

### Step 3: Create and verify a least-privilege role

```bash
kubectl create role pod-reader \
  --verb=get,list,watch \
  --resource=pods \
  --namespace=default

kubectl create rolebinding pod-reader-binding \
  --role=pod-reader \
  --serviceaccount=default:coverline-backend \
  --namespace=default

# Verify
kubectl auth can-i get pods \
  --as=system:serviceaccount:default:coverline-backend \
  --namespace=default   # yes

kubectl auth can-i get secrets \
  --as=system:serviceaccount:default:coverline-backend \
  --namespace=default   # no
```

> Exam tip: you can bind a `ClusterRole` with a `RoleBinding` — this scopes the ClusterRole to one namespace without granting cluster-wide access. This distinction is frequently tested.

---

## Challenge 3 — System Hardening: AppArmor and seccomp

**CKS domain: System Hardening (15%)**

### Step 1: Apply the AppArmor profile to the backend

AppArmor restricts what a process can do at the kernel level. The `runtime/default` profile is the container runtime's built-in set of restrictions:

```bash
kubectl patch deployment coverline-backend --type=strategic -p '{"spec":{"template":{"spec":{"containers":[{"name":"coverline-backend","securityContext":{"appArmorProfile":{"type":"RuntimeDefault"}}}]}}}}'
```

Verify:

```bash
kubectl get pod -l app=coverline-backend \
  -o jsonpath='{.items[0].metadata.annotations}'
```

### Step 2: Apply seccomp and drop capabilities via Helm

See [`security-context-values.yaml`](security-context-values.yaml) — sets `seccompProfile: RuntimeDefault`, `runAsNonRoot: true`, drops all capabilities.

```bash
helm upgrade coverline phase-4-helm/charts/backend/ \
  --reuse-values \
  --values phase-10b-cks/security-context-values.yaml
```

### Step 3: Verify seccomp is active

```bash
kubectl get pod -l app=coverline-backend \
  -o jsonpath='{.items[0].spec.securityContext.seccompProfile}'
# Expected: {"type":"RuntimeDefault"}
```

> Exam tip: AppArmor is set via pod annotations (pre-1.30 syntax); seccomp moved to `spec.securityContext.seccompProfile`. Never add `SYS_ADMIN` — it is nearly equivalent to root. Drop `ALL` and add back only what the app genuinely needs.

---

## Challenge 4 — Minimize microservice vulnerabilities: Kyverno

**CKS domain: Minimize Microservice Vulnerabilities (20%)**

Kyverno enforces policies written as Kubernetes-native YAML — no Rego, no separate constraint templates. A `ClusterPolicy` is a single resource with `validate`, `mutate`, or `generate` rules. `validationFailureAction: Enforce` blocks non-compliant resources at admission; `Audit` logs violations without blocking.

### Step 1: Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --wait
```

Verify:

```bash
kubectl get pods -n kyverno
```

### Step 2: Apply the require-non-root policy

See [`policies/require-non-root.yaml`](policies/require-non-root.yaml) — `validationFailureAction: Enforce`, matches pods in the `default` namespace.

```bash
kubectl apply -f phase-10b-cks/policies/require-non-root.yaml
```

Test — this should be rejected at admission:

```bash
kubectl run test-root --image=nginx --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test-root","image":"nginx",
    "securityContext":{"runAsNonRoot":false}}]}}'
# Expected: Error from server (Forbidden): ...admission webhook denied the request...
```

### Step 3: Apply the block-hostpath policy

See [`policies/block-hostpath.yaml`](policies/block-hostpath.yaml) — denies any pod spec containing a `hostPath` volume, cluster-wide.

```bash
kubectl apply -f phase-10b-cks/policies/block-hostpath.yaml
```

This is how the red team's container escape would have been blocked. A pod mounting a `hostPath` volume is denied before it is scheduled — it never starts.

Verify the policies are active:

```bash
kubectl get clusterpolicy
```

Expected:

```
NAME              ADMISSION   BACKGROUND   READY   AGE
block-hostpath    true        true         True    30s
require-non-root  true        true         True    30s
```

Check for existing violations (audit mode scan runs in the background):

```bash
kubectl get policyreport -A
```

### Step 4: Enable secrets encryption at rest (GKE)

On GKE, encryption at rest uses Google-managed keys by default. To use a customer-managed key:

```bash
gcloud kms keyrings create k8s-secrets \
  --location us-central1 --project platform-eng-lab-will

gcloud kms keys create coverline-secrets \
  --keyring k8s-secrets --location us-central1 \
  --purpose encryption --project platform-eng-lab-will

gcloud container clusters update platform-eng-lab-will-dev-gke \
  --region us-central1 \
  --database-encryption-key \
  projects/platform-eng-lab-will/locations/us-central1/keyRings/k8s-secrets/cryptoKeys/coverline-secrets
```

> On a kubeadm exam cluster, encryption is configured via `EncryptionConfiguration` in `/etc/kubernetes/encryption-config.yaml` and referenced by `--encryption-provider-config` on the API server.

---

## Challenge 5 — Supply chain security: image signing with Cosign

**CKS domain: Supply Chain Security (20%)**

### Step 1: Generate a signing key pair

```bash
cosign generate-key-pair
# Produces: cosign.key (private — add to GitHub Actions secrets)
#           cosign.pub (public — commit to repo)
```

### Step 2: Add signing to the CI pipeline

In `.github/workflows/platform-pipeline.yml`, after the build step:

```yaml
- name: Sign image with Cosign
  env:
    COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
    COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
  run: |
    cosign sign --key env://COSIGN_PRIVATE_KEY \
      ${{ env.REGISTRY }}/backend:${{ steps.meta.outputs.sha }}
```

### Step 3: Generate and attest an SBOM

```bash
syft us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest \
  -o spdx-json > sbom.json

cosign attest --key cosign.key \
  --predicate sbom.json --type spdx \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest
```

Verify:

```bash
cosign verify --key cosign.pub \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest
```

### Step 4: Install the Policy Controller and block unsigned images

```bash
helm upgrade --install policy-controller sigstore/policy-controller \
  --namespace cosign-system --create-namespace --wait

kubectl apply -f phase-10b-cks/policies/image-policy.yaml
```

The `image-policy.yaml` creates a `ClusterImagePolicy` that requires a valid Cosign signature from the CoverLine CI key on every image pulled from the CoverLine Artifact Registry. Any unsigned image is rejected at admission.

---

## Challenge 6 — Monitoring, logging, and auditing: Falco + Audit Policy

**CKS domain: Monitoring, Logging and Auditing (20%)**

### Step 1: Install Falco

Falco monitors Linux syscalls at runtime and fires alerts when behaviour matches a threat rule. It catches things admission controllers cannot — a legitimate container that starts behaving maliciously after startup:

```bash
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=ebpf \
  --set falcosidekick.enabled=true \
  --set falcosidekick.config.slack.webhookurl="$SLACK_WEBHOOK" \
  --wait
```

### Step 2: Trigger a built-in rule and watch Falco fire

```bash
# Terminal 1 — watch Falco alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Terminal 2 — trigger the "Terminal shell in container" rule
kubectl exec -it deploy/coverline-backend -- /bin/sh
```

Expected Falco log: `Notice A shell was spawned in a container with an attached terminal (container=coverline-backend ...)`

### Step 3: Add a custom CoverLine rule

Load [`falco/coverline-rules.yaml`](falco/coverline-rules.yaml) — fires when a non-Python process reads the `DB_PASSWORD` environment variable, a specific indicator of credential theft:

```bash
kubectl create configmap falco-coverline-rules \
  --from-file=phase-10b-cks/falco/coverline-rules.yaml \
  --namespace falco
```

### Step 4: Enable API server audit logging (GKE)

```bash
gcloud container clusters update platform-eng-lab-will-dev-gke \
  --region us-central1 \
  --logging=SYSTEM,WORKLOAD,API_SERVER
```

Query the audit log — all secret reads in the last hour:

```bash
gcloud logging read \
  'resource.type="k8s_cluster" AND
   protoPayload.methodName="io.k8s.core.v1.secrets.get"' \
  --limit 50 --project platform-eng-lab-will \
  --format json | \
  jq '.[] | {time: .timestamp,
             user: .protoPayload.authenticationInfo.principalEmail,
             secret: .protoPayload.resourceName}'
```

Query all `kubectl exec` events:

```bash
gcloud logging read \
  'resource.type="k8s_cluster" AND
   protoPayload.methodName="io.k8s.core.v1.pods.exec.create"' \
  --limit 20 --project platform-eng-lab-will \
  --format json | \
  jq '.[] | {time: .timestamp,
             user: .protoPayload.authenticationInfo.principalEmail,
             pod: .protoPayload.resourceName}'
```

> Exam tip (kubeadm): audit policy files go in `/etc/kubernetes/audit/`. Add `--audit-policy-file` and `--audit-log-path` to the API server manifest and mount the audit directory as a `hostPath` volume. Know how to write a policy that logs secret reads at `RequestResponse` and drops `RequestReceived` events — this is a common exam task.

---

## Challenge 7 — CKS exam scenarios

Work through these against the live cluster. Each maps to a real exam task format.

### Scenario 1 — Fix an insecure pod

```bash
kubectl run insecure-pod --image=nginx \
  --overrides='{
    "spec": {
      "hostPID": true, "hostNetwork": true,
      "containers": [{"name": "insecure-pod", "image": "nginx",
        "securityContext": {"privileged": true, "runAsUser": 0},
        "volumeMounts": [{"name": "host-vol", "mountPath": "/host"}]}],
      "volumes": [{"name": "host-vol", "hostPath": {"path": "/"}}]
    }
  }'
```

Find and fix all five issues: `hostPID`, `hostNetwork`, `privileged`, `runAsUser: 0`, and the `hostPath` volume.

### Scenario 2 — Write a NetworkPolicy

The `coverline-backend` pod should only accept ingress from pods labelled `app=coverline-frontend` in the `default` namespace and from the `monitoring` namespace (Prometheus scraping). All other ingress blocked.

Answer: [`scenarios/backend-netpol.yaml`](scenarios/backend-netpol.yaml)

```bash
kubectl apply -f phase-10b-cks/scenarios/backend-netpol.yaml
# Verify — allowed: pod labelled app=coverline-frontend in default namespace
kubectl run frontend-probe \
  --image=curlimages/curl \
  --namespace=default \
  --labels="app=coverline-frontend" \
  --rm -it --restart=Never -- \
  curl -s --connect-timeout 3 http://coverline-backend:5000/health
# Verify — blocked: pod in kube-system (no matching NetworkPolicy allow rule)
kubectl run probe --image=curlimages/curl --rm -it --restart=Never \
  --namespace=kube-system -- \
  curl -s --connect-timeout 3 coverline-backend.default:5000
```

### Scenario 3 — RBAC: create a scoped service account

Create a service account `reporter` in the `default` namespace that can `get` and `list` pods and configmaps in that namespace only — not secrets, not any other namespace.

```bash
kubectl create serviceaccount reporter -n default
kubectl create role reporter-role \
  --verb=get,list --resource=pods,configmaps --namespace=default
kubectl create rolebinding reporter-binding \
  --role=reporter-role \
  --serviceaccount=default:reporter --namespace=default

# Verify
kubectl auth can-i list pods    --as=system:serviceaccount:default:reporter -n default   # yes
kubectl auth can-i get  secrets --as=system:serviceaccount:default:reporter -n default   # no
kubectl auth can-i list pods    --as=system:serviceaccount:default:reporter -n monitoring # no
```

### Scenario 4 — Write a Falco rule

Write a Falco rule that fires at `WARNING` when any process reads `/etc/shadow` outside `kube-system`. Output must include process name, container name, and user.

Answer in [`falco/coverline-rules.yaml`](falco/coverline-rules.yaml) — `WARNING` priority, matches `/etc/shadow` reads outside `kube-system`, outputs `proc`, `container`, and `user`.

### Step 5: Final posture check

```bash
# CIS benchmark pass rate
kubectl logs job/kube-bench | grep -E "PASS|FAIL" | tail -10

# No SA with cluster-admin
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") |
    .subjects[]? | select(.kind=="ServiceAccount") | "\(.namespace)/\(.name)"'

# Kyverno policy violations
kubectl get policyreport -A

# Backend image is signed
cosign verify --key cosign.pub \
  us-central1-docker.pkg.dev/platform-eng-lab-will/coverline/backend:latest

# Falco running
kubectl get pods -n falco
```

---

## Teardown

```bash
helm uninstall kyverno -n kyverno
helm uninstall policy-controller -n cosign-system
helm uninstall falco -n falco
kubectl delete namespace kyverno cosign-system falco
kubectl delete -f phase-10b-cks/policies/
kubectl delete job kube-bench
```

The AppArmor annotations, seccomp profiles, and RBAC changes are non-destructive — leave them in place for Phase 11.

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| KMS key (secrets encryption) | ~$0.06 |
| Kyverno, Falco, Policy Controller pods | included in node cost |
| **Phase 10b additional cost** | **~$0.06** |

---

## CKS concept: defence in depth

No single security control is sufficient. The CKS curriculum maps to exactly the layers that compose a defence-in-depth architecture:

```
Layer                  Control                  What it stops
─────────────────────────────────────────────────────────────────
Supply chain           Cosign + SBOM            Unverified or tampered images entering the cluster
Admission              Kyverno, PSA             Non-compliant pods being created
Node / kernel          AppArmor, seccomp        Syscall-based container escapes
Runtime                Falco                    Malicious behaviour in running containers
Identity               RBAC, no automount       Lateral movement via stolen SA tokens
Audit                  Audit policy             Detection and forensics after the fact
```

The red team found gaps at layers 1, 3, 4, and 6. Fixing any one of them would not have closed the others. This is why the CKS curriculum covers all six domains — not because any single control is the most important, but because a cluster is only as strong as its weakest layer.

---

## Production considerations

### 1. Run kube-bench on every node pool upgrade
A GKE node pool upgrade brings new kubelet binaries. Run kube-bench as a Job after every upgrade to confirm the CIS checks still pass on the new version.

### 2. Review Kyverno PolicyReports weekly
Kyverno generates `PolicyReport` and `ClusterPolicyReport` resources with the results of background scans against existing workloads. Review them weekly — they surface misconfigured resources that were created before a policy was applied:

```bash
kubectl get policyreport -A
kubectl describe clusterpolicyreport
```

Kyverno also exposes a `/metrics` endpoint — scrape it with Prometheus to alert on violation counts.

### 3. Keep Falco rules in Git, not in ConfigMaps
This lab creates Falco rules via `kubectl create configmap`. In production, manage rule ConfigMaps through ArgoCD — Falco rule changes get code review, a PR trail, and are automatically rolled back if they break something.

### 4. Use Workload Identity for Cosign in CI
This lab stores `COSIGN_PRIVATE_KEY` as a GitHub Actions secret. In production, use Sigstore's keyless signing with Workload Identity Federation — the signing key is ephemeral, tied to the GitHub Actions OIDC token, and there is no long-lived secret to rotate or leak.

### 5. CKS exam quick reference
- Check `kubectl config current-context` before every task — the exam switches clusters between questions
- Static pod manifests live on the control plane node in `/etc/kubernetes/manifests/` — editing them restarts the component automatically
- `kubectl auth can-i` is the fastest way to verify RBAC changes without running a test pod
- AppArmor is still set via pod annotations in 1.29; seccomp uses `spec.securityContext.seccompProfile`

---

## Outcome

| Red team finding | Closed by |
|---|---|
| Container escape via `hostPath` + unrestricted syscalls | Kyverno block-hostpath policy + AppArmor/seccomp (Challenges 3, 4) |
| SA tokens automounted in all pods | `automountServiceAccountToken: false` on default SA (Challenge 2) |
| Three images with no provenance | Cosign signing in CI + Policy Controller admission webhook (Challenge 5) |
| No audit log of secret access | API server audit logging to Cloud Logging (Challenge 6) |
| No runtime threat detection | Falco eBPF on all nodes with custom CoverLine rules (Challenge 6) |
| No admission control | Kyverno require-non-root + block-hostpath ClusterPolicies (Challenge 4) |

The red team runs again in 90 days. This time the cluster is ready for them.

---

[Back to main README](../README.md) | [Next: Phase 10c — Backup & Disaster Recovery](../phase-10c-backup-dr/README.md)
