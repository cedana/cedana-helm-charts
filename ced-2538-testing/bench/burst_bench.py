#!/usr/bin/env python3
"""CED-2538 load generator: manufacture the TTFT tail, then let it be attributed.

The reported symptom is a TTFT tail during a 127k-151k-token prompt burst while median TTFT and
decode speed sit at parity. A tail that only appears under burst is a queueing or stall effect, so
a steady request rate will not reproduce it -- the arrival pattern is part of the repro, not a
detail of it. Three stages, in order, each answering a different question:

  WARM  JIT, DeepGEMM and the shape buckets for both prompt lengths. The per-call doc is explicit
        that an unwarmed native baseline reads ~2x slow (DeepSeek measured 575 vs 1099 tok/s), so
        a cold run would show cedana *winning* and tell us nothing. Not recorded.

  A     One long request at a time (concurrency 1), alternating 127k and 151k. No queueing, no
        contention: this is the clean per-length TTFT floor and the p50 reference the tail is
        measured against. If A already differs between native and cedana, the problem is not a
        tail and stages B/C are the wrong instrument.

  B     Burst: idle gap, then K identical-length prompts released at once, repeated. Recreates the
        queueing the report describes. Each round has a fresh prefix, so nothing is served from
        cache and every round is a real prefill of K x len tokens.

  C     HiCache load-back, the stage the other two cannot reach. Send P distinct long prefixes
        (populating GPU cache and, under write_through, the host tier), then flood with unrelated
        long traffic to force GPU-side eviction, then re-send the original P. The re-sends must
        come back from the host tier, so their TTFT isolates load-back cost. `cached_tokens` from
        --enable-cache-report is the proof: a re-send with cached_tokens ~= prompt_len went through
        the cache, one with cached_tokens ~= 0 was evicted past the host tier too and must be
        dropped from the analysis rather than read as a slow load-back.

Every record carries both CLOCK_MONOTONIC and wall time. The watcher stamps its snapshots the same
way, and that is the only thing that lets a bpftrace line be joined to the request that caused it.

Output: one JSON object per line on OUT (default /out/bench.jsonl), plus a human summary on stdout.
Env: HOST PORT OUT LEN_A LEN_B BURST_K BURST_ROUNDS BURST_IDLE_S C_PREFIXES C_FLOOD SLOW_MS
     VOCAB_LO VOCAB_HI WARM_ONLY
"""
import json
import os
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

HOST = os.environ.get("HOST", "localhost")
PORT = int(os.environ.get("PORT", "30000"))
OUT = os.environ.get("OUT", "/out/bench.jsonl")
LEN_A = int(os.environ.get("LEN_A", "127000"))
LEN_B = int(os.environ.get("LEN_B", "151000"))
BURST_K = int(os.environ.get("BURST_K", "8"))
BURST_ROUNDS = int(os.environ.get("BURST_ROUNDS", "12"))
BURST_IDLE_S = float(os.environ.get("BURST_IDLE_S", "20"))
C_PREFIXES = int(os.environ.get("C_PREFIXES", "6"))
C_FLOOD = int(os.environ.get("C_FLOOD", "8"))
SLOW_MS = float(os.environ.get("SLOW_MS", "8000"))
# Conservative id window: GLM-5.2's vocab is ~151k, but low ids avoid any added/special range.
VOCAB_LO = int(os.environ.get("VOCAB_LO", "1000"))
VOCAB_HI = int(os.environ.get("VOCAB_HI", "60000"))
WARM_ONLY = os.environ.get("WARM_ONLY", "0") == "1"

URL = f"http://{HOST}:{PORT}/generate"
out_fh = None


def ids_for(seed: int, n: int):
    """Deterministic token ids. The same seed is the same prompt, so a re-send is a real cache hit
    and a different seed is a real miss -- stage C depends on both halves of that."""
    rng = random.Random(seed)
    return [rng.randrange(VOCAB_LO, VOCAB_HI) for _ in range(n)]


def emit(rec):
    out_fh.write(json.dumps(rec) + "\n")
    out_fh.flush()
    if rec.get("ttft_ms") is not None and rec["ttft_ms"] >= SLOW_MS:
        # Printed so it lands in `kubectl logs` next to the watcher's own trigger lines.
        print(
            f"[ced-2538] SLOW ttft={rec['ttft_ms']:.0f}ms stage={rec['stage']} "
            f"len={rec['prompt_len']} cached={rec.get('cached_tokens')} "
            f"mono={rec['submit_mono']:.6f} wall={rec['submit_wall']:.6f} id={rec['id']}",
            flush=True,
        )


