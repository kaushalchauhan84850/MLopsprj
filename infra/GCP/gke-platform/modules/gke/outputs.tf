output "cluster_name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Cluster location (zone)."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Kubernetes API endpoint."
  value       = google_container_cluster.this.endpoint
}

output "node_pool_name" {
  description = "Worker node pool name."
  value       = google_container_node_pool.workers.name
}
