#!/bin/bash
# vault-wi-binding.sh — Bind the Vault Kubernetes ServiceAccount to the GCP SA via Workload Identity.
# Run after: terraform apply (KMS) AND helm install vault (Vault pods running).

set -euo pipefail

PROJECT_ID="platform-eng-lab-will"

gcloud iam service-accounts add-iam-policy-binding \
  vault-server@${PROJECT_ID}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[vault/vault]" \
  --project="${PROJECT_ID}"

echo "Workload Identity binding created."
echo "Annotate the Vault K8s ServiceAccount:"
echo "  kubectl annotate serviceaccount vault -n vault \\"
echo "    iam.gke.io/gcp-service-account=vault-server@${PROJECT_ID}.iam.gserviceaccount.com"
