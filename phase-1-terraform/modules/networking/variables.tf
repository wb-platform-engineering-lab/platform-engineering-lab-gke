variable "region" {
  description = "GCP region"
  type        = string
}


variable "vpc_name" {
  description = "VPC name"
  type        = string
}

variable "subnetwork_name" {
  description = "Subnetwork name"
  type        = string
}

variable "subnetwork_cidr" {
  description = "Subnetwork CIDR"
  type        = string
}

variable "pods_ip_cidr_range" {
  description = "Pods IP CIDR range"
  type        = string
}

variable "services_ip_cidr_range" {
  description = "Services IP CIDR range"
  type        = string
}

variable "allow_internal_firewall_name" {
  description = "Allow internal firewall name"
  type        = string
}

variable "router_name" {
  description = "Router name"
  type        = string
}

variable "nat_name" {
  description = "NAT name"
  type        = string
}