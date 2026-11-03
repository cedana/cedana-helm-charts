#!/usr/bin/env python3
"""nccl-verdict.py SERVER_LOG [--topo nccl-topo.xml] | --watcher DIR

Reads NCCL's own account of its init out of a server log and says whether the topology it built
was whole: every GPU reaches every other over NVL, no SHM hops, full channel count. With the
dumped XML it also lists each GPU's <nvlink> children, which is where a missing link first
shows. With --watcher it summarises nvlink.bt's per-link answers instead.
Stdlib only, so it runs on any old log: python3 nccl-verdict.py today/server-cold.log
"""
import argparse
import collections
import os
import re
import sys
import xml.etree.ElementTree as ET

RANK = re.compile(r"\[(\d+)\] NCCL (INFO|WARN) (.*)$")
CHANNELS = re.compile(r"(\d+) coll channels, (\d+) collnet channels, (\d+) nvls channels, (\d+) p2p channels")
PATHROW = re.compile(r"NCCL INFO (GPU/\S+) :(.*)$")
PATHENT = re.compile(r"(GPU|NVS|CPU|NET|NIC)/(\S+) \((\d+)/([\d.]+)/(\w+)\)")
VIA = re.compile(r"Channel \d+/\d+ : \S+ -> \S+ via (\S+)")


def transport(token):
    # Interleaved ranks glue lines together ("P2P/IPCodes"); keep the prefix that means something.
    for p in ("P2P/IPC", "P2P/CUMEM", "P2P/direct", "P2P/indirect"):
        if token.startswith(p):
            return p
    for p in ("P2P", "SHM", "NET", "COLLNET"):
        if token.startswith(p):
            return p
    return "other"


def verdict_log(path, topo=None):
    chans, warns, via, rows, env, nvls = {}, [], collections.Counter(), {}, [], []
    inits = collections.Counter()
    version = None
    for line in open(path, errors="replace"):
        m = RANK.search(line)
        if not m:
            continue
        rank, level, msg = int(m.group(1)), m.group(2), m.group(3)
        if level == "WARN":
            warns.append(line.rstrip())
            continue
        if version is None and msg.startswith("NCCL version"):
            version = msg
        if "Init START" in msg:
            inits["START"] += 1
        if "Init COMPLETE" in msg:
            inits["COMPLETE"] += 1
        c = CHANNELS.search(msg)
        if c:
            chans.setdefault(rank, []).append(tuple(int(x) for x in c.groups()))
        v = VIA.search(msg)
        if v:
            via[transport(v.group(1))] += 1
        p = PATHROW.search(line)
        if p:
            # Every rank prints the matrix; keep the longest row per GPU, since interleaved
            # output truncates some.
            ents = PATHENT.findall(p.group(2))
            if len(ents) > len(rows.get(p.group(1), [])):
                rows[p.group(1)] = ents
        if "NCCL_TOPO_FILE" in msg or "NCCL_GRAPH_FILE" in msg:
            env.append(msg)
        if "NVLS" in msg and rank == 0:
            nvls.append(msg)

    bad, notes = [], []
    print(f"== {path}")
    print(f"version: {version or '?'}   comm inits: {inits['START']} started, {inits['COMPLETE']} completed")
    for e in env:
        print(f"env: {e}")

    print("\n-- channels per rank (first comm): coll / collnet / nvls / p2p")
    for r in sorted(chans):
        first = chans[r][0]
        print(f"  rank {r}: {first[0]:>3} / {first[1]:>3} / {first[2]:>3} / {first[3]:>3}"
              + (f"   (+{len(chans[r]) - 1} later comms)" if len(chans[r]) > 1 else ""))
    if chans:
        coll = min(c[0][0] for c in chans.values())
        nvlsc = min(c[0][2] for c in chans.values())
        if coll < 8:
            bad.append(f"only {coll} coll channels")
        if nvlsc == 0:
            notes.append("0 nvls channels (the reported side effect; also 0 when NVLS is simply disabled)")
    else:
        bad.append("no channel-count line found (init not reached?)")

    print("\n-- path matrix: per GPU, how it reaches the other GPUs and the switch")
    for src, ents in sorted(rows.items()):
        gpu_types = collections.Counter(t for k, _, _, _, t in ents if k == "GPU" and t != "LOC")
        nvs = [t for k, _, _, _, t in ents if k == "NVS"]
        flag = ""
        if any(t != "NVL" for t in gpu_types) or (nvs and nvs[0] != "NVL"):
            flag = "   <-- NOT ALL NVL"
            bad.append(f"{src} reaches peers via {dict(gpu_types)}, switch {nvs[0] if nvs else 'none'}")
        elif sum(gpu_types.values()) < 7 or not nvs:
            flag = "   (row truncated in the log)"
        print(f"  {src:<14} gpu paths {dict(gpu_types)}  switch {nvs[0] if nvs else 'none'}{flag}")
    if not rows:
        print("  (no path matrix: GRAPH subsystem not logged)")

    print("\n-- transport per channel hop")
    for t, n in via.most_common():
        print(f"  {n:>5}  via {t}")
    if via.get("SHM"):
        bad.append(f"{via['SHM']} SHM hops")

    if nvls:
        print("\n-- NVLS (rank 0)")
        for m in nvls[:12]:
            print(f"  {m}")
    if warns:
        print(f"\n-- NCCL WARN ({len(warns)})")
        for w in warns[:20]:
            print(f"  {w}")

    if topo:
        print(f"\n-- {topo}: <nvlink> children per GPU")
        root = ET.parse(topo).getroot()
        for pci in root.iter("pci"):
            for g in pci.findall("gpu"):
                links = g.findall("nvlink")
                n = sum(int(l.get("count", "1")) for l in links)
                targets = sorted({l.get("target") for l in links})
                flag = "   <-- NO NVLINK" if not links else ""
                print(f"  dev {g.get('dev')} bus {pci.get('busid')}: {n} links -> {targets}{flag}")
                if not links:
                    bad.append(f"gpu dev {g.get('dev')} ({pci.get('busid')}) has no <nvlink> in the dumped topology")

    print("\n== VERDICT:", "DEGRADED" if bad else "HEALTHY")
    for b in bad:
        print(f"   - {b}")
    for n in notes:
        print(f"   note: {n}")
    return 1 if bad else 0


