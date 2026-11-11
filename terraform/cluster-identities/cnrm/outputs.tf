# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "service_account" {
  description = "Config Connector's Google service account (core-stack components/config-connector names it the same way)."
  value       = google_service_account.cnrm.email
}

output "grantable_roles" {
  value = local.grantable_roles
}
