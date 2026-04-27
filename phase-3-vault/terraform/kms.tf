locals {
  project_id = "platform-eng-lab-will"
  env        = "dev"
}

# KMS key ring for Vault auto-unseal
#resource "google_kms_key_ring" "vault" {
#  name     = "vault-keyring"
#  location = "global"
#  project  = local.project_id
#}

data "google_kms_key_ring" "vault" {
  name     = "vault-keyring"
  location = "global"
  project  = local.project_id
}

# KMS crypto key — Vault uses this to wrap/unwrap its master key
resource "google_kms_crypto_key" "vault_unseal" {
  name            = "vault-unseal-key"
  key_ring        = data.google_kms_key_ring.vault.id
  rotation_period = "7776000s" # 90 days

  #lifecycle {
  #  prevent_destroy = true
  #}
}

# Allow the Vault service account to encrypt/decrypt with the key
resource "google_kms_crypto_key_iam_binding" "vault_unseal" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${google_service_account.vault.email}",
  ]
}

# Allow the Vault service account to check key existence (cloudkms.cryptoKeys.get)
resource "google_kms_key_ring_iam_binding" "vault_viewer" {
  key_ring_id = data.google_kms_key_ring.vault.id
  role        = "roles/cloudkms.viewer"

  members = [
    "serviceAccount:${google_service_account.vault.email}",
  ]
}

# Service account for Vault pods (used for KMS + Workload Identity)
resource "google_service_account" "vault" {
  account_id   = "vault-server"
  display_name = "HashiCorp Vault"
  project      = local.project_id
}

# NOTE: Workload Identity binding is done via vault-wi-binding.sh after the GKE cluster exists.
# The identity pool (project.svc.id.goog) is only created when GKE is provisioned.
