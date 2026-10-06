terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59, < 7.0" # EKS module v21 requires >= 6.59
    }
  }
}

provider "aws" {
  region = var.region

  # Every resource gets these tags. scripts/verify-destroyed.sh uses the
  # Project tag to prove that nothing was left behind after `terraform destroy`.
  default_tags {
    tags = local.tags
  }
}