def kv_of(line):
    return dict(x.split("=", 1) for x in line.split()[5:] if "=" in x)


def verdict_watcher(d):
    logs = [os.path.join(d, f) for f in os.listdir(d) if f.startswith("nvlink.") and f.endswith(".log")]
    if not logs:
        print(f"no nvlink.*.log under {d}")
        return 1
    state = collections.defaultdict(collections.Counter)   # bus -> {"ret=.. active=..": n}
    cap, ret_bad, first, opens = collections.Counter(), collections.Counter(), {}, collections.Counter()
    for path in logs:
        for line in open(path, errors="replace"):
            if " NVL-STATE " in line:
                kv = kv_of(line)
                bus = kv.get("bus") or kv.get("dev")
                state[bus][f"ret={kv['ret']} active={kv['active']}"] += 1
                first.setdefault(bus, line.split()[1].split("=", 1)[1])
                if kv["ret"] != "0":
                    ret_bad["nvmlDeviceGetNvLinkState"] += 1
            elif " NVL-CAP " in line:
                kv = kv_of(line)
                cap[(kv.get("bus") or kv.get("dev"), f"ret={kv['ret']} val={kv['val']}")] += 1
            elif " NVL-REMOTE " in line:
                if kv_of(line)["ret"] != "0":
                    ret_bad["nvmlDeviceGetNvLinkRemotePciInfo_v2"] += 1
            elif " OPEN " in line and "ret=-" in line:
                opens[line.split()[6]] += 1
    print(f"== {d}: nvlink.bt per-GPU answers (all ranks summed)")
    for bus in sorted(state):
        print(f"  {bus or '?':<14} first asked wall={first[bus]}  {dict(state[bus])}")
    if cap:
        print("-- capability answers (bus, ret/val) -> n")
        for (bus, k), n in sorted(cap.items()):
            print(f"  {bus or '?':<14} {k}: {n}")
    if ret_bad:
        print(f"-- non-zero NVML returns: {dict(ret_bad)}")
    if opens:
        print("-- failed opens")
        for p, n in opens.most_common(20):
            print(f"  {n:>4} {p}")
    bad = [b for b, s in state.items() if all("active=1" not in k for k in s)]
    print("== WATCHER VERDICT:",
          f"GPU(s) never seen with an active link: {bad}" if bad else "every GPU answered with active links")
    return 1 if bad else 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="?")
    ap.add_argument("--topo")
    ap.add_argument("--watcher")
    a = ap.parse_args()
    if a.watcher:
        sys.exit(verdict_watcher(a.watcher))
    if not a.log:
        ap.error("a server log or --watcher DIR is required")
    sys.exit(verdict_log(a.log, a.topo))
