# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_version" {
  value = google_container_cluster.this.master_version
}

output "network" {
  value = var.cluster.network.network
}

output "subnetwork" {
  value = var.cluster.network.subnetwork
}

output "dns_endpoint" {
  description = "The control plane's DNS-based endpoint (gcloud container clusters get-credentials --dns-endpoint)."
  value       = google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "workload_pool" {
  value = local.workload_pool
}

output "node_service_account" {
  value = google_service_account.nodes.email
}
