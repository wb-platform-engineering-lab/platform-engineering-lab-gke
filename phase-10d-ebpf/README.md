# Phase 10d — eBPF Runtime Security (Tetragon + Falco)

> **Security concepts introduced:** eBPF, Tetragon TracingPolicy, in-kernel enforcement, runtime threat detection, MITRE ATT&CK mapping | **Builds on:** Phase 10 security hardening, Phase 10b CKS

[📝 Take the quiz](https://wb-platform-engineering-lab.github.io/platform-engineering-lab-gke/phase-10d-ebpf/quiz.html)

---

## Concepts introduced

| Concept | What it does | Why we need it |
|---|---|---|
| **eBPF** | Runs sandboxed programs in the Linux kernel without a kernel module | Observes and enforces at the syscall level with near-zero overhead — no instrumentation, no sidecars |
| **Tetragon** | Cilium's eBPF-based runtime security — TracingPolicies execute in-kernel | Kills a malicious process *before* the syscall completes; Falco fires *after* — enforcement vs detection |
| **TracingPolicy** | Tetragon CRD defining which syscalls to monitor or kill | Declarative: "if any process in namespace `coverline` calls `execve` with `/bin/sh`, SIGKILL it" |
| **TracingPolicyNamespaced** | Namespace-scoped TracingPolicy | Enforces rules only on coverline pods — doesn't kill shells in `kube-system` or `monitoring` |
| **Falco (eBPF probe)** | Syscall-level threat detection with a structured rules engine | Independent detection path: even if Tetragon kills the process, Falco generates the audit event for SIEM routing |
| **MITRE ATT&CK mapping** | Tactic/technique labels on every rule | Maps each detection to a standard framework — required for SOC 2 and enterprise security reporting |

---

## The problem

> *CoverLine — 1,500,000 members. SOC 2 Type II certified. Bug bounty programme live for 90 days.*
>
> The report landed at 11:47 PM on a Tuesday.
>
> A security researcher had found a deserialization vulnerability in the claims document upload parser. The finding was marked **Critical**. He included a working proof-of-concept: a crafted PDF that, when uploaded, caused the backend pod to execute arbitrary Python code.
>
> The team activated the incident response runbook. They patched and redeployed within two hours. But the post-mortem raised a question that didn't have a good answer:
>
> *"If this hadn't been a responsible disclosure — if an attacker had found it first — what would have stopped them?"*
>
> The security team walked through the kill chain:
>
> 1. Attacker uploads malicious PDF → RCE inside `coverline-backend` pod
> 2. Attacker tries to spawn `/bin/sh` → **succeeds** (no enforcement at the exec layer)
> 3. Attacker reads `/run/secrets/kubernetes.io/serviceaccount/token` → **succeeds** (SA token exists, no read enforcement)
> 4. Attacker queries the Kubernetes API with the stolen token → **blocked** by RBAC (Phase 10 — SA scoped to deployments only)
> 5. Attacker attempts `ptrace` on adjacent process to scrape env vars → **succeeds** (SYS_PTRACE was dropped in Phase 10b, but a container runtime CVE re-exposed it)
> 6. Attacker exfiltrates `DB_PASSWORD` from memory → **succeeds**
>
> Steps 2, 3, and 5 were not covered by any existing control. NetworkPolicies stop lateral movement at L3/L4. Kyverno blocks non-compliant pods at admission. But once code was running inside a legitimate pod, the attacker had minutes of free movement.
>
> *"Admission controllers protect at create time. We have nothing that stops a legitimate container from doing illegitimate things at runtime."*
>
> The fix: enforce at the syscall level. In-kernel. Before the syscall completes.

---

## Architecture

```
Before phase-10d:
  Attacker achieves RCE inside coverline-backend pod
  → exec /bin/sh              ← succeeds (no exec enforcement)
  → read /run/secrets/...     ← succeeds (no file read enforcement)
  → ptrace adjacent process   ← succeeds (capability drop bypassed by CVE)
  → exfiltrate DB_PASSWORD    ← succeeds
  Falco fires alerts AFTER each syscall completes (detection, not enforcement)

After phase-10d:
  Attacker achieves RCE inside coverline-backend pod
  → exec /bin/sh
      └── Tetragon: security_bprm_check kprobe fires in-kernel
          └── SIGKILL sent before exec completes — shell never starts
          └── Falco: "CRITICAL Shell spawned in CoverLine container" → Slack
  → read /run/secrets/kubernetes.io/serviceaccount/token
      └── Tetragon: security_file_open kprobe fires, action: Post
          └── Falco: "ERROR Sensitive file read" → PagerDuty
  → ptrace
      └── Tetragon: raw_syscalls tracepoint, syscall 101 → SIGKILL
          └── Falco: "CRITICAL Ptrace syscall attempt" → Slack
  Attack chain broken at step 2. Steps 3–6 never execute.

Tetragon + Falco layers:
  ┌─────────────────────────────────────────────────────────┐
  │  Linux kernel                                            │
  │  ┌──────────────────────────────────────────────────┐   │
  │  │  eBPF programs (loaded by Tetragon DaemonSet)    │   │
  │  │  ├── security_bprm_check kprobe → SIGKILL        │   │
  │  │  ├── raw_syscalls tracepoint   → SIGKILL / Post  │   │
  │  │  └── security_file_open kprobe → Post            │   │
  │  └──────────────────────────────────────────────────┘   │
  │                         │                                │
  │              structured events (gRPC)                    │
  │                         │                                │
  │  ┌──────────────────────▼───────────────────────────┐   │
  │  │  Tetragon DaemonSet (one pod per node)            │   │
  │  │  ├── TracingPolicyNamespaced: block-shell-exec    │   │
  │  │  ├── TracingPolicyNamespaced: block-ptrace        │   │
  │  │  └── TracingPolicyNamespaced: observe-sensitive   │   │
  │  └──────────────────────────────────────────────────┘   │
  │                                                          │
  │  ┌───────────────────────────────────────────────────┐  │
  │  │  Falco DaemonSet (eBPF probe)                      │  │
  │  │  ├── coverline-ebpf-rules.yaml (custom)            │  │
  │  │  └── falcosidekick → Slack #security-alerts        │  │
  │  └───────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────┘

Defence-in-depth stack:
  Supply chain  │ Cosign + Trivy          (Phase 10, 10b)
  Admission     │ Kyverno, PSA            (Phase 10b)
  Kernel        │ AppArmor, seccomp       (Phase 10b)
  Network       │ NetworkPolicies, Cilium (Phase 10)
  Runtime       │ Tetragon (enforce)      ← Phase 10d  ←────
                │ Falco    (detect)       ← Phase 10d  ←────
  Identity      │ RBAC, no automount      (Phase 10)
  Audit         │ Cloud Audit Logs        (Phase 10)
```

---

## Repository structure

```
phase-10d-ebpf/
├── tetragon/
│   ├── block-shell-exec.yaml         ← TracingPolicyNamespaced: kill shell exec in coverline namespace
│   ├── block-ptrace.yaml             ← TracingPolicyNamespaced: kill ptrace syscall
│   └── observe-sensitive-reads.yaml  ← TracingPolicyNamespaced: Post events on sensitive file reads
└── falco/
    └── coverline-ebpf-rules.yaml     ← Custom Falco rules: shell, ptrace, env scrape, outbound
```

---

## Prerequisites

Phase 10 and Phase 10b complete (RBAC, NetworkPolicies, Kyverno, Falco installed):

```bash
bash bootstrap.sh --phase 10
kubectl get pods -n falco   # Falco already running from Phase 10b
```

Install Tetragon CLI (optional but useful for inspecting events):

```bash
brew install tetra
```

---

## Step 1 — Install Tetragon

Tetragon is part of the Cilium project. GKE Dataplane V2 already runs Cilium as the CNI — Tetragon installs cleanly alongside it without replacing the CNI.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install tetragon cilium/tetragon \
  --namespace kube-system \
  --set tetragon.grpc.address="localhost:54321" \
  --set tetragon.enablePolicyFilter=true \
  --wait
```

Verify Tetragon is running on every node:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=tetragon
# Expected: one pod per node, all Running
```

Check the Tetragon CRDs are installed:

```bash
kubectl get crd | grep tetragon
# Expected: tracingpolicies.cilium.io
#           tracingpoliciesnamespaced.cilium.io
```

---

## Step 2 — Apply the shell exec enforcement policy

This TracingPolicy hooks `security_bprm_check` — the kernel function called before any program image is loaded. If the binary path matches a shell, SIGKILL is sent in-kernel before the process starts. There is no window for the shell to execute even a single instruction.

```bash
kubectl apply -f phase-10d-ebpf/tetragon/block-shell-exec.yaml
```

Verify the policy is loaded:

```bash
kubectl get tracingpoliciesnamespaced -n coverline
# Expected: block-shell-exec   ...  True
```

### Test: exec into the backend pod — watch Tetragon kill it

```bash
# Terminal 1 — watch Tetragon events
kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
  -c export-stdout -f | tetra getevents -o compact

# Terminal 2 — attempt to exec a shell
kubectl exec -it deploy/coverline-backend -- /bin/sh
# Expected: command terminated with exit code 137 (SIGKILL)
```

Expected Tetragon event in Terminal 1:

```
🚀 process coverline/coverline-backend-xxx /bin/sh
💥 exit    coverline/coverline-backend-xxx /bin/sh SIGKILL
```

The exec completes from `kubectl`'s perspective with exit code 137. No shell prompt ever appears. The attack stops at step 2.

> The SIGKILL is sent by the eBPF program running inside the kernel — it executes in the same context as the syscall, before returning to userspace. This is fundamentally different from a Kubernetes admission webhook (which runs before pod creation) or Falco (which runs after the syscall completes). Tetragon enforcement has no race window.

---

## Step 3 — Apply the ptrace enforcement policy

```bash
kubectl apply -f phase-10d-ebpf/tetragon/block-ptrace.yaml
```

### Test: attempt ptrace inside a pod

```bash
# Deploy a test container with strace
kubectl run ptrace-test --image=alpine --namespace=coverline \
  --labels="app=ptrace-test" --rm -it --restart=Never -- \
  sh -c "apk add -q strace && strace -p 1 2>&1 || true"
# Expected: killed (strace attempts ptrace syscall → SIGKILL)
```

Expected Tetragon event:

```
🚀 process coverline/ptrace-test strace
💥 exit    coverline/ptrace-test strace SIGKILL
```

---

## Step 4 — Apply the sensitive file read observation policy

This policy does not kill — it generates a structured event for each read of a sensitive path. Falco routes these events to Slack.

```bash
kubectl apply -f phase-10d-ebpf/tetragon/observe-sensitive-reads.yaml
```

### Test: read /etc/passwd from inside a pod

```bash
kubectl exec deploy/coverline-backend -- cat /etc/passwd
# Expected: command succeeds (observe mode, not enforce)
```

Check Tetragon events:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=tetragon \
  -c export-stdout | tetra getevents -o compact | grep passwd
# Expected: 📖 read coverline/coverline-backend-xxx /etc/passwd
```

> To switch from observe to enforce, change `action: Post` to `action: Sigkill` in `observe-sensitive-reads.yaml`. For a production cluster handling PII, enforce is appropriate. For a first deployment, start in observe mode to baseline normal behaviour before blocking.

---

## Step 5 — Load the custom Falco rules

Load the CoverLine-specific Falco rules that complement Tetragon enforcement:

```bash
kubectl create configmap falco-ebpf-rules \
  --from-file=coverline-ebpf-rules.yaml=phase-10d-ebpf/falco/coverline-ebpf-rules.yaml \
  --namespace falco \
  --dry-run=client -o yaml | kubectl apply -f -
```

Mount the ConfigMap in the Falco DaemonSet (if not already done via Helm values):

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --reuse-values \
  --set "falco.rulesFile[0]=/etc/falco/falco_rules.yaml" \
  --set "falco.rulesFile[1]=/etc/falco/coverline-ebpf-rules.yaml" \
  --set "falco.extraVolumes[0].name=coverline-rules" \
  --set "falco.extraVolumes[0].configMap.name=falco-ebpf-rules" \
  --set "falco.extraVolumeMounts[0].name=coverline-rules" \
  --set "falco.extraVolumeMounts[0].mountPath=/etc/falco/coverline-ebpf-rules.yaml" \
  --set "falco.extraVolumeMounts[0].subPath=coverline-ebpf-rules.yaml"
```

### Verify Falco picks up the custom rules

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "coverline"
# Expected: Loaded custom rule: Shell Spawned in CoverLine Container
#           Loaded custom rule: Sensitive File Read in CoverLine Container
#           ...
```

### Test the full enforcement + detection chain

```bash
# Terminal 1 — watch Falco alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Terminal 2 — attempt to exec shell (Tetragon kills it, Falco alerts)
kubectl exec deploy/coverline-backend -- /bin/sh
```

Expected Falco output in Terminal 1:

```
CRITICAL Shell spawned in CoverLine container
  (ns=coverline pod=coverline-backend-xxx container=coverline-backend
   user=1000 shell=sh parent=runc cmdline=/bin/sh)
```

---

## Step 6 — View events with tetra CLI

The `tetra` CLI queries the Tetragon gRPC API for structured event streams. More powerful than reading raw JSON logs:

```bash
# All events in the coverline namespace
kubectl exec -n kube-system ds/tetragon -c tetragon -- \
  tetra getevents --namespace coverline -o compact

# Only process exec events
kubectl exec -n kube-system ds/tetragon -c tetragon -- \
  tetra getevents --namespace coverline -o compact \
  --event-types PROCESS_EXEC

# Only kill events (Tetragon enforcement actions)
kubectl exec -n kube-system ds/tetragon -c tetragon -- \
  tetra getevents --namespace coverline -o compact \
  --event-types PROCESS_KPROBE | grep SIGKILL
```

---

## Step 7 — Verify the full posture

```bash
# All Tetragon policies active
kubectl get tracingpoliciesnamespaced -n coverline
# Expected:
#   NAME                      ENABLED
#   block-shell-exec          true
#   block-ptrace              true
#   observe-sensitive-reads   true

# Falco running with custom rules
kubectl get pods -n falco
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Loading rules"

# Shell exec is blocked
kubectl exec deploy/coverline-backend -- /bin/sh
# Expected: exit code 137

# Tetragon DaemonSet healthy
kubectl rollout status daemonset/tetragon -n kube-system
```

---

## Architecture Decision Records

- `docs/decisions/adr-021-tetragon-over-seccomp-enforce.md` — Why Tetragon TracingPolicy over custom seccomp profiles for exec enforcement
- `docs/decisions/adr-022-observe-before-enforce.md` — Why sensitive file reads start in observe mode before switching to enforce

---

## Teardown

```bash
kubectl delete -f phase-10d-ebpf/tetragon/
helm uninstall tetragon -n kube-system
kubectl delete configmap falco-ebpf-rules -n falco
```

Falco itself stays — it was installed in Phase 10b and is still needed.

---

## Cost breakdown

| Resource | $/day |
|---|---|
| GKE cluster (Phase 1) | ~$0.66 |
| Tetragon DaemonSet | included in node cost |
| Falco DaemonSet | included in node cost |
| **Phase 10d additional cost** | **~$0.00** |

Both Tetragon and Falco run as DaemonSets. They consume ~50–100 MiB of memory per node. On a 3-node e2-standard-2 cluster there is no material cost increase.

---

## eBPF concept: why in-kernel enforcement matters

Every other security control in this lab runs *outside* the kernel:

| Control | Where it runs | When it fires |
|---|---|---|
| Kyverno | API server admission webhook | Before pod is *created* |
| AppArmor | Kernel LSM | Before syscall *completes* (same as eBPF) |
| seccomp | Kernel syscall filter | Before syscall *completes* (same as eBPF) |
| Falco | Userspace daemon via eBPF ring buffer | *After* syscall completes |
| Tetragon | eBPF program in kernel | *Before* syscall completes — SIGKILL in same execution context |

Tetragon and AppArmor/seccomp operate at the same point in the execution path. The difference is flexibility: TracingPolicy is a Kubernetes CRD, namespace-scoped, live-reloadable, and can target specific pods. AppArmor profiles are per-node and require a node reboot to update.

Falco's eBPF probe observes syscalls via a ring buffer and sends events to userspace for evaluation. There is an inherent latency between the syscall completing and Falco acting on it. For critical enforcement (block shell exec, kill ptrace), Falco is not sufficient alone — it is the audit and alerting layer. Tetragon is the enforcement layer.

---

## Production considerations

### 1. Start in observe mode for all new policies
Apply new TracingPolicies with `action: Post` first. Run for 48 hours. Review the events to identify any false positives (e.g. a legitimate init container that runs a shell). Switch to `action: Sigkill` only after baselining.

### 2. Manage TracingPolicies via ArgoCD
TracingPolicies are Kubernetes resources. Manage them through the same GitOps pipeline as everything else — PRs, code review, ArgoCD sync. A policy change that kills the wrong process will cause an incident. Treat it like a firewall rule change.

### 3. Export Tetragon events to your SIEM
Tetragon produces structured JSON events. In production, pipe them to Cloud Logging or your SIEM directly:

```bash
kubectl logs -n kube-system ds/tetragon -c export-stdout -f | \
  gcloud logging write tetragon-events - --payload-type=json
```

### 4. Pair with Falco for MITRE ATT&CK coverage reporting
Every Falco rule in `coverline-ebpf-rules.yaml` is tagged with a MITRE technique ID. Feed Falco output to a SIEM that understands MITRE tags (Elastic, Chronicle) to generate automatic ATT&CK heatmaps for the security team.

### 5. Review policies after every base image update
A base image update may introduce new binaries or change paths. After any image rebuild, re-run the observe-mode policies for 24 hours to check whether new processes appear in the event stream.

---

## Outcome

| Attack chain step | What stops it |
|---|---|
| RCE via deserialization → exec `/bin/sh` | Tetragon `block-shell-exec` TracingPolicy — SIGKILL in-kernel |
| Read `/run/secrets/.../token` | Tetragon `observe-sensitive-reads` → Falco alert → PagerDuty |
| `ptrace` adjacent process for env scraping | Tetragon `block-ptrace` TracingPolicy — SIGKILL in-kernel |
| Exfiltrate `DB_PASSWORD` | Never reached — attack chain broken at step 1 |

The bug bounty researcher's RCE finding is still valid — the deserialization vulnerability needs patching. But the blast radius is now contained to the pod itself. An attacker who reaches code execution inside `coverline-backend` cannot spawn a shell, inspect adjacent processes, or scrape credentials. The pod is a dead end.

---

[Back to main README](../README.md) | [Previous: Phase 10c — Backup & Disaster Recovery](../phase-10c-backup-dr/README.md) | [Next: Phase 10e — FinOps & Cost Visibility](../phase-10e-finops/README.md)
