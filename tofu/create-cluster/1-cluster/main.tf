# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 1 of 3: the GKE cluster, without nodes (2-nodepools adds them).
#
#   the cluster          in the client's existing VPC and subnet (VPC-native,
#                        the subnet's secondary ranges for pods and services);
#                        private nodes; the control plane reached through its
#                        DNS-based endpoint, which IAM guards, so a runner
#                        needs no route into the VPC
#   no release channel   GitOps Manager upgrades the cluster (three times a
#                        year), not GKE: node auto-upgrade is off below, which
#                        a channel would not allow
#   Workload Identity    <project>.svc.id.goog: pods act as Google identities
#                        (External Secrets, external-dns; 3-platform grants)
#   node service account minimal: logs, metrics, image pulls; not the
#                        default compute account, which is Editor
# -----------------------------------------------------------------------------

provider "google" {
  project = var.cluster.project
}

locals {
  labels = merge(
    {
      "gkemanager"  = "managed"
      "deployed-by" = "gitopsmanager"
      "managed-by"  = "opentofu"
      "environment" = var.cluster.zone_prefix
    },
    var.runtime.cost_label_name == "" ? {} : { (lower(var.runtime.cost_label_name)) = lower(var.runtime.cost_label_value) },
  )
  workload_pool = "${var.cluster.project}.svc.id.goog"
}

# The newest GKE version of the cluster file's minor in this location.
data "google_container_engine_versions" "this" {
  location       = var.cluster.location
  version_prefix = "${var.cluster.kubernetes_version}."
}

# ------------------------------------------------------- node service account
resource "google_service_account" "nodes" {
  account_id   = substr("gke-${var.cluster.name}-nodes", 0, 30)
  display_name = "GKE nodes of ${var.cluster.name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.cluster.project
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ------------------------------------------------------------------ cluster
resource "google_container_cluster" "this" {
  name     = var.cluster.name
  location = var.cluster.location

  network    = var.cluster.network.network
  subnetwork = var.cluster.network.subnetwork

  min_master_version = data.google_container_engine_versions.this.latest_master_version

  # Node pools are 2-nodepools' own resources: the default pool goes at once.
  remove_default_node_pool = true
  initial_node_count       = 1
  node_config {
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  release_channel {
    channel = "UNSPECIFIED"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.cluster.network.pods_range
    services_secondary_range_name = var.cluster.network.services_range
  }

  private_cluster_config {
    enable_private_nodes   = true
    master_ipv4_cidr_block = var.cluster.network.master_cidr
  }

  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    http_load_balancing {
      disabled = false
    }
  }

  resource_labels     = local.labels
  deletion_protection = true

  lifecycle {
    # Versions move by the upgrade, not by a re-run of the create; the default
    # pool's settings only matter for the moment it exists.
    ignore_changes = [min_master_version, node_config, initial_node_count]
  }

  depends_on = [google_project_iam_member.nodes]
}
