# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 2 of 3: the node pools, one per entry in the cluster file.
#
#   labelled sku=<pool>      where the core stack places things (Traefik on
#                            sku=general), as on EKS and AKS
#   GKE_METADATA             Workload Identity on the nodes: pods get their
#                            Kubernetes service account's Google identity,
#                            never the node's
#   auto-upgrade off         GitOps Manager upgrades nodes with the cluster;
#                            auto-repair stays on
#   spot                     optional per pool (spot VMs, taken back by Google
#                            at short notice)
# -----------------------------------------------------------------------------

provider "google" {
  project = var.cluster.project
}

data "google_container_cluster" "this" {
  name     = var.cluster.name
  location = var.cluster.location
}

data "google_service_account" "nodes" {
  account_id = substr("gke-${var.cluster.name}-nodes", 0, 30)
}

resource "google_container_node_pool" "this" {
  for_each = var.cluster.node_pools

  name     = each.key
  cluster  = data.google_container_cluster.this.name
  location = var.cluster.location
  version  = data.google_container_cluster.this.master_version

  # Per zone of a regional cluster.
  node_count = each.value.count

  management {
    auto_repair  = true
    auto_upgrade = false
  }

  node_config {
    machine_type    = each.value.machine_type
    disk_size_gb    = each.value.disk_size
    disk_type       = "pd-balanced"
    spot            = each.value.spot
    service_account = data.google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels = {
      sku = each.key
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    # Counts and versions move by scaling and upgrades, not by a re-run of
    # the create.
    ignore_changes = [node_count, version]
  }
}
