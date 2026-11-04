# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 3 of 3: what the cluster needs before Argo CD takes over. The GKE
# counterpart of eksmanager-bootstrap's 4-platform.
#
#   StorageClasses               default-retain and default, as on EKS
#   namespaces                   the cluster file's, and argocd
#   the Argo CD admin password   per cluster, in the shared services
#                                project's Secret Manager
#   Workload Identity grants     External Secrets reads the secrets; external-
#                                dns writes the Cloud DNS zone. Granted to their
#                                Kubernetes service accounts directly (no
#                                Google service accounts to keep)
#   Argo CD itself               from core-stack's argo-cd component, and its
#                                infra project
#
# Secret names are bare in Secret Manager (no "/"), as core-stack reads them
# on Google Cloud: <cluster>-argocd-admin-secret, global-cd-repo-secret.
# StorageClasses as on EKS and AKS: default-retain (which the Elasticsearch
# volumes ask for) and default, neither GKE's default class (standard-rwo is
# left alone).
# After this, core-stack's install puts everything else through Argo CD.
# -----------------------------------------------------------------------------

locals {
  admin_secret_name   = "${var.cluster.name}-argocd-admin-secret"
  cd_repo_secret_name = "global-cd-repo-secret"
  namespaces          = setunion(toset(var.cluster.global_namespaces), toset(["argocd"]))
  workload_pool       = "${var.cluster.project}.svc.id.goog"

  # A Kubernetes service account as an IAM principal (Workload Identity
  # Federation for GKE).
  ksa = {
    eso          = "principal://iam.googleapis.com/projects/${data.google_project.cluster.number}/locations/global/workloadIdentityPools/${local.workload_pool}/subject/ns/external-secrets/sa/external-secrets"
    external_dns = "principal://iam.googleapis.com/projects/${data.google_project.cluster.number}/locations/global/workloadIdentityPools/${local.workload_pool}/subject/ns/kube-system/sa/external-dns"
  }
}

data "google_project" "cluster" {
  project_id = var.cluster.project
}

# ----------------------------------------------------------- StorageClasses
# The GKE persistent disk CSI driver, balanced disks. Every field but the
# annotations is immutable, and default-retain is exactly what core-stack's
# eck-operator renders on Google Cloud, so its sync later changes nothing.
resource "kubernetes_storage_class_v1" "this" {
  for_each = {
    "default-retain" = "Retain"
    "default"        = "Delete"
  }

  metadata {
    name = each.key
  }
  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = each.value
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type = "pd-balanced"
  }
}

# --------------------------------------------------------------- namespaces
resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.value
  }

  # Removing a namespace from the cluster file must never delete it.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].labels, metadata[0].annotations]
  }
}

# ------------------------------------------------- Argo CD admin password
resource "random_password" "argocd_admin" {
  length  = 32
  special = false
}

# The agent's format, so the argo-cd component's ExternalSecret and the GUI
# read it unchanged: {"data":{"password":"<base64>"}}. Created, then left to
# the GUI, which may set a new value.
resource "google_secret_manager_secret" "argocd_admin" {
  provider  = google.secrets
  secret_id = local.admin_secret_name
  labels    = { "gkemanager" = "managed", "cluster" = var.cluster.name }
  replication {
    auto {}
  }
  lifecycle {
    ignore_changes = all
  }
}

resource "google_secret_manager_secret_version" "argocd_admin" {
  provider    = google.secrets
  secret      = google_secret_manager_secret.argocd_admin.id
  secret_data = jsonencode({ data = { password = base64encode(random_password.argocd_admin.result) } })
  lifecycle {
    ignore_changes = all
  }
}

# ------------------------------------------------ Workload Identity grants
# External Secrets reads every secret in the shared services project, as the
# store does on AWS and Azure; external-dns manages the zone's records.
resource "google_project_iam_member" "eso_secrets" {
  provider = google.secrets
  project  = var.runtime.secrets_project
  role     = "roles/secretmanager.secretAccessor"
  member   = local.ksa.eso
}

