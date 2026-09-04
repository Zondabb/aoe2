#!/usr/bin/env python3
"""P6-9 load test: dual-team tick_batch for ~5 minutes without timeouts."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import httpx

FIXTURE = Path(__file__).resolve().parents[1] / "tests" / "fixtures" / "opening_eco.json"


def main() -> int:
    parser = argparse.ArgumentParser(description="AI service tick_batch load test")
    parser.add_argument("--base-url", default="http://127.0.0.1:8765")
    parser.add_argument("--duration-sec", type=float, default=300.0)
    parser.add_argument("--interval-sec", type=float, default=0.5)
    parser.add_argument("--token", default="")
    args = parser.parse_args()

    payload = json.loads(FIXTURE.read_text(encoding="utf-8"))
    req = payload["request"]
    headers = {"Content-Type": "application/json"}
    if args.token:
        headers["Authorization"] = f"Bearer {args.token}"

    client = httpx.Client(base_url=args.base_url, timeout=5.0, headers=headers)
    health = client.get("/health")
    if health.status_code != 200:
        print(f"health check failed: {health.status_code}", file=sys.stderr)
        return 1

    match_id = f"load_{int(time.time())}"
    client.post(
        "/v1/ai/match/start",
        json={"protocol_version": 1, "match_id": match_id, "teams": []},
    )

    tick = 0
    latencies: list[float] = []
    timeouts = 0
    started = time.perf_counter()
    while time.perf_counter() - started < args.duration_sec:
        tick += 1
        batch = {
            "protocol_version": 1,
            "match_id": match_id,
            "requests": [
                {
                    "team": req["team"],
                    "tick": tick,
                    "time_sec": tick * args.interval_sec,
                    "profile_id": req["profile_id"],
                    "enemy_team": req["enemy_team"],
                    "events": [],
                    "observation": req["observation"],
                },
                {
                    "team": req["enemy_team"],
                    "tick": tick,
                    "time_sec": tick * args.interval_sec,
                    "profile_id": "chinese",
                    "enemy_team": req["team"],
                    "events": [],
                    "observation": req["observation"],
                },
            ],
        }
        t0 = time.perf_counter()
        try:
            response = client.post("/v1/ai/tick_batch", json=batch)
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            latencies.append(elapsed_ms)
            if response.status_code != 200:
                print(f"tick {tick} failed: HTTP {response.status_code}", file=sys.stderr)
                return 1
            if len(response.json().get("responses", [])) != 2:
                print(f"tick {tick} invalid batch response", file=sys.stderr)
                return 1
        except httpx.TimeoutException:
            timeouts += 1
            print(f"tick {tick} timeout", file=sys.stderr)
            return 1
        time.sleep(max(0.0, args.interval_sec - (time.perf_counter() - t0)))

    client.post("/v1/ai/match/end", json={"protocol_version": 1, "match_id": match_id})
    avg_ms = sum(latencies) / len(latencies) if latencies else 0.0
    print(
        json.dumps(
            {
                "ticks": tick,
                "timeouts": timeouts,
                "avg_batch_latency_ms": round(avg_ms, 2),
                "max_batch_latency_ms": round(max(latencies), 2) if latencies else 0.0,
            }
        )
    )
    return 0 if timeouts == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
