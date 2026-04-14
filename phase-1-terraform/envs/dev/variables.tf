variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Deployment environment: dev, staging, or prod"
  type        = string
}

variable "node_count" {
  description = "Initial node count for the node pool"
  type        = number
  default     = 1
}

variable "machine_type" {
  description = "GCE machine type for cluster nodes"
  type        = string
  default     = "e2-standard-2"
}

variable "min_node_count" {
  type    = number
  default = 1
}

variable "max_node_count" {
  type    = number
  default = 3
}

variable "subnetwork_cidr" {
  description = "Subnetwork CIDR"
  type        = string
  default     = "10.0.0.0/8"
}

variable "pods_ip_cidr_range" {
  description = "Pods IP CIDR range"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_ip_cidr_range" {
  description = "Services IP CIDR range"
  type        = string
  default     = "10.2.0.0/16"
}