#!/usr/bin/env python3
"""render.py MANIFEST [--node N] [--image I] [--side S] [--restore PATH] [--topo-file]

Rewrites a manifest for one run and prints it. Nothing is edited in place: what ran is in $OUT.
  --node       nodeName on every pod
  --image      image on every container
  --side       SIDE env where a container already has one (the watcher)
  --restore    CEDANA_CHECKPOINT_PATH on the server container
  --topo-file  NCCL_TOPO_FILE on the server, from the ced2575-topo ConfigMap
"""
import argparse
import sys

import yaml

TOPO_MOUNT = "/etc/nccl"


def set_env(env, name, value):
    for e in env:
        if e["name"] == name:
            e["value"] = value
            return
    env.append({"name": name, "value": value})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--node")
    ap.add_argument("--image")
    ap.add_argument("--side")
    ap.add_argument("--restore")
    ap.add_argument("--topo-file", action="store_true")
    a = ap.parse_args()

    docs = [d for d in yaml.safe_load_all(open(a.manifest)) if d]
    for doc in docs:
        spec = doc["spec"]
        if a.node:
            spec["nodeName"] = a.node
        for c in spec.get("initContainers", []) + spec.get("containers", []):
            if a.image:
                c["image"] = a.image
            env = c.setdefault("env", [])
            if a.side and any(e["name"] == "SIDE" for e in env):
                set_env(env, "SIDE", a.side)
            if c["name"] != "server":
                continue
            if a.restore:
                c["env"] = [e for e in env if e["name"] not in ("CEDANA_CHECKPOINT", "CEDANA_CHECKPOINT_PATH")]
                c["env"].append({"name": "CEDANA_CHECKPOINT_PATH", "value": a.restore})
            if a.topo_file:
                set_env(c["env"], "NCCL_TOPO_FILE", f"{TOPO_MOUNT}/topo.xml")
                c.setdefault("volumeMounts", []).append({"name": "topo", "mountPath": TOPO_MOUNT, "readOnly": True})
        if a.topo_file and any(c["name"] == "server" for c in spec.get("containers", [])):
            spec.setdefault("volumes", []).append({"name": "topo", "configMap": {"name": "ced2575-topo"}})
    yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)


if __name__ == "__main__":
    main()
