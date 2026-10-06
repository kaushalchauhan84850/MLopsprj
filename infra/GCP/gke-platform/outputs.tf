output "project_id" {
  description = "Project that holds the cluster."
  value       = var.project_id
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_location" {
  description = "Zone of the cluster."
  value       = module.gke.location
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.gke.endpoint
}

output "network_name" {
  description = "VPC network name."
  value       = module.network.network_name
}

output "node_service_account" {
  description = "Service account used by the worker nodes."
  value       = module.iam.node_service_account_email
}

output "get_credentials_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${module.gke.cluster_name} --zone ${module.gke.location} --project ${var.project_id}"
}
