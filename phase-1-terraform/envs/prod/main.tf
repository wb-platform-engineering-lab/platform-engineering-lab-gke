locals {
  environment   = var.environment
  project_id    = var.project_id
  naming_prefix = "${local.project_id}-${local.environment}"
}

module "networking" {
  source                       = "../../modules/networking"
  region                       = var.region
  vpc_name                     = "${local.naming_prefix}-vpc"
  subnetwork_name              = "${local.naming_prefix}-subnet"
  subnetwork_cidr              = var.subnetwork_cidr
  pods_ip_cidr_range           = var.pods_ip_cidr_range
  services_ip_cidr_range       = var.services_ip_cidr_range
  allow_internal_firewall_name = "${local.naming_prefix}-allow-internal"
  router_name                  = "${local.naming_prefix}-router"
  nat_name                     = "${local.naming_prefix}-nat"
}

module "gke" {
  source         = "../../modules/gke"
  project_id     = var.project_id
  region         = var.region
  network        = module.networking.network_name
  subnetwork     = module.networking.subnetwork_name
  environment    = local.environment
  cluster_name   = "${local.naming_prefix}-gke"
  node_count     = var.node_count
  machine_type   = var.machine_type
  min_node_count = var.min_node_count
  max_node_count = var.max_node_count
}

module "bigquery" {
  source     = "../../modules/bigquery"
  project_id = var.project_id
  region     = var.region
  dataset_id = replace("${local.naming_prefix}-dataset", "-", "_")
}
