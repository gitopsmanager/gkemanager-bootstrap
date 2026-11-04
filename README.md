<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# gkemanager-bootstrap

Create GKE clusters for GitOps Manager with OpenTofu: the Google Cloud
counterpart of [`eksmanager-bootstrap`](https://github.com/gitopsmanager/eksmanager-bootstrap)
and [`aksmanager-bootstrap`](https://github.com/gitopsmanager/aksmanager-bootstrap).
Then install the core stack on the cluster with
[core-stack](https://github.com/gitopsmanager/core-stack)'s `install-core-stack.yml`.

Open source under the [Apache License 2.0](LICENSE). Copyright GitOps Manager, S.L.

> **Beta: not tested.** Written 1 Nov 2026 and never run. The stages pass
> `tofu validate` and the create script was tested locally, but nothing has
> run in GitHub Actions or against Google Cloud. Expect changes, and don't use
> it for clusters you depend on yet.

## What a run does

Actions -> **bootstrap-create-cluster** -> Run workflow, with the cluster's
name (`clusters/<name>.json`). A dry run validates the file and plans stage 1
only.

| Stage | Creates |
|---|---|
| `1-cluster` | The cluster in your VPC and subnet (VPC-native), private nodes, the control plane's DNS-based endpoint, Workload Identity, no release channel (GitOps Manager upgrades it), and a node service account with only logging, monitoring and image-pull roles |
| `2-nodepools` | One node pool per entry, labelled `sku=<pool>` (Traefik runs on `sku=general`), Workload Identity metadata, auto-repair on and auto-upgrade off, spot optional |
| `3-platform` | StorageClasses `default-retain` and `default` (as on EKS and AKS); the cluster file's namespaces; the Argo CD admin password in Secret Manager (`<cluster>-argocd-admin-secret`); Workload Identity grants (External Secrets may read the shared services project's secrets, external-dns may manage the Cloud DNS zone); Argo CD from core-stack, and its `infra` project |

Then it records the cluster in `clusters/<name>.outputs.json` (project,
location, network, DNS endpoint), which core-stack's install reads.

Each stage is its own state (`gs://<bucket>/projects/<project>/clusters/<name>/<stage>/`),
so re-running is safe. A cancelled run stops OpenTofu gracefully instead of
killing it mid-write (`scripts/run_tofu_stage.sh`).

## Before the first run

`setup.sh` does the first part (the APIs, the state bucket, an Artifact
Registry repository with the runner image copied in) and prints the rest:
the repository variables, and the roles for core-stack's `tofu/runners-gcp`.

- **A VPC and subnet** with two secondary ranges, for pods and for services,
  and a `/28` free for the control plane (`network.master_cidr`). Today the
  network is an input, not created here.
- **A GCS bucket** for the state.
- **The shared services project's Secret Manager** holding
  `global-cd-repo-secret`: the CD repo's GitHub App, as GitOps Manager writes
  it (a Kubernetes Secret manifest as JSON).
- **A runner:** GitOps Manager's long-job runner on Google Cloud (label
  `gom-gcp-long`, core-stack's `tofu/runners-gcp`) by default, acting as its
  service account. Elsewhere (`CREATE_CLUSTER_RUNNER`, e.g. GitHub's runners),
  Workload Identity Federation from this repo to a service account. Either
  service account needs:
  - in the cluster's project: Kubernetes Engine Admin, Service Account Admin
    and Service Account User (the node service account), and Project IAM Admin
    (the node service account's roles);
  - in the shared services project: Secret Manager Admin and Project IAM Admin
    (External Secrets' grant);
  - in the Cloud DNS zone's project: Project IAM Admin (external-dns's grant);
  - on the state bucket: Storage Object Admin;
  - on a Shared VPC subnet, if the subnet is shared: Compute Network User.
- **Repository variables:** listed at the top of
  [`.github/workflows/bootstrap-create-cluster.yml`](.github/workflows/bootstrap-create-cluster.yml).
- **Workflows may open pull requests:** the create records
  `clusters/<cluster>.outputs.json` through a pull request squash-merged at once
  (gitopsmanager/Auto-Commit-Squash-Merge), with the run's own token. Turn on
  Settings -> Actions -> General -> Workflow permissions -> **Allow GitHub
  Actions to create and approve pull requests** (off by default); with a
  required review on `main`, let GitHub Actions bypass it.

## The cluster file

[`clusters/example-gce-dev-gke1.json`](clusters/example-gce-dev-gke1.json):
`name` (2-40 characters), `project`, `location` (a region for a regional
cluster, or a zone), `zone_prefix`, `dns_zone`, `kubernetes_version`
(major.minor; the newest patch in that location is used), `network`,
`node_pools` (one named `general` is required; `count` is per zone) and
`global_namespaces`.

## Not here yet

- Writing the secrets (`global-cd-repo-secret`, the GitHub App's) into the
  shared services project: the GUI does it on the SaaS; by hand otherwise.
- Creating the VPC, NAT and Cloud DNS zones; Let's Encrypt certificates for
  the zones.
- The cluster monitor on Google Cloud is core-stack's (`tofu/cluster-monitor-gcp`).
