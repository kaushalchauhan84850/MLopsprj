# -----------------------------------------------------------------------------
# Required
# -----------------------------------------------------------------------------
variable "project_id" {
  description = "GCP project ID that will hold the cluster. The project must already exist and have billing enabled."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

# -----------------------------------------------------------------------------
# Location
# -----------------------------------------------------------------------------
variable "region" {
  description = "GCP region. us-east1 = South Carolina."
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "Zone for the cluster. A zonal cluster has exactly ONE control plane (the single 'master'), and node_count worker nodes in this zone."
  type        = string
  default     = "us-east1-b"

  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must be inside the chosen region (for example region us-east1 -> zone us-east1-b)."
  }
}

# -----------------------------------------------------------------------------
# Naming and labels
# -----------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name. Also the prefix for the VPC, subnet, router and node service account. Max 20 chars so derived names stay inside GCP limits."
  type        = string
  default     = "gke-jobs"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,18}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be 1-20 chars: lowercase letters, digits, hyphens; start with a letter; end with a letter or digit."
  }
}

variable "environment" {
  description = "Environment label (dev, staging, prod ...)."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9_-]{1,63}$", var.environment))
    error_message = "environment must be lowercase letters, digits, hyphens or underscores (max 63 chars)."
  }
}

variable "labels" {
  description = "Extra labels added to the cluster and nodes."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Worker nodes
# -----------------------------------------------------------------------------
variable "node_count" {
  description = "Number of worker nodes (fixed size, no autoscaling)."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "machine_type" {
  description = "Machine type of the worker nodes. Pick a bigger type if your jobs need more CPU or memory."
  type        = string
  default     = "e2-standard-2"
}

variable "disk_size_gb" {
  description = "Boot disk size per worker node, in GB."
  type        = number
  default     = 50
}

variable "disk_type" {
  description = "Boot disk type: pd-standard, pd-balanced or pd-ssd."
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.disk_type)
    error_message = "disk_type must be pd-standard, pd-balanced or pd-ssd."
  }
}

variable "use_spot_nodes" {
  description = "Use Spot VMs for the workers. Much cheaper, but Google can reclaim them at any time. Good for fault-tolerant batch jobs."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Cluster behaviour
# -----------------------------------------------------------------------------
variable "release_channel" {
  description = "GKE release channel: RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the Kubernetes API endpoint. Replace the default with your own IP (x.x.x.x/32)."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "anywhere-CHANGE-ME"
    }
  ]
}

variable "deletion_protection" {
  description = "Block cluster deletion. Keep false so terraform destroy works; if you set it to true you must apply false again before destroying."
  type        = bool
  default     = false
}

variable "disable_apis_on_destroy" {
  description = "Disable the Google APIs again on destroy. Default false: disabling APIs is a common cause of destroy errors, and enabled APIs cost nothing."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Network ranges (change only if they clash with networks you peer or VPN with)
# -----------------------------------------------------------------------------
variable "subnet_cidr" {
  description = "Primary range of the node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for Pod IPs."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for Service IPs."
  type        = string
  default     = "10.30.0.0/20"
}

variable "master_ipv4_cidr" {
  description = "/28 range used by the Google-managed control plane (private cluster peering)."
  type        = string
  default     = "172.16.0.0/28"
}