def one(req_id, stage, rnd, seed, n, max_new=4):
    """One streamed request. TTFT is measured to the first chunk that carries text, not to the
    first byte: sglang can emit an empty opening chunk, and timing to that would under-report."""
    body = {
        "input_ids": ids_for(seed, n),
        "sampling_params": {"max_new_tokens": max_new, "temperature": 0},
        "stream": True,
    }
    rec = {
        "id": req_id, "stage": stage, "round": rnd, "seed": seed, "prompt_len": n,
        "submit_mono": time.monotonic(), "submit_wall": time.time(),
        "ttft_ms": None, "e2e_ms": None, "cached_tokens": None, "error": None,
    }
    t0 = time.monotonic()
    try:
        with requests.post(URL, json=body, stream=True, timeout=(30, 1800)) as r:
            r.raise_for_status()
            for raw in r.iter_lines(decode_unicode=True):
                if not raw or not raw.startswith("data:"):
                    continue
                payload = raw[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if rec["ttft_ms"] is None and chunk.get("text"):
                    rec["ttft_ms"] = (time.monotonic() - t0) * 1000.0
                meta = chunk.get("meta_info") or {}
                if "cached_tokens" in meta:
                    rec["cached_tokens"] = meta["cached_tokens"]
    except Exception as exc:  # noqa: BLE001 - one bad request must not end the run
        rec["error"] = f"{type(exc).__name__}: {exc}"
    rec["e2e_ms"] = (time.monotonic() - t0) * 1000.0
    emit(rec)
    return rec


def banner(msg):
    print(f"[ced-2538] mono={time.monotonic():.6f} wall={time.time():.6f} {msg}", flush=True)


def wait_ready():
    """Poll until the engine answers. Prints WHY it is still waiting: a wrong HOST fails DNS here,
    and a silently swallowed exception looks exactly like a server that is merely slow to load."""
    banner(f"waiting for http://{HOST}:{PORT}/get_model_info")
    tries = 0
    while True:
        tries += 1
        try:
            r = requests.get(f"http://{HOST}:{PORT}/get_model_info", timeout=10)
            if r.ok:
                banner("server ready")
                return
            print(f"[ced-2538] not ready (HTTP {r.status_code}), try {tries}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"[ced-2538] not ready, try {tries}: {type(exc).__name__}: {exc}", flush=True)
        time.sleep(10)


def stage_warm():
    banner("WARM start (not recorded)")
    for n in (LEN_A, LEN_B):
        for i in range(2):
            body = {
                "input_ids": ids_for(900000 + i, n),
                "sampling_params": {"max_new_tokens": 4, "temperature": 0},
            }
            try:
                requests.post(URL, json=body, timeout=(30, 1800)).raise_for_status()
            except Exception as exc:  # noqa: BLE001
                print(f"[ced-2538] warm {n} failed: {exc}", flush=True)
            banner(f"WARM len={n} pass={i}")
    banner("WARM done")


def stage_a():
    banner("STAGE A start (concurrency 1, the TTFT floor)")
    k = 0
    for i in range(8):
        for n in (LEN_A, LEN_B):
            one(f"a{k}", "A", i, 100000 + k, n)
            k += 1
    banner("STAGE A done")


def stage_b():
    banner(f"STAGE B start (bursts of {BURST_K}, {BURST_ROUNDS} rounds, {BURST_IDLE_S}s idle)")
    with ThreadPoolExecutor(max_workers=BURST_K) as pool:
        for rnd in range(BURST_ROUNDS):
            # Idle first: the queue must be empty so the burst is a real step, and the gap gives
            # the watcher a quiet baseline immediately before each burst.
            time.sleep(BURST_IDLE_S)
            n = LEN_A if rnd % 2 == 0 else LEN_B
            banner(f"STAGE B round={rnd} len={n} releasing {BURST_K}")
            base = 200000 + rnd * 1000
            futs = [pool.submit(one, f"b{rnd}-{j}", "B", rnd, base + j, n)
                    for j in range(BURST_K)]
            ttfts = sorted(f.result()["ttft_ms"] or float("nan") for f in futs)
            banner(f"STAGE B round={rnd} ttft_ms min={ttfts[0]:.0f} max={ttfts[-1]:.0f}")
    banner("STAGE B done")


def stage_c():
    banner(f"STAGE C start (HiCache load-back, {C_PREFIXES} prefixes)")
    seeds = [300000 + i for i in range(C_PREFIXES)]
    # 1. Populate: each prefix prefilled once, write_through puts it on the host tier.
    for i, s in enumerate(seeds):
        one(f"c-fill{i}", "C-fill", 0, s, LEN_A)
    banner("STAGE C fill done; flooding to evict GPU-side")
    # 2. Evict: unrelated long traffic, enough of it to push the prefixes out of GPU cache.
    with ThreadPoolExecutor(max_workers=min(4, C_FLOOD)) as pool:
        futs = [pool.submit(one, f"c-flood{j}", "C-flood", 0, 400000 + j, LEN_B)
                for j in range(C_FLOOD)]
        for f in futs:
            f.result()
    banner("STAGE C flood done; re-sending prefixes (these must load back from host)")
    # 3. Load back: same ids, so a hit is genuine. Sequential, to time each load-back alone.
    for i, s in enumerate(seeds):
        r = one(f"c-back{i}", "C-back", 1, s, LEN_A)
        banner(f"STAGE C back{i} ttft={r['ttft_ms']} cached_tokens={r['cached_tokens']}")
    banner("STAGE C done")


def summarize():
    import statistics
    rows = {}
    with open(OUT) as fh:
        for line in fh:
            r = json.loads(line)
            if r["ttft_ms"] is not None:
                rows.setdefault((r["stage"], r["prompt_len"]), []).append(r["ttft_ms"])
    print("\n[ced-2538] TTFT summary (ms)", flush=True)
    print(f"{'stage':<10}{'len':>8}{'n':>5}{'p50':>10}{'p90':>10}{'max':>10}", flush=True)
    for key in sorted(rows):
        v = sorted(rows[key])
        p50 = statistics.median(v)
        p90 = v[min(len(v) - 1, int(0.9 * len(v)))]
        print(f"{key[0]:<10}{key[1]:>8}{len(v):>5}{p50:>10.0f}{p90:>10.0f}{v[-1]:>10.0f}", flush=True)


def main():
    global out_fh
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out_fh = open(OUT, "a", buffering=1)
    wait_ready()
    stage_warm()
    if WARM_ONLY:
        banner("WARM_ONLY set; stopping")
        return
    stage_a()
    stage_b()
    stage_c()
    summarize()
    banner(f"all stages done; records in {OUT}")


if __name__ == "__main__":
    sys.exit(main())
