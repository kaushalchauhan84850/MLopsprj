data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project   = var.cluster_name
    ManagedBy = "terraform"
  }
}

################################################################################
# Network
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 200)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # cheaper; use one_nat_gateway_per_az = true for HA
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

################################################################################
# EKS control plane ("master", run by AWS) + 3 managed worker nodes
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  # Gives the identity running Terraform admin rights inside the cluster.
  enable_cluster_creator_admin_permissions = true

  # Logging off by default: no CloudWatch log group to leak on destroy.
  create_cloudwatch_log_group = var.enable_control_plane_logs
  enabled_log_types           = var.enable_control_plane_logs ? ["audit", "api", "authenticator"] : []

  # AWS never deletes a KMS key immediately; it goes to "pending deletion"
  # for 7-30 days. Use the shortest window.
  kms_key_deletion_window_in_days = 7

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
  }

  # Generous timeouts so a slow (but healthy) delete is not reported as an error.
  timeouts = {
    create = "40m"
    update = "60m"
    delete = "40m"
  }

  eks_managed_node_groups = {
    workers = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_count
      max_size     = var.node_count
      desired_size = var.node_count

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size_gb
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      labels = {
        role = "worker"
      }

      timeouts = {
        create = "40m"
        update = "60m"
        delete = "60m"
      }
    }
  }
}

################################################################################
# Destroy-time cleanup
#
# Terraform destroys resources in reverse dependency order. Because this
# resource depends on module.eks and module.vpc, it is destroyed FIRST, while
# the cluster and VPC still exist. Its destroy-time provisioner runs
# scripts/pre-destroy.sh, which removes everything Kubernetes created outside
# Terraform (load balancers, volumes, orphaned network interfaces). Those are
# what normally cause "DependencyViolation" / "resource in error state" during
# `terraform destroy`.
#
# Requires aws CLI, kubectl and jq on the machine running terraform.
# Escape hatch (only if nothing was ever deployed to the cluster):
#   SKIP_K8S_CLEANUP=1 terraform destroy
################################################################################
resource "terraform_data" "pre_destroy_cleanup" {
  count = var.destroy_cleanup_enabled ? 1 : 0

  depends_on = [module.eks, module.vpc]

  # Destroy-time provisioners may only reference `self`, so everything the
  # script needs is stored here.
  input = {
    cluster_name = module.eks.cluster_name
    region       = var.region
    vpc_id       = module.vpc.vpc_id
    script       = "${path.module}/scripts/pre-destroy.sh"
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "bash '${self.input.script}'"

    environment = {
      CLUSTER_NAME = self.input.cluster_name
      AWS_REGION   = self.input.region
      VPC_ID       = self.input.vpc_id
    }
  }
}
