# vm.tf — Vault server on a dedicated Compute Engine VM.
# Runs outside GKE to avoid the circular dependency:
# Vault must be reachable even when the Kubernetes cluster is restarting.

locals {
  vault_vm_zone   = "us-central1-b"
  vault_vm_name   = "vault-server"
  gke_subnet_cidr = "10.0.0.0/14"  # GKE cluster subnet — adjust to match your VPC
}

# --------------------------------------------------------------------------
# Compute Engine VM
# --------------------------------------------------------------------------
resource "google_compute_instance" "vault" {
  name         = local.vault_vm_name
  machine_type = "e2-medium"   # 1 vCPU, 4GB RAM — cheapest viable for Vault
  zone         = local.vault_vm_zone
  project      = local.project_id

  tags = ["vault-server"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 20   # GB — OS + Vault binary + Raft data
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = "default"
    subnetwork = "default"

    # No external IP — Vault is only reachable from within the VPC.
    # Use IAP tunnel or bastion for admin access.
  }

  # Attach the vault-server service account for KMS auto-unseal access
  service_account {
    email  = google_service_account.vault.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  # Ansible will configure Vault after provisioning
  metadata_startup_script = <<-EOT
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip
  EOT

  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}

# --------------------------------------------------------------------------
# Firewall rules
# --------------------------------------------------------------------------

# Allow GKE pods to reach Vault (for the Agent Injector and pod sidecars)
resource "google_compute_firewall" "vault_from_gke" {
  name    = "allow-vault-from-gke"
  network = "default"
  project = local.project_id

  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }

  source_ranges = [local.gke_subnet_cidr]
  target_tags   = ["vault-server"]
}

# Allow IAP SSH access for Ansible provisioning and admin operations
resource "google_compute_firewall" "vault_iap_ssh" {
  name    = "allow-vault-iap-ssh"
  network = "default"
  project = local.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google's IAP IP range — only IAP tunnels can reach this VM
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["vault-server"]
}

# --------------------------------------------------------------------------
# Outputs consumed by Ansible inventory
# --------------------------------------------------------------------------
output "vault_internal_ip" {
  description = "Vault VM internal IP — used in Ansible inventory and Vault Agent config"
  value       = google_compute_instance.vault.network_interface[0].network_ip
}

output "vault_addr" {
  description = "VAULT_ADDR to use from within the GKE cluster"
  value       = "http://${google_compute_instance.vault.network_interface[0].network_ip}:8200"
}
