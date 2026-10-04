#!/usr/bin/env python3
"""Tiny OpenAI-compatible streaming mock so the load test can run without a GPU.

    python mock_server.py --port 8000 &
    python loadtest.py --concurrency 20 --requests 100

Simulates queueing: each request waits for one of --slots, like vLLM's batch.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random


async def handle(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter, slots: asyncio.Semaphore
) -> None:
    try:
        request_line = await reader.readline()
        headers = {}
        while (line := await reader.readline()) not in (b"\r\n", b""):
            k, _, v = line.decode().partition(":")
            headers[k.strip().lower()] = v.strip()
        body = await reader.readexactly(int(headers.get("content-length", 0)))
        if b"/health" in request_line:
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            return
        req = json.loads(body or b"{}")
        n = min(int(req.get("max_tokens", 64)), 64)

        writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
        async with slots:
            await asyncio.sleep(random.uniform(0.05, 0.2))  # prefill
            for i in range(n):
                chunk = {"choices": [{"index": 0, "delta": {"content": f"tok{i} "}}]}
                writer.write(f"data: {json.dumps(chunk)}\n\n".encode())
                await writer.drain()
                await asyncio.sleep(0.01)
        usage = {"choices": [], "usage": {"completion_tokens": n}}
        writer.write(f"data: {json.dumps(usage)}\n\ndata: [DONE]\n\n".encode())
        await writer.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        writer.close()


async def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--slots", type=int, default=16)
    a = p.parse_args()
    slots = asyncio.Semaphore(a.slots)
    server = await asyncio.start_server(lambda r, w: handle(r, w, slots), "127.0.0.1", a.port)
    print(f"mock vLLM on :{a.port} with {a.slots} slots")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
