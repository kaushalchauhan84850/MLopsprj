variable "project_id" {
  description = "Project that holds the cluster."
  type        = string
}

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "location" {
  description = "Zone of the cluster. A zone (not a region) gives a single control plane."
  type        = string
}

variable "network" {
  description = "Self link of the VPC network."
  type        = string
}

variable "subnetwork" {
  description = "Self link of the node subnet."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for Pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for Services."
  type        = string
}

variable "node_service_account" {
  description = "Email of the service account used by worker nodes."
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes."
  type        = number
}

variable "machine_type" {
  description = "Machine type of the worker nodes."
  type        = string
}

variable "disk_size_gb" {
  description = "Boot disk size per node, in GB."
  type        = number
}

variable "disk_type" {
  description = "Boot disk type."
  type        = string
}

variable "use_spot_nodes" {
  description = "Use Spot VMs for workers."
  type        = bool
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
}

variable "master_ipv4_cidr" {
  description = "/28 range for the control plane."
  type        = string
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the Kubernetes API."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}

variable "deletion_protection" {
  description = "Block cluster deletion."
  type        = bool
}

variable "labels" {
  description = "Labels for the cluster and nodes."
  type        = map(string)
}
