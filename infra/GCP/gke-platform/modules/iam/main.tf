# Dedicated, least-privilege service account for the worker nodes (instead of
# the broad default Compute Engine service account).
#
# Roles are granted with google_project_iam_member, which is NON-authoritative:
# it adds/removes only this one binding and never touches other members of the
# role. That keeps destroy from clobbering IAM that other people manage.

locals {
  node_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
}

resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "${var.name}-nodes"
  display_name = "GKE worker nodes for ${var.name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = local.node_roles

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}
