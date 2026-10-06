output "network_name" {
  description = "VPC network name."
  value       = google_compute_network.vpc.name
}

output "network_self_link" {
  description = "VPC network self link."
  value       = google_compute_network.vpc.self_link
}

output "subnet_self_link" {
  description = "Node subnet self link."
  value       = google_compute_subnetwork.nodes.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range used for Pods."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Name of the secondary range used for Services."
  value       = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
}

output "nat_name" {
  description = "Cloud NAT name."
  value       = google_compute_router_nat.nat.name
}
