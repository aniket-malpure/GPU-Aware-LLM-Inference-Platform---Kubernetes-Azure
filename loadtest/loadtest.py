#!/usr/bin/env python3
"""Concurrent load test for an OpenAI-compatible vLLM endpoint.

Streams chat completions so it can measure time-to-first-token (TTFT) per
request, then reports latency percentiles, token throughput and errors.

Examples:
    kubectl -n llm port-forward svc/llm-vllm-inference 8000:8000
    python loadtest.py --concurrency 50 --duration 300
    python loadtest.py --concurrency 10 --requests 200 --out results.json
    python loadtest.py --ramp 5,10,25,50 --step-seconds 120   # autoscaler demo
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import sys
import time
from dataclasses import asdict, dataclass, field

import httpx

PROMPTS = [
    "Explain how a Kubernetes scheduler decides which node a pod runs on.",
    "Write a Python function that merges overlapping intervals, with tests.",
    "Summarize the trade-offs between tensor parallelism and pipeline parallelism.",
    "Draft a short incident postmortem for a GPU node that hit an XID 79 error.",
    "What causes CUDA out-of-memory errors during LLM inference and how do you fix them?",
    "Compare Go and Rust for writing infrastructure controllers.",
    "Give three ways to reduce time-to-first-token for a large language model server.",
    "Explain paged attention to a backend engineer in under 150 words.",
]


@dataclass
class Result:
    ok: bool
    status: int
    ttft_s: float | None = None
    latency_s: float | None = None
    output_tokens: int = 0
    error: str = ""


@dataclass
class Summary:
    target: str
    concurrency: int
    duration_s: float
    requests: int
    successes: int
    errors: int
    error_rate: float
    rps: float
    output_tokens_per_s: float
    ttft_p50_s: float | None
    ttft_p95_s: float | None
    ttft_p99_s: float | None
    latency_p50_s: float | None
    latency_p95_s: float | None
    error_samples: list[str] = field(default_factory=list)


def pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


async def one_request(client: httpx.AsyncClient, args: argparse.Namespace) -> Result:
    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": random.choice(PROMPTS)}],
        "max_tokens": args.max_tokens,
        "temperature": 0.7,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    start = time.perf_counter()
    ttft = None
    tokens = 0
    try:
        async with client.stream("POST", "/v1/chat/completions", json=body) as resp:
            if resp.status_code != 200:
                text = (await resp.aread()).decode(errors="replace")[:200]
                return Result(ok=False, status=resp.status_code, error=text)
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    break
                chunk = json.loads(payload)
                if chunk.get("usage"):
                    tokens = chunk["usage"].get("completion_tokens", tokens)
                choices = chunk.get("choices") or []
                if choices and choices[0].get("delta", {}).get("content") and ttft is None:
                    ttft = time.perf_counter() - start
        return Result(
            ok=True,
            status=200,
            ttft_s=ttft,
            latency_s=time.perf_counter() - start,
            output_tokens=tokens,
        )
    except (httpx.HTTPError, json.JSONDecodeError) as exc:
        return Result(ok=False, status=0, error=f"{type(exc).__name__}: {exc}"[:200])


async def run_phase(
    args: argparse.Namespace,
    concurrency: int,
    duration: float | None,
    total: int | None,
) -> Summary:
    results: list[Result] = []
    deadline = time.perf_counter() + duration if duration else None
    issued = 0
    lock = asyncio.Lock()

    async def worker(client: httpx.AsyncClient) -> None:
        nonlocal issued
        while True:
            async with lock:
                if total is not None and issued >= total:
                    return
                if deadline is not None and time.perf_counter() >= deadline:
                    return
                issued += 1
            results.append(await one_request(client, args))

    limits = httpx.Limits(max_connections=concurrency, max_keepalive_connections=concurrency)
    timeout = httpx.Timeout(args.timeout, connect=10)
    headers = {"Authorization": f"Bearer {args.api_key}"} if args.api_key else {}
    started = time.perf_counter()
    async with httpx.AsyncClient(
        base_url=args.url, limits=limits, timeout=timeout, headers=headers
    ) as client:
        await asyncio.gather(*(worker(client) for _ in range(concurrency)))
    elapsed = time.perf_counter() - started

    ok = [r for r in results if r.ok]
    ttfts = [r.ttft_s for r in ok if r.ttft_s is not None]
    lats = [r.latency_s for r in ok if r.latency_s is not None]
    errors = [r for r in results if not r.ok]
    return Summary(
        target=args.url,
        concurrency=concurrency,
        duration_s=round(elapsed, 2),
        requests=len(results),
        successes=len(ok),
        errors=len(errors),
        error_rate=round(len(errors) / len(results), 4) if results else 0.0,
        rps=round(len(results) / elapsed, 2) if elapsed else 0.0,
        output_tokens_per_s=round(sum(r.output_tokens for r in ok) / elapsed, 1) if elapsed else 0.0,
        ttft_p50_s=_r(pct(ttfts, 0.50)),
        ttft_p95_s=_r(pct(ttfts, 0.95)),
        ttft_p99_s=_r(pct(ttfts, 0.99)),
        latency_p50_s=_r(pct(lats, 0.50)),
        latency_p95_s=_r(pct(lats, 0.95)),
        error_samples=list({e.error or str(e.status) for e in errors})[:5],
    )


def _r(v: float | None) -> float | None:
    return round(v, 3) if v is not None else None


def print_summary(s: Summary) -> None:
    print(f"\n=== concurrency {s.concurrency} | {s.requests} requests in {s.duration_s}s ===")
    print(f"  success      {s.successes}  errors {s.errors} ({s.error_rate:.2%})")
    print(f"  throughput   {s.rps} req/s, {s.output_tokens_per_s} output tok/s")
    print(f"  TTFT         p50 {s.ttft_p50_s}s  p95 {s.ttft_p95_s}s  p99 {s.ttft_p99_s}s")
    print(f"  latency      p50 {s.latency_p50_s}s  p95 {s.latency_p95_s}s")
    for e in s.error_samples:
        print(f"  error sample {e}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://localhost:8000")
    p.add_argument("--model", default="llama-3-8b", help="served model name")
    p.add_argument("--api-key", default="")
    p.add_argument("--concurrency", type=int, default=50)
    p.add_argument(
        "--duration",
        type=float,
        default=None,
        help="seconds to run (default: use --requests)",
    )
    p.add_argument(
        "--requests",
        type=int,
        default=None,
        help="total requests (default 500 if no --duration)",
    )
    p.add_argument("--ramp", default="", help="comma list of concurrency steps, e.g. 5,10,25,50")
    p.add_argument("--step-seconds", type=float, default=120)
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--timeout", type=float, default=300)
    p.add_argument(
        "--max-error-rate",
        type=float,
        default=None,
        help="exit 1 if exceeded (CI smoke gate)",
    )
    p.add_argument("--out", default="", help="write JSON summary here")
    a = p.parse_args(argv)
    if a.duration is None and a.requests is None and not a.ramp:
        a.requests = 500
    return a


def write_json(path: str, data: object) -> None:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


async def main_async(args: argparse.Namespace) -> int:
    summaries: list[Summary] = []
    if args.ramp:
        for c in (int(x) for x in args.ramp.split(",") if x.strip()):
            s = await run_phase(args, c, args.step_seconds, None)
            print_summary(s)
            summaries.append(s)
    else:
        s = await run_phase(args, args.concurrency, args.duration, args.requests)
        print_summary(s)
        summaries.append(s)

    if args.out:
        await asyncio.to_thread(write_json, args.out, [asdict(s) for s in summaries])
        print(f"\nwrote {args.out}")

    if args.max_error_rate is not None:
        worst = max(s.error_rate for s in summaries)
        if worst > args.max_error_rate:
            print(
                f"FAIL: error rate {worst:.2%} > {args.max_error_rate:.2%}",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main_async(parse_args(sys.argv[1:]))))
