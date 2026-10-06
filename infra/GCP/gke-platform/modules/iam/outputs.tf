output "node_service_account_email" {
  description = "Email of the node service account. Resolves only after the role bindings exist, so nodes are created after them and destroyed before them."
  value       = google_service_account.nodes.email

  depends_on = [google_project_iam_member.nodes]
}
