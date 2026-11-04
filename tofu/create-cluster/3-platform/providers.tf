# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Two projects:
#   google          the cluster's project
#   google.secrets  the shared services project, where the secrets live
# The runner's own credentials for both (Workload Identity Federation from
# GitHub, or the runner's service account).
provider "google" {
  project = var.cluster.project
}

provider "google" {
  alias   = "secrets"
  project = var.runtime.secrets_project
}

data "google_client_config" "this" {}

data "google_container_cluster" "this" {
  name     = var.cluster.name
  location = var.cluster.location
}

locals {
  # The DNS-based endpoint, as gcloud get-credentials --dns-endpoint writes
  # it: a Google-served name with a publicly trusted certificate, reachable
  # from wherever IAM allows, so no CA and no route into the VPC.
  kube_host = "https://${data.google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint}"
}

provider "kubernetes" {
  host  = local.kube_host
  token = data.google_client_config.this.access_token
}

provider "helm" {
  kubernetes = {
    host  = local.kube_host
    token = data.google_client_config.this.access_token
  }
}
