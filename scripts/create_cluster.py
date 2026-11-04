#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""
Steps of bootstrap-create-cluster.yml (GKE) that are not OpenTofu.

    prepare    validate clusters/<name>.json, write the variables every stage
               reads (build/create-cluster/create.auto.tfvars.json)
    register   write clusters/<name>.outputs.json: what core-stack's install
               and arc-env-map read (cloud gcp, project, location, network)

The GKE counterpart of eksmanager-bootstrap's scripts/create_cluster.py.
Standard library only.
"""
import argparse
import ipaddress
import json
import os
import re
import sys

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,38}[a-z0-9]$")          # GKE: 40 characters at most
PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
LOCATION_RE = re.compile(r"^[a-z]+-[a-z]+[0-9](-[a-z])?$")         # region or zone
VERSION_RE = re.compile(r"^1\.[0-9]{2}$")
MACHINE_RE = re.compile(r"^[a-z][a-z0-9]*-[a-z0-9-]+$")
NS_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
RESOURCE_RE = re.compile(r"^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$")

SPEC_KEYS = {"name", "project", "location", "zone_prefix", "dns_zone", "kubernetes_version",
             "network", "node_pools", "global_namespaces"}
NETWORK_KEYS = {"network", "subnetwork", "pods_range", "services_range", "master_cidr"}
POOL_KEYS = {"machine_type", "count", "disk_size", "spot"}


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fail(f"{what} not found: {path}")
    except json.JSONDecodeError as e:
        fail(f"{what} is not valid JSON ({path}): {e}")


def gh_output(**kv):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            for k, v in kv.items():
                f.write(f"{k}={v}\n")


def validate(spec):
    errors = []
    extra = set(spec) - SPEC_KEYS
    if extra:
        errors.append(f"unknown keys {sorted(extra)}")
    for k in sorted(SPEC_KEYS - {"global_namespaces"} - set(spec)):
        errors.append(f"missing {k}")
    if errors:
        return errors
    if not NAME_RE.match(spec["name"]):
        errors.append("name: lowercase letters, digits and hyphens, 2-40 characters, starting with a letter")
    if not PROJECT_RE.match(spec["project"]):
        errors.append(f"project: not a Google Cloud project ID: {spec['project']!r}")
    if not LOCATION_RE.match(spec["location"]):
        errors.append(f"location: a region (europe-west1) or a zone (europe-west1-b), got {spec['location']!r}")
    if not VERSION_RE.match(str(spec["kubernetes_version"])):
        errors.append("kubernetes_version: major.minor, e.g. 1.36")
    if not str(spec["dns_zone"]).endswith(".") and "." not in str(spec["dns_zone"]):
        errors.append("dns_zone: a DNS name, e.g. gce-dev.client.example.com")
    net = spec["network"]
    if not isinstance(net, dict):
        errors.append("network must be an object")
    else:
        extra = set(net) - NETWORK_KEYS
        if extra:
            errors.append(f"network: unknown keys {sorted(extra)}")
        for k in ("network", "subnetwork", "pods_range", "services_range"):
            if not RESOURCE_RE.match(str(net.get(k, ""))):
                errors.append(f"network.{k}: a Google Cloud resource name (the VPC, its subnet, and the subnet's secondary ranges)")
        try:
            cidr = ipaddress.ip_network(net.get("master_cidr", ""))
            if cidr.prefixlen != 28:
                errors.append("network.master_cidr must be a /28")
        except ValueError:
            errors.append("network.master_cidr: a /28 for the control plane, e.g. 172.16.0.0/28")
    pools = spec["node_pools"]
    if not isinstance(pools, dict) or not pools:
        errors.append("node_pools: at least one pool")
    else:
        for name, pool in pools.items():
            if not RESOURCE_RE.match(name):
                errors.append(f"node_pools.{name}: pool names are Google Cloud resource names")
            if not isinstance(pool, dict):
                errors.append(f"node_pools.{name} must be an object")
                continue
            extra = set(pool) - POOL_KEYS
            if extra:
                errors.append(f"node_pools.{name}: unknown keys {sorted(extra)}")
            if not MACHINE_RE.match(str(pool.get("machine_type", ""))):
                errors.append(f"node_pools.{name}.machine_type: e.g. e2-standard-4")
            if not isinstance(pool.get("count"), int) or pool["count"] < 0:
                errors.append(f"node_pools.{name}.count: a whole number of nodes per zone")
            if not isinstance(pool.get("disk_size"), int) or pool["disk_size"] < 30:
                errors.append(f"node_pools.{name}.disk_size: GB, at least 30")
            if "spot" in pool and not isinstance(pool["spot"], bool):
                errors.append(f"node_pools.{name}.spot: true or false")
        if "general" not in pools:
            errors.append("node_pools: a pool named general (Traefik runs on sku=general nodes)")
    for ns in spec.get("global_namespaces", []):
        if not NS_RE.match(str(ns)):
            errors.append(f"global_namespaces: {ns!r} is not a namespace name")
    return errors


def cmd_prepare(a):
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    if spec.get("name") != a.cluster:
        fail(f"clusters/{a.cluster}.json names the cluster {spec.get('name')!r}")
    errors = validate(spec)
    if errors:
        for e in errors:
            print(f"::error::clusters/{a.cluster}.json: {e}")
        sys.exit(1)
    runtime = json.loads(a.runtime)
    spec.setdefault("global_namespaces", [])
    for pool in spec["node_pools"].values():
        pool.setdefault("spot", False)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "create.auto.tfvars.json"), "w", encoding="utf-8") as f:
        json.dump({"cluster": spec, "runtime": runtime}, f, indent=2)
    gh_output(project=spec["project"], location=spec["location"])
    print(f"{a.cluster}: {spec['project']} {spec['location']}, Kubernetes {spec['kubernetes_version']}, "
          f"pools {', '.join(spec['node_pools'])}")


def cmd_register(a):
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    outputs = load_json(a.tofu_outputs, "OpenTofu outputs")

    def out(k):
        v = outputs.get(k, {})
        return v.get("value") if isinstance(v, dict) else v

    record = {
        "cloud": "gcp",
        "project": spec["project"],
        "location": spec["location"],
        "kubernetes_version": spec["kubernetes_version"],
        "network": out("network"),
        "subnetwork": out("subnetwork"),
        "dns_endpoint": out("dns_endpoint"),
        "workload_pool": out("workload_pool"),
    }
    path = os.path.join(a.clusters_dir, f"{a.cluster}.outputs.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print(f"Wrote {path}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("prepare")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--runtime", required=True, help="JSON object of values from the workflow")
    s.add_argument("--out", default="build/create-cluster")
    s.set_defaults(fn=cmd_prepare)
    s = sub.add_parser("register")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--tofu-outputs", required=True)
    s.set_defaults(fn=cmd_register)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
