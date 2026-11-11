<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# Terraform

Everything here is Terraform 1.11.0, which each workflow installs on its runner
(`scripts/install_terraform.sh`). `create-cluster/` holds the three stages
(`1-cluster`, `2-nodepools`, `3-platform`), each with its own state in GCS and
the same two variables (`cluster`, `runtime`), written by
`scripts/create_cluster.py prepare`. `cluster-identities/cnrm` is Config
Connector's identity, a fourth state (`identity-cnrm`) run by the create after
`1-cluster` and by `bootstrap-cluster-identities.yml`, with the same two
variables. `create-cluster/4-handover` describes the hand-over from the
bootstrap pool to Config Connector's pools (not built yet).
