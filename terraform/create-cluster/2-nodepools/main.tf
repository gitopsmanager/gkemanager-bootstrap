# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 2: the bootstrap pool, the cluster's only pool until the handover.
#
# The cluster file's pools are NOT made here. Config Connector makes them from
# the CD repo (core-stack components/nodepools, ContainerNodePool), once the
# core stack has installed it; then the handover (4-handover/README.md) runs
# this stage again with runtime.bootstrap_pool false, which deletes the
# bootstrap pool and leaves this state honest. Until then:
#
#   one pool, "bootstrap"    one node per zone, the size of the file's general
#                            pool, so the platform (Argo CD, the core stack,
#                            Config Connector) has somewhere to run
#   labelled sku=general     where the core stack places things (Traefik on
#                            sku=general), as the general pool will be; and
#                            gitopsmanager.io/bootstrap=true
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

locals {
  general = var.cluster.node_pools["general"]
  pools = var.runtime.bootstrap_pool ? {
    bootstrap = {
      machine_type = local.general.machine_type
      count        = 1
      disk_size    = local.general.disk_size
      spot         = false
    }
  } : {}
}

resource "google_container_node_pool" "this" {
  for_each = local.pools

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
      sku                          = "general"
      "gitopsmanager.io/bootstrap" = "true"
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
