variable "project_id" {
  description = "Project that holds the network."
  type        = string
}

variable "name" {
  description = "Name prefix for every network resource."
  type        = string
}

variable "region" {
  description = "Region of the subnet, router and NAT."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary range of the node subnet."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for Pod IPs."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for Service IPs."
  type        = string
}
