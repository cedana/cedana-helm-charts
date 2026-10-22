"""pd_bench.py -- CED-2549 load generator. Cut down from CED-2538's burst_bench.py.

THE SHAPE IS THE REPRO, so it is controlled directly rather than approximated by a rate-based
tool. The report is specific: 5.8k-token prompts, single requests fine, 8 concurrent gives 2 fast
returns and 6 hangs, and the same deployment without cedana passes 8/8 and 2x16/16. So the stages
are exactly that ladder and nothing else:

    STAGES=1x4,8x3,16x2     concurrency x rounds

Stage 1 is the control that MUST pass -- if it does not, the run is not about concurrency and
everything downstream is noise. Stage 8 is the repro. Stage 16 is the 2x16 case.

WHY EVERY REQUEST GETS A UNIQUE PREFIX. Prefill runs --enable-prefix-caching. Byte-identical
prompts would be served from its prefix cache, the block set handed to decode would differ from
the one the report describes, and a clean run would prove nothing. Each request starts with its
own random token salt, so every prefill is genuine work and every transfer is a real transfer.

WHY IT STREAMS. A hung request and a slow request are different findings. Streaming separates
them: ttft_s is when the first token arrived, which for a P/D pair is the moment the KV transfer
completed and decode started generating. A request that hangs with no TTFT never got its KV; one
that gets a TTFT and then stalls lost the pair mid-decode.

THE DEADLINE IS DELIBERATELY SHORTER THAN vLLM'S. vLLM raises "RPC call to execute_model timed
out" at 300 s and the engine dies. DEADLINE_S defaults to 120 so that a hang is recorded, the
runner's stall detector fires, and the watcher gets its snapshot while the processes are still
alive and dumpable. Raising it past ~250 trades the snapshot for a longer wait and gets nothing.

Stdlib only: the engine image has no guaranteed HTTP client and there is no egress to install one.

Env: HOST PORT MODEL OUT PROMPT_TOKENS MAX_TOKENS STAGES IDLE_S DEADLINE_S
"""

import http.client
import json
import os
import random
import socket
import string
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

HOST = os.environ.get("HOST", "cedana-glm53-pd-frontend")
PORT = int(os.environ.get("PORT", "8990"))
MODEL = os.environ.get("MODEL", "cedana-eval-glm53-pd")
OUT = os.environ.get("OUT", "/out/bench.jsonl")
PROMPT_TOKENS = int(os.environ.get("PROMPT_TOKENS", "5800"))
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "64"))
STAGES = os.environ.get("STAGES", "1x4,8x3,16x2")
IDLE_S = float(os.environ.get("IDLE_S", "20"))
DEADLINE_S = float(os.environ.get("DEADLINE_S", "120"))

_out_lock = threading.Lock()
_words = None


