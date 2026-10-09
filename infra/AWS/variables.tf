variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the Project tag on every resource."
  type        = string
  default     = "heavy-cluster"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,98}$", var.cluster_name))
    error_message = "cluster_name must start with a letter and contain only letters, digits and hyphens."
  }
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Use a version that is still in standard support (see the EKS version calendar), otherwise AWS charges the higher extended-support rate."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.0.0.0/16."
  }
}

variable "node_instance_type" {
  description = "EC2 instance type for the worker nodes"
  type        = string
  default     = "t3.large" # 2 vCPU / 8 GB, burstable. For heavier jobs use m6i.2xlarge, c7i.* (CPU) or r7i.* (memory).
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "node_disk_size_gb" {
  description = "Root volume size per worker node (GB)"
  type        = number
  default     = 100
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint, e.g. [\"203.0.113.10/32\"]. Deliberately has no default so the API is never opened to the world by accident."
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "api_allowed_cidrs must be a non-empty list of valid CIDR blocks."
  }
}

variable "enable_control_plane_logs" {
  description = "Send EKS control plane logs to CloudWatch. Off by default: the log group is a classic source of leftovers after destroy (EKS can re-create it)."
  type        = bool
  default     = false
}

variable "destroy_cleanup_enabled" {
  description = "Run scripts/pre-destroy.sh before destroying the cluster. Removes load balancers, volumes and orphaned network interfaces that Kubernetes created outside Terraform and that otherwise block deletion of the VPC."
  type        = bool
  default     = true
}
