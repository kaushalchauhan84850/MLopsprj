locals {
  labels = merge(
    {
      managed-by  = "terraform"
      environment = var.environment
      cluster     = var.cluster_name
    },
    var.labels,
  )
}