resource "google_project_iam_member" "external_dns" {
  project = var.runtime.dns_project
  role    = "roles/dns.admin"
  member  = local.ksa.external_dns
}

# ----------------------------------------------------- Argo CD's secrets
# Written directly, once: the External Secrets Operator is not installed yet.
# Once it is, the argo-cd component's ExternalSecrets take these over.

# The CD repo's credentials, as the GitHub App install writes them (or a
# username and token put there by hand): a Kubernetes Secret manifest as
# JSON, data.* base64-encoded.
data "google_secret_manager_secret_version" "cd_repo" {
  provider = google.secrets
  secret   = local.cd_repo_secret_name
}

locals {
  cd_repo = jsondecode(data.google_secret_manager_secret_version.cd_repo.secret_data).data
}

resource "kubernetes_secret_v1" "repo" {
  metadata {
    name      = "repo-secret"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  # The GitHub App's fields, or a username and token (cd_auth token: for those
  # who'd rather not make an App), whichever the stored value holds.
  data = merge(
    { type = "git", url = var.runtime.cd_repo_url },
    can(local.cd_repo.githubAppID) ? {
      githubAppID             = base64decode(local.cd_repo.githubAppID)
      githubAppInstallationID = base64decode(local.cd_repo.githubAppInstallationID)
      githubAppPrivateKey     = base64decode(local.cd_repo.githubAppPrivateKey)
      } : {
      username = base64decode(local.cd_repo.username)
      password = base64decode(local.cd_repo.password)
    },
  )

  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# argocd-server will not start without argocd-secret.
resource "kubernetes_secret_v1" "argocd" {
  metadata {
    name      = "argocd-secret"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }
  data = {
    "admin.password"      = bcrypt(random_password.argocd_admin.result)
    "admin.passwordMtime" = timestamp()
  }

  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# ------------------------------------------------------------------ Argo CD
# core-stack's argo-cd component at the pinned ref: the chart and values Argo
# CD will manage itself with. Installed once; after that Argo CD manages
# itself from the CD repo. Without the web UI routes and the infra project,
# whose kinds don't exist until this release has installed the CRDs; the
# project is applied just after (terraform_data.infra_project).
locals {
  argo_cd_set = [
    { name = "global.gom.cloud", value = "gcp" },
    { name = "global.gom.cluster", value = var.cluster.name },
    { name = "global.gom.dnsZone", value = var.cluster.dns_zone },
    { name = "global.gom.zonePrefix", value = var.cluster.zone_prefix },
    { name = "global.gom.cdRepoUrl", value = var.runtime.cd_repo_url },
    { name = "argo-cd.global.domain", value = "${var.cluster.name}-argocd-argocd-web-ui.${var.cluster.dns_zone}" },
    { name = "repoSecret.enabled", value = "false" },
    { name = "adminPassword.enabled", value = "false" },
    { name = "zoneCert.enabled", value = "false" },
  ]
}

resource "helm_release" "argo_cd" {
  name              = "argo-cd"
  namespace         = "argocd"
  chart             = "${var.runtime.core_stack_dir}/components/argo-cd"
  dependency_update = true
  wait              = true
  timeout           = 900

  set = concat(local.argo_cd_set, [
    { name = "webUi.enabled", value = "false" },
    { name = "project.enabled", value = "false" },
  ])

  lifecycle {
    ignore_changes = all
  }

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_secret_v1.repo,
    kubernetes_secret_v1.argocd,
  ]
}

resource "terraform_data" "infra_project" {
  input = var.cluster.name

  provisioner "local-exec" {
    command = "bash ${path.module}/apply-infra-project.sh"
    environment = {
      PROJECT  = var.cluster.project
      LOCATION = var.cluster.location
      CLUSTER  = var.cluster.name
      CHART    = "${var.runtime.core_stack_dir}/components/argo-cd"
      SET_ARGS = join(" ", [for s in local.argo_cd_set : "${s.name}=${s.value}"])
    }
  }

  depends_on = [helm_release.argo_cd]
}