def log(msg):
    print(f"[bench] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def record(row):
    with _out_lock:
        with open(OUT, "a") as fh:
            fh.write(json.dumps(row) + "\n")


def corpus():
    """A fixed pseudo-word vocabulary. Deterministic across runs so two runs are comparable."""
    global _words
    if _words is None:
        rng = random.Random(2549)
        _words = [
            "".join(rng.choice(string.ascii_lowercase) for _ in range(rng.randint(3, 9)))
            for _ in range(4096)
        ]
    return _words


def make_prompt(n_words, salt):
    """Unique per request: the salt defeats prefill's prefix cache, the body is filler."""
    rng = random.Random(salt)
    words = corpus()
    body = " ".join(rng.choice(words) for _ in range(n_words))
    return f"[{salt}] Summarise the following in one sentence.\n\n{body}"


def chat(prompt, stage, round_i, idx, concurrency, deadline):
    """One streaming chat completion. Returns the record it also writes."""
    payload = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
    })
    row = {
        "stage": stage, "round": round_i, "idx": idx, "concurrency": concurrency,
        "wall": time.time(), "mono": time.monotonic(),
        "status": None, "ttft_s": None, "latency_s": None,
        "prompt_tokens": None, "completion_tokens": None, "error": None,
    }
    t0 = time.monotonic()
    conn = http.client.HTTPConnection(HOST, PORT, timeout=deadline)
    try:
        conn.request("POST", "/v1/chat/completions", body=payload,
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        row["status"] = resp.status
        if resp.status != 200:
            row["error"] = resp.read(2048).decode("utf-8", "replace")
            row["latency_s"] = time.monotonic() - t0
            record(row)
            return row
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except ValueError:
                continue
            # TTFT is the first chunk carrying generated text. For a P/D pair that is the moment
            # the KV transfer landed and decode began, which is exactly what hangs here.
            choices = chunk.get("choices") or []
            if row["ttft_s"] is None and choices:
                delta = choices[0].get("delta") or {}
                if delta.get("content") or delta.get("reasoning_content"):
                    row["ttft_s"] = time.monotonic() - t0
            usage = chunk.get("usage")
            if usage:
                row["prompt_tokens"] = usage.get("prompt_tokens")
                row["completion_tokens"] = usage.get("completion_tokens")
        row["latency_s"] = time.monotonic() - t0
    except (TimeoutError, socket.timeout):
        row["status"] = "deadline"
        row["latency_s"] = time.monotonic() - t0
        row["error"] = f"no response within {deadline}s -- THIS IS THE HANG"
    except OSError as exc:
        # A socket error after the engine dies on its own 300 s timeout looks like this.
        row["status"] = "error"
        row["latency_s"] = time.monotonic() - t0
        row["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        conn.close()
    record(row)
    return row


def calibrate():
    """Find words-per-prompt for PROMPT_TOKENS by asking the server what it actually counted.

    The OpenAI chat API takes text, not token ids, so the only authority on the token count is the
    server's own usage.prompt_tokens. Two cheap probes converge well inside a percent, which is
    far closer than the symptom needs -- and every record carries the real count anyway.
    """
    n_words = int(PROMPT_TOKENS * 0.75)
    for attempt in range(3):
        row = chat(make_prompt(n_words, f"cal{attempt}"), "calibrate", 0, attempt, 1, 60)
        got = row.get("prompt_tokens")
        if not got:
            log(f"calibration probe {attempt} returned no usage ({row['status']}); "
                f"keeping {n_words} words")
            return n_words
        log(f"calibration probe {attempt}: {n_words} words -> {got} tokens")
        if abs(got - PROMPT_TOKENS) <= PROMPT_TOKENS * 0.02:
            return n_words
        n_words = max(1, int(n_words * PROMPT_TOKENS / got))
    return n_words


def run_round(stage, n_words, concurrency, round_i):
    """All requests released together: a burst, not a ramp. The barrier is the point."""
    barrier = threading.Barrier(concurrency)

    def one(idx):
        prompt = make_prompt(n_words, f"{stage}-{round_i}-{idx}-{time.time()}")
        try:
            barrier.wait(timeout=60)
        except threading.BrokenBarrierError:
            log(f"  barrier broke before stage={stage} round={round_i} idx={idx}")
        return chat(prompt, stage, round_i, idx, concurrency, DEADLINE_S)

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        rows = list(pool.map(one, range(concurrency)))

    ok, hung, other = [], [], []
    for r in rows:
        if r["status"] == 200 and r["ttft_s"] is not None:
            ok.append(r)
        elif r["status"] == "deadline":
            hung.append(r)
        else:
            other.append(r)
    ttfts = sorted(r["ttft_s"] for r in ok)
    summary = (f"stage={stage} round={round_i} c={concurrency} "
               f"ok={len(ok)}/{concurrency} hung={len(hung)} other={len(other)}")
    if ttfts:
        summary += (f" ttft_min={ttfts[0]:.2f}s ttft_med={ttfts[len(ttfts) // 2]:.2f}s "
                    f"ttft_max={ttfts[-1]:.2f}s")
    log(summary)
    if hung:
        log(f"  *** {len(hung)} of {concurrency} did not respond within {DEADLINE_S}s "
            f"-- the reported symptom ***")
    return rows


def main():
    stages = []
    for item in STAGES.split(","):
        c, _, r = item.strip().partition("x")
        stages.append((int(c), int(r)))

    log(f"target http://{HOST}:{PORT} model={MODEL}")
    log(f"stages={STAGES} prompt_tokens={PROMPT_TOKENS} deadline={DEADLINE_S}s")
    open(OUT, "a").close()

    n_words = calibrate()
    log(f"using {n_words} words per prompt")

    all_rows = []
    for concurrency, rounds in stages:
        for round_i in range(rounds):
            all_rows += run_round(f"c{concurrency}", n_words, concurrency, round_i)
            # Idle between rounds so one round's transfers cannot overlap the next, and so the
            # runner's stall detector sees a clean quiet period between bursts.
            time.sleep(IDLE_S)

    log("---- summary ----")
    for concurrency, _ in stages:
        rows = [r for r in all_rows if r["concurrency"] == concurrency]
        if not rows:
            continue
        ok = sum(1 for r in rows if r["status"] == 200 and r["ttft_s"] is not None)
        hung = sum(1 for r in rows if r["status"] == "deadline")
        log(f"c={concurrency}: {ok}/{len(rows)} ok, {hung} hung, "
            f"{len(rows) - ok - hung} other")
    log(f"records in {OUT}")
    log("bench finished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
