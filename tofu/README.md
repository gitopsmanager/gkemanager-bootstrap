<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# OpenTofu

Everything here is OpenTofu: the workflow and scripts call `tofu`, never
`terraform`. `create-cluster/` holds the three stages
(`1-cluster`, `2-nodepools`, `3-platform`), each with its own state in GCS and
the same two variables (`cluster`, `runtime`), written by
`scripts/create_cluster.py prepare`.
