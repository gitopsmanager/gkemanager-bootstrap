# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Config Connector's own identity on one GKE cluster: the operator that makes
# the cluster's node pools and workload identities from the CD repo
# (core-stack components/config-connector, namespaced mode, the nodepools
# namespace only).
#
# Its own state (identity-cnrm), run by the create (bootstrap-create-cluster.yml,
# after 1-cluster) and by bootstrap-cluster-identities.yml (mode create or
# update). Config Connector never changes this identity itself: it may not
# touch a service account that is not gom-*, and this one is cnrm-*.
#
#   cnrm-<cluster>          the Google service account (cut to 30 characters)
#   Workload Identity       for cnrm-system/cnrm-controller-manager-nodepools,
#                           the controller namespaced mode runs for nodepools
#   node pools              a custom role with the node pool calls and nothing
#                           else about any cluster (no cluster create, update
#                           or delete), and actAs on this cluster's node
#                           service account only
#   workload identities     a custom role to make, change and delete service
#                           accounts and their IAM policies, conditioned to
#                           gom-* accounts: gom-app-* it makes, gom-* shared
#                           ones it links (never cnrm-* or gke-*)
#   their grants            Project IAM Admin conditioned so it may add or
#                           remove only the roles in grantable_roles (the
#                           "fixed list"; core-stack tools/cd_identities_gcp.py
#                           GRANTABLE_ROLES). Anything else needs an admin, or
#                           a workflow with more power.
# -----------------------------------------------------------------------------

provider "google" {
  project = var.cluster.project
}

locals {
  workload_pool = "${var.cluster.project}.svc.id.goog"
  role_suffix   = replace(var.cluster.name, "-", "_")

  # The roles Config Connector may grant on the project, and no others.
  grantable_roles = [
    "roles/storage.objectViewer",
    "roles/storage.objectUser",
    "roles/secretmanager.secretAccessor",
  ]
}

resource "google_service_account" "cnrm" {
  account_id   = replace(substr("cnrm-${var.cluster.name}", 0, 30), "/-+$/", "")
  display_name = "Config Connector on ${var.cluster.name}"
  description  = "GitOps Manager: node pools and workload identities of GKE cluster ${var.cluster.name}, from the CD repo."
}

# Namespaced mode: one controller per namespace, cnrm-controller-manager-<namespace>.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.cnrm.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[cnrm-system/cnrm-controller-manager-nodepools]"
}

# ------------------------------------------------------------------ node pools
resource "google_project_iam_custom_role" "nodepools" {
  role_id     = "gomCnrmNodePools_${local.role_suffix}"
  title       = "GitOps Manager node pools (${var.cluster.name})"
  description = "Config Connector on ${var.cluster.name}: node pool calls only."
  permissions = [
    "container.clusters.get",
    "container.nodePools.create",
    "container.nodePools.delete",
    "container.nodePools.get",
    "container.nodePools.list",
    "container.nodePools.update",
    "container.operations.get",
    "container.operations.list",
  ]
}

resource "google_project_iam_member" "nodepools" {
  project = var.cluster.project
  role    = google_project_iam_custom_role.nodepools.id
  member  = "serviceAccount:${google_service_account.cnrm.email}"
}

# A node pool runs as the cluster's node service account (1-cluster): acting
# as it, and no other.
data "google_service_account" "nodes" {
  account_id = substr("gke-${var.cluster.name}-nodes", 0, 30)
}

resource "google_service_account_iam_member" "act_as_nodes" {
  service_account_id = data.google_service_account.nodes.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.cnrm.email}"
}

# ---------------------------------------------------------- workload identities
resource "google_project_iam_custom_role" "app_accounts" {
  role_id     = "gomCnrmAppAccounts_${local.role_suffix}"
  title       = "GitOps Manager workload identities (${var.cluster.name})"
  description = "Config Connector on ${var.cluster.name}: gom-* service accounts and their IAM policies."
  permissions = [
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.delete",
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.update",
    "iam.serviceAccounts.getIamPolicy",
    "iam.serviceAccounts.setIamPolicy",
  ]
}

# Creating names the project; everything else names the service account,
# which must be gom-*.
resource "google_project_iam_member" "app_accounts" {
  project = var.cluster.project
  role    = google_project_iam_custom_role.app_accounts.id
  member  = "serviceAccount:${google_service_account.cnrm.email}"
  condition {
    title       = "gom service accounts only"
    description = "Config Connector may create service accounts, and change only gom-* ones."
    expression  = "resource.type != 'iam.googleapis.com/ServiceAccount' || resource.name.extract('serviceAccounts/{account}@').startsWith('gom-')"
  }
}

# -------------------------------------------------------------- their grants
resource "google_project_iam_member" "grants" {
  project = var.cluster.project
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.cnrm.email}"
  condition {
    title       = "fixed list of roles"
    description = "Config Connector may grant and revoke only these roles on the project."
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([${join(", ", [for r in local.grantable_roles : "'${r}'"])}])"
  }
}
