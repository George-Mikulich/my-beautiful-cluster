output "project_id" {
  value       = var.project_id
  description = "GCloud Project ID"
}

output "kubernetes_cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE Cluster Name"
}

output "kubernetes_cluster_host" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE Cluster Host"
}

output "vpc_name" {
  value       = google_compute_network.vpc.self_link
  description = "VPC name"
}

output "subnet_name" {
  value = google_compute_subnetwork.subnet.self_link
  description = "subnet name"
}