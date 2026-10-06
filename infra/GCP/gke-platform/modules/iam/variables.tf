variable "project_id" {
  description = "Project that holds the service account."
  type        = string
}

variable "name" {
  description = "Cluster name; the service account is called <name>-nodes."
  type        = string
}
