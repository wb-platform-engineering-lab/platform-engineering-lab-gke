locals {
  project_id = "platform-eng-lab-will"
  vault_sa   = "vault@platform-eng-lab-will.iam.gserviceaccount.com"
}

# KMS key ring for Vault auto-unseal
resource "google_kms_key_ring" "vault" {
  name     = "vault-keyring"
  location = "global"
  project  = local.project_id
}

# KMS crypto key — Vault uses this to wrap/unwrap its master key
resource "google_kms_crypto_key" "vault_unseal" {
  name            = "vault-unseal-key"
  key_ring        = google_kms_key_ring.vault.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Allow the Vault service account to use the key for auto-unseal
resource "google_kms_crypto_key_iam_binding" "vault_unseal" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${local.vault_sa}",
  ]
}

# Service account for Vault pods (used for KMS + Workload Identity)
resource "google_service_account" "vault" {
  account_id   = "vault"
  display_name = "HashiCorp Vault"
  project      = local.project_id
}

# Workload Identity binding — Vault K8s SA → GCP SA
resource "google_service_account_iam_binding" "vault_workload_identity" {
  service_account_id = google_service_account.vault.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${local.project_id}.svc.id.goog[vault/vault]",
  ]
}
