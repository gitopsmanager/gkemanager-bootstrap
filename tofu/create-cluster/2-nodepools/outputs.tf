# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "node_pools" {
  value = { for k, p in google_container_node_pool.this : k => { machine_type = p.node_config[0].machine_type, spot = p.node_config[0].spot } }
}
