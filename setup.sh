#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Set up the Google Cloud shared services project for GKE clusters: what the
# create (bootstrap-create-cluster.yml) and the runners need before the first
# run. Run once by an operator (Owner on the projects), from a checkout of
# this repo; safe to re-run: it creates what is missing and changes nothing
# that is there.
#
#   1. the APIs, in the shared services project and each cluster project
#   2. the state bucket (versioned, uniform access)
#   3. an Artifact Registry repository, and the runner image copied into it
#      (crane; the image Cloud Run runs, from your registry, not GHCR)
#   4. prints the repository variables to set in this repo
#
# Then: core-stack's tofu/runners-gcp (the runners, as the module's README
# says), with role_bindings for the create (below), and the bootstrap GitHub
# App's webhook pointed at its scaler.
#
# Environment:
#   SHARED_PROJECT    the shared services project (secrets, runners, state)
#   REGION            its region, e.g. europe-west1
#   CLUSTER_PROJECTS  space-separated projects GKE clusters go in
#   RUNNER_IMAGE      optional: ghcr.io/gitopsmanager/runner@sha256:... (from
#                     runner-images' newest images.json); skipped when empty
#   STATE_BUCKET      optional: default <SHARED_PROJECT>-gke-clusters
#   REPOSITORY        optional: the Artifact Registry repository, default gitopsmanager
set -euo pipefail

: "${SHARED_PROJECT:?set SHARED_PROJECT}"
: "${REGION:?set REGION}"
: "${CLUSTER_PROJECTS:?set CLUSTER_PROJECTS (space-separated)}"
STATE_BUCKET="${STATE_BUCKET:-${SHARED_PROJECT}-gke-clusters}"
REPOSITORY="${REPOSITORY:-gitopsmanager}"

say() { printf '\n== %s\n' "$*"; }

say "APIs"
shared_apis=(secretmanager.googleapis.com run.googleapis.com cloudfunctions.googleapis.com
  cloudbuild.googleapis.com artifactregistry.googleapis.com storage.googleapis.com iam.googleapis.com
  iamcredentials.googleapis.com cloudresourcemanager.googleapis.com dns.googleapis.com compute.googleapis.com)
gcloud services enable "${shared_apis[@]}" --project "$SHARED_PROJECT"
for p in $CLUSTER_PROJECTS; do
  gcloud services enable container.googleapis.com compute.googleapis.com iam.googleapis.com \
    cloudresourcemanager.googleapis.com --project "$p"
done

say "State bucket gs://$STATE_BUCKET"
if gcloud storage buckets describe "gs://$STATE_BUCKET" --project "$SHARED_PROJECT" >/dev/null 2>&1; then
  echo "exists"
else
  gcloud storage buckets create "gs://$STATE_BUCKET" --project "$SHARED_PROJECT" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention
  # Versioned: a state file can be got back.
  gcloud storage buckets update "gs://$STATE_BUCKET" --versioning
fi

say "Artifact Registry $REGION-docker.pkg.dev/$SHARED_PROJECT/$REPOSITORY"
if gcloud artifacts repositories describe "$REPOSITORY" --location "$REGION" --project "$SHARED_PROJECT" >/dev/null 2>&1; then
  echo "exists"
else
  gcloud artifacts repositories create "$REPOSITORY" --repository-format docker --location "$REGION" \
    --project "$SHARED_PROJECT" --description "GitOps Manager images (copied from GHCR)"
fi

if [ -n "${RUNNER_IMAGE:-}" ]; then
  say "Runner image"
  command -v crane >/dev/null || { echo "crane is needed to copy the image (go-containerregistry)"; exit 1; }
  digest="${RUNNER_IMAGE##*@}"
  [[ "$digest" == sha256:* ]] || { echo "RUNNER_IMAGE must be pinned by digest (...@sha256:...)"; exit 1; }
  target="$REGION-docker.pkg.dev/$SHARED_PROJECT/$REPOSITORY/runner"
  gcloud auth print-access-token | crane auth login "$REGION-docker.pkg.dev" -u oauth2accesstoken --password-stdin
  crane copy "$RUNNER_IMAGE" "$target:${digest#sha256:}"
  echo "runner_image = \"$target@$digest\""
fi

say "Next"
cat <<EOF
Repository variables for this repo (Settings > Secrets and variables > Actions):
  CREATE_CLUSTER_STATE_BUCKET = $STATE_BUCKET
  SECRETS_PROJECT             = $SHARED_PROJECT
  CD_REPO                     = <owner>/<cd repo>
  CORE_STACK_REF              = <the core-stack tag>
And: Settings > Actions > General > Workflow permissions > Allow GitHub Actions
to create and approve pull requests (the create commits its record through one).

core-stack tofu/runners-gcp, role_bindings for the create (each cluster project,
and the shared services project):
EOF
for p in $CLUSTER_PROJECTS; do
  for r in roles/container.admin roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser roles/resourcemanager.projectIamAdmin; do
    echo "  { project = \"$p\", role = \"$r\" },"
  done
done
for r in roles/secretmanager.admin roles/resourcemanager.projectIamAdmin; do
  echo "  { project = \"$SHARED_PROJECT\", role = \"$r\" },"
done
echo "and roles/storage.objectAdmin on gs://$STATE_BUCKET:"
echo "  gcloud storage buckets add-iam-policy-binding gs://$STATE_BUCKET --member serviceAccount:<runners SA> --role roles/storage.objectAdmin"
