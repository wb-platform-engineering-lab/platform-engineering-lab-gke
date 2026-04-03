module "networking" {
  source     = "./modules/networking"
  project_id = var.project_id
  region     = var.region
}

module "gke" {
  source         = "./modules/gke"
  project_id     = var.project_id
  region         = var.region
  network        = module.networking.network_name
  subnetwork     = module.networking.subnetwork_name
}

module "bigquery" {
  source     = "./modules/bigquery"
  project_id = var.project_id
  region     = var.region
}
