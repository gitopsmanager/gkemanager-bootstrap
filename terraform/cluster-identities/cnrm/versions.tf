# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Terraform (see terraform/README.md). State:
#   gs://<CREATE_CLUSTER_STATE_BUCKET>/projects/<project>/clusters/<cluster>/identity-cnrm/
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  backend "gcs" {}
}
