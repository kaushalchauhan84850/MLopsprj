# Google APIs the stack needs. Every module depends on this, so on destroy the
# APIs are handled LAST, after all resources that use them are gone.
#
# disable_on_destroy defaults to false: leaving an API enabled is free, whereas
# disabling it is a classic source of destroy errors ("dependent services").
locals {
  required_apis = [
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = var.disable_apis_on_destroy
  disable_dependent_services = var.disable_apis_on_destroy
}
