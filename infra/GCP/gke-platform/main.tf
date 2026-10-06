# -----------------------------------------------------------------------------
# Composition root. Create order is top to bottom, destroy order is the reverse:
#
#   apis -> network + iam -> gke (control plane, then worker node pool)
#
# On `terraform destroy`: node pool -> cluster -> IAM roles/service account ->
# NAT/router/subnet/VPC -> (APIs are left enabled).
# -----------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  project_id    = var.project_id
  name          = var.cluster_name
  region        = var.region
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  depends_on = [google_project_service.apis]
}

module "iam" {
  source = "./modules/iam"

  project_id = var.project_id
  name       = var.cluster_name

  depends_on = [google_project_service.apis]
}

module "gke" {
  source = "./modules/gke"

  project_id           = var.project_id
  name                 = var.cluster_name
  location             = var.zone
  network              = module.network.network_self_link
  subnetwork           = module.network.subnet_self_link
  pods_range_name      = module.network.pods_range_name
  services_range_name  = module.network.services_range_name
  node_service_account = module.iam.node_service_account_email

  node_count       = var.node_count
  machine_type     = var.machine_type
  disk_size_gb     = var.disk_size_gb
  disk_type        = var.disk_type
  use_spot_nodes   = var.use_spot_nodes
  release_channel  = var.release_channel
  master_ipv4_cidr = var.master_ipv4_cidr

  authorized_networks = var.authorized_networks
  deletion_protection = var.deletion_protection
  labels              = local.labels

  # Whole-module dependencies: the NAT gateway and the IAM role bindings must
  # exist before nodes boot, and are removed only after nodes are gone.
  depends_on = [module.network, module.iam]
}
