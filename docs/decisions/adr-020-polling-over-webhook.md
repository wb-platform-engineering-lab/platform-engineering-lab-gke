# ADR-020: Git Polling over Webhook for ArgoCD

## Status

Accepted

## Context

ArgoCD detects git changes either by polling the repository on a configurable interval or by receiving a webhook from GitHub when a push occurs. Webhooks are faster but require network connectivity from GitHub to the ArgoCD server.

## Decision

Use ArgoCD's default git polling (every 3 minutes) rather than configuring GitHub webhooks for the lab environment.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Git polling | Zero network configuration required; works with private clusters behind NAT | Up to 3-minute delay between git push and sync start |
| GitHub webhook | Near-instant sync trigger (seconds after push) | Requires ArgoCD server to be publicly reachable; needs GitHub webhook secret and firewall rules |

## Consequences

- Deployments triggered by git push take up to 3 minutes to begin syncing — acceptable for a lab environment.
- No inbound firewall rules needed on the GKE cluster for the ArgoCD API server.
- In production, webhooks are strongly recommended to reduce deployment latency; configure via `argocd-notifications` or the ArgoCD GitHub App.
- Polling interval can be reduced to 1 minute in `argocd-cm` if faster feedback is needed during lab exercises.
