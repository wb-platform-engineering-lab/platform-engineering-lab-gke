# GCS bucket for Vault Raft snapshots (disaster recovery)
resource "google_storage_bucket" "vault_snapshots" {
  name                        = "platform-eng-lab-will-vault-snapshots"
  location                    = "US"
  project                     = local.project_id
  uniform_bucket_level_access = true

  # Auto-delete snapshots older than 30 days
  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

# GCP service account for the snapshot CronJob
resource "google_service_account" "vault_snapshot" {
  account_id   = "vault-snapshot"
  display_name = "Vault Snapshot CronJob"
  project      = local.project_id
}

# Allow the snapshot SA to write to the GCS bucket
resource "google_storage_bucket_iam_member" "vault_snapshot" {
  bucket = google_storage_bucket.vault_snapshots.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vault_snapshot.email}"
}

# NOTE: Workload Identity binding for vault-snapshot SA is done via vault-wi-binding.sh
# (same reason as vault-server — WI pool only exists after GKE is provisioned)
