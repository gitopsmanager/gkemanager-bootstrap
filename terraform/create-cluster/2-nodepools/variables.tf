# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Both come from build/create-cluster/create.auto.tfvars.json, written by
# scripts/create_cluster.py prepare. Every stage takes the same two.

variable "cluster" {
  description = "The validated clusters/<name>.json."
  type = object({
    name               = string
    project            = string
    location           = string
    zone_prefix        = string
    dns_zone           = string
    kubernetes_version = string
    network = object({
      network        = string
      subnetwork     = string
      pods_range     = string
      services_range = string
      master_cidr    = string
    })
    node_pools = map(object({
      machine_type = string
      count        = number
      disk_size    = number
      spot         = bool
    }))
    global_namespaces = list(string)
  })
}

variable "runtime" {
  description = "What the workflow knows: the shared services project (the secrets), the Cloud DNS zone's project, the CD repo, the core-stack checkout, the cost label."
  type = object({
    secrets_project  = string
    dns_project      = string
    cd_repo_url      = string
    core_stack_dir   = string
    cost_label_name  = string
    cost_label_value = string
    # The handover sets it false, which deletes the bootstrap pool.
    bootstrap_pool = optional(bool, true)
  })
}
