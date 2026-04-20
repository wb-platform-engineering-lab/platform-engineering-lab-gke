# ADR-019b: Cosign for Container Image Signing and Supply Chain Security

## Status

Accepted

## Context

Phase 10b addresses supply chain security: ensuring that the container images running in the cluster were built by the authorised CI pipeline and have not been tampered with. Without signing, anyone with push access to the registry can push a malicious image.

## Decision

Use Sigstore Cosign to sign container images in the CI pipeline immediately after push. Use the Sigstore Policy Controller (admission webhook) to verify signatures at admission — unsigned or invalidly signed images are rejected.

## Alternatives Considered

| Option | Pros | Cons |
|---|---|---|
| Cosign (Sigstore) | Keyless signing via OIDC (no key management), transparent log (Rekor) for audit, CNCF project, integrates with GitHub Actions | Relatively new; Policy Controller is a separate install; keyless trust root is Sigstore's infrastructure |
| Notary v2 | OCI-native, Docker Hub integrated | More complex setup; separate notation CLI; less GitHub Actions integration |
| No signing | Zero overhead | No protection against registry push attacks or image tampering |

## Consequences

- Images are signed in CI using `cosign sign` with OIDC keyless signing — no private key to rotate or protect.
- The signature is stored in the same OCI registry as the image (as a separate manifest).
- Policy Controller admission webhook rejects pods that reference unsigned images from the required registry.
- SBOM generation (`cosign attest --type spdxjson`) is run alongside signing — attestation stored in registry.
- Cosign verification is enforced per-namespace via `ClusterImagePolicy` — the `default` namespace requires all images from `gcr.io/platform-eng-lab-will/*` to be signed.
