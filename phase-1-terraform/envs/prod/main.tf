locals {
  environment = var.environment
  project_id  = var.project_id
  region      = var.region

  naming_prefix = "${local.project_id}-${local.environment}"

  common_tags = {
    project     = local.project_id
    environment = local.environment
    managedBy   = "terraform"
  }
}



module "networking" {
  source     = "../../modules/networking"
  project_id = var.project_id
  region     = var.region
  vpc_name = "${local.naming_prefix}-vpc"
  subnetwork_name = "${local.naming_prefix}-subnet"
  subnetwork_cidr = var.subnetwork_cidr
  pods_ip_cidr_range = var.pods_ip_cidr_range
  services_ip_cidr_range = var.services_ip_cidr_range
  allow_internal_firewall_name = "${local.naming_prefix}-allow-internal"
  router_name = "${local.naming_prefix}-router"
  nat_name = "${local.naming_prefix}-nat"
}

module "gke" {
  source       = "../../modules/gke"
  project_id   = var.project_id
  region       = var.region
  network      = module.networking.network_name
  subnetwork   = module.networking.subnetwork_name
  environment  = local.environment
  cluster_name = "${local.naming_prefix}-gke"
}


module "bigquery" {
  source     = "../../modules/bigquery"
  project_id = var.project_id
  region     = var.region
  dataset_id = replace("${local.naming_prefix}-dataset", "-", "_")
}
