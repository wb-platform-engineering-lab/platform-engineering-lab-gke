# ADR-020b: Falco with eBPF Driver over Kernel Module

## Status

Accepted

## Context

Phase 10b adds runtime threat detection using Falco. Falco intercepts Linux syscalls to detect anomalous behaviour (shells spawned in containers, file writes to sensitive paths, privilege escalation). It supports two drivers: a kernel module (`.ko`) loaded at the OS level, and an eBPF probe.

## Decision

Use Falco with the eBPF driver (`driver.kind=ebpf` in Helm values). On GKE, the kernel module requires specific OS compatibility and may break on node upgrades, while eBPF is supported on GKE's Container-Optimised OS nodes without kernel module compilation.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| eBPF driver | Supported on GKE Container-Optimised OS, survives kernel upgrades without recompilation, more stable | Slightly higher overhead than kernel module on very high syscall rate workloads |
| Kernel module (`.ko`) | Lower overhead, older and more stable codepath | Requires compiling or downloading a module matching the exact kernel version; breaks on GKE node upgrades; not supported on COS without extra steps |
| Falco Modern eBPF (BTF) | No pre-compiled probe, relies on BTF kernel headers | Requires kernel 5.8+; GKE node kernels vary; less tested in this GKE configuration |

## Consequences

- Falco DaemonSet runs on every node — resource usage scales with node count and syscall rate.
- Custom rules in `phase-10b-cks/falco/custom_rules.yaml` detect lab-specific scenarios (exec in coverline containers, writes to `/etc/`).
- Alert output goes to `falco-falcosidekick` which forwards to the `monitoring` namespace Alertmanager (integrated with Phase 6 stack).
- Falco rules are loaded from a ConfigMap — changes deploy without pod restart via the sidecar hot-reload mechanism.
- The Kubernetes Audit Policy (Challenge 6) complements Falco: Falco detects runtime events; audit policy captures Kubernetes API-level events.
