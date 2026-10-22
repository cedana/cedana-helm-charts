"""Render the cedana variant of the P/D baseline. CED-2549.

The baseline (10-pd-native.yaml) is the vendor's file byte for byte and is never edited in
place -- it IS the native control, and a diff against the zip has to stay empty. This writes a
patched copy to stdout instead, which the runners capture into $OUT so what ran is recorded.

WHY NOT A FULL YAML ROUND TRIP. Document 1 is a ConfigMap whose only key is launch.py, a 440
line Python program carried as a block scalar. Passing that through safe_load/safe_dump
reserializes it -- quoting style, trailing whitespace, line folding all up to the emitter -- and
the result is a launch.py that is probably but not provably identical to the one the baseline was
validated with. A node-NIC-selection prelude is not something to be "probably" right about. So
only the two Pod documents are parsed; every other document is passed through as raw text.

Documents are split on a bare `---` at column 0. The baseline's YAML anchors (&id001..&id003)
live entirely inside the frontend document, which is never parsed, so anchor expansion cannot
leak across the split.

Usage:
    python3 11-pd-cedana.patch.py 10-pd-native.yaml                       # cold cedana pair
    python3 11-pd-cedana.patch.py 10-pd-native.yaml \
        --restore prefill=/scratch/ckpt/aaa --restore decode=/scratch/ckpt/bbb
"""

import argparse
import sys

import yaml

# The two GPU pods. The frontend has no GPU and no engine, so it runs native in every variant:
# putting it under the runtime would add an interception layer to the one process in the pair
# that does no CUDA work, for no signal.
ROLE_BY_POD = {
    "cedana-glm53-pd-prefill": "prefill",
    "cedana-glm53-pd-decode": "decode",
}
CHECKPOINT_ENV = ("CEDANA_CHECKPOINT", "CEDANA_CHECKPOINT_PATH")


def patch_pod(doc, restore_path, runtime_class):
    """runtimeClassName on the pod, CEDANA_CHECKPOINT_PATH on its single container."""
    doc["spec"]["runtimeClassName"] = runtime_class
    for container in doc["spec"]["containers"]:
        env = [e for e in container.get("env", []) if e["name"] not in CHECKPOINT_ENV]
        if restore_path:
            env.append({"name": "CEDANA_CHECKPOINT_PATH", "value": restore_path})
        container["env"] = env
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline")
    ap.add_argument(
        "--restore",
        action="append",
        default=[],
        metavar="ROLE=PATH",
        help="restore this role from PATH; repeatable. Omit for a cold cedana start.",
    )
    ap.add_argument("--runtime-class", default="cedana")
    args = ap.parse_args()

    restore = {}
    for item in args.restore:
        role, _, path = item.partition("=")
        if role not in ROLE_BY_POD.values() or not path:
            ap.error(f"--restore wants prefill=PATH or decode=PATH, got {item!r}")
        restore[role] = path

    raw_docs = open(args.baseline).read().split("\n---\n")
    patched_roles = set()
    out = []

    for raw in raw_docs:
        # Cheap enough to parse every document to find out what it is; only the Pods are kept
        # as objects. A parse failure here is a malformed baseline and should be loud.
        doc = yaml.safe_load(raw)
        name = (doc or {}).get("metadata", {}).get("name")
        role = ROLE_BY_POD.get(name) if (doc or {}).get("kind") == "Pod" else None
        if role is None:
            out.append(raw.rstrip("\n"))
            continue
        patched_roles.add(role)
        doc = patch_pod(doc, restore.get(role), args.runtime_class)
        out.append(yaml.safe_dump(doc, sort_keys=False).rstrip("\n"))

    missing = set(ROLE_BY_POD.values()) - patched_roles
    if missing:
        sys.exit(f"{args.baseline}: no Pod document for {', '.join(sorted(missing))}")
    unused = set(restore) - patched_roles
    if unused:
        sys.exit(f"--restore named {', '.join(sorted(unused))}, which is not in the baseline")

    print("\n---\n".join(out))


if __name__ == "__main__":
    main()
