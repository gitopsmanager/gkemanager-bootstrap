<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# 4-handover (not built yet)

**A placeholder.** This describes the stage; there is no code here yet, and
`bootstrap-create-cluster.yml` does not run it.

The create makes the cluster with one small pool, `bootstrap` (`2-nodepools`),
so the platform has somewhere to run. The cluster file's own pools are made by
Config Connector, from the CD repo, like every later change to them. The
handover moves the cluster from the one to the other, once the core stack has
installed Config Connector (`install_node_pool_operator` on in
`stacks/<cluster>.json`; core-stack `components/config-connector`), whose
identity the create has made (`terraform/cluster-identities/cnrm`).

1. **Render the pools.** The cluster file's `node_pools` become core-stack
   `components/nodepools/values.<cluster>.yaml` entries: `general` and the
   rest as they are, a pool named `system` with `System: true` (tainted
   `CriticalAddonsOnly`), `count` as `Min` and `Max` (per zone), `disk_size`
   as `DiskSize`, `spot` as `Spot`. Then core-stack's `nodepools.yml` renders
   them into `<cluster>/nodepools/render/` in the CD repo as ContainerNodePools
   and syncs them.
2. **Wait until they are Ready.** `nodepools.yml`'s own check
   (`components/nodepools/verify.py --cloud gcp`): every pool RUNNING at its
   file's settings.
3. **Delete the bootstrap pool with Terraform.** `2-nodepools` again, with
   `runtime.bootstrap_pool` false: Terraform deletes the pool, GKE drains its
   node, and its pods move to the new pools (both carry `sku=general`). The
   state then holds no pool, and later re-runs of the create change nothing.

Never the other way round: the bootstrap pool goes only after the new pools
are Ready, so the cluster always has a pool.
