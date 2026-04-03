# ADR-001: GKE over Self-Managed Kubernetes

## Status

Accepted

## Context

This project requires a Kubernetes cluster to deploy and manage microservices. The options were to use a managed Kubernetes service or self-manage the control plane on virtual machines.

## Decision

Use Google Kubernetes Engine (GKE) as the managed Kubernetes service on GCP.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| GKE (chosen) | Managed control plane, auto-upgrades, deep GCP integration, Autopilot option | GCP vendor lock-in |
| EKS (AWS) | Large ecosystem, mature tooling | More complex networking setup, higher baseline cost |
| AKS (Azure) | Good Azure DevOps integration | Less mature than GKE/EKS for Kubernetes-native features |
| Self-managed (kubeadm) | Full control, any cloud or on-prem | High operational overhead: etcd, upgrades, certificates, HA all manual |

## Consequences

- The control plane (API server, etcd, scheduler) is fully managed by Google — no operational burden
- GKE handles cluster upgrades, node repairs, and certificate rotation automatically
- Deep integration with GCP services (Cloud IAM, Cloud Logging, Artifact Registry) reduces glue code
- Vendor lock-in to GCP is accepted as a trade-off for reduced operational complexity in a lab context
