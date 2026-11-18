"""Test-only relay byte accounting at the ASGI WebSocket boundary.

Records message metadata and UTF-8 payload lengths, never game-state contents.
Counts exclude WebSocket/TCP/TLS headers, compression and retransmissions.
Run via test_online_fair_e2e.py --traffic-report; report JSON is reproducible
with: python tools/trace_multiplayer_traffic.py report <traffic.jsonl>.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import time


class TrafficRecorder:
    def __init__(self, app, path: Path):
        self.app = app
        self.output = path.open("w", encoding="utf-8", buffering=1)
        self.connection = 0
        self.completed_tick = 0

    async def __call__(self, scope, receive, send):
        if scope["type"] != "websocket":
            return await self.app(scope, receive, send)
        self.connection += 1
        connection = self.connection
        role = "loading"

        def record(packet, direction):
            nonlocal role
            raw = packet.get("text")
            if raw is None:
                return
            try:
                message = json.loads(raw)
            except (ValueError, TypeError):
                return
            if not isinstance(message, dict):
                return
            kind = message.get("type", "unknown")
            if direction == "out" and kind == "match_found":
                role = "host" if message["team"] == message["host_team"] else "guest"
            elif direction == "out" and kind == "spectate_started":
                role = "spectator"
            if direction == "in" and kind == "frame":
                self.completed_tick = message["tick"]
            self.output.write(json.dumps({
                "time": time.monotonic(), "connection": connection, "role": role,
                "direction": direction, "type": kind, "bytes": len(raw.encode("utf-8")),
                "tick": message.get("tick"), "completed_tick": self.completed_tick,
                "commands": len(message.get("commands", [])),
                "game_commands": sum(1 for entry in message.get("commands", [])
                                     if entry.get("command", entry).get("op") not in ("ai_control_state", "match_speed")),
                "has_timing": "timing" in message,
                "codec": message.get("codec"), "raw_size": message.get("raw_size"),
            }, separators=(",", ":")) + "\n")

        async def tracked_receive():
            packet = await receive()
            record(packet, "in")
            return packet

        async def tracked_send(packet):
            await send(packet)
            record(packet, "out")

        await self.app(scope, tracked_receive, tracked_send)


def summarize(path: Path) -> dict:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    # Match the E2E's stable window. A keyframe in this window must not be
    # silently included in ordinary traffic (large maps may recover later).
    frames = {r["tick"]: r["time"] for r in rows
              if r["direction"] == "in" and r["type"] == "frame"}
    start, end = frames[300], frames[435]
    seconds = end - start
    assert not any(r["type"] == "keyframe" and start <= r["time"] < end for r in rows), (
        "keyframe inside measurement window; select a stable interval")
    counts, sizes = Counter(), Counter()
    for r in rows:
        if start <= r["time"] < end:
            assert r["role"] in ("host", "guest", "spectator"), "unclassified active connection"
            key = (r["role"], r["direction"], r["type"])
            counts[key] += 1
            sizes[key] += r["bytes"]
    table = [{"role": k[0], "direction": k[1], "type": k[2],
              "messages": n, "bytes": sizes[k], "messages_per_second": n / seconds,
              "bytes_per_second": sizes[k] / seconds} for k, n in sorted(counts.items())]
    totals = []
    for role in ("host", "guest", "spectator"):
        for direction in ("in", "out"):
            group = [r for r in table if r["role"] == role and r["direction"] == direction]
            totals.append({"role": role, "direction": direction,
                           "bytes_per_second": sum(r["bytes_per_second"] for r in group),
                           "messages_per_second": sum(r["messages_per_second"] for r in group)})
    # Duplicate plans/commits are expected around keyframe recovery only.
    duplicates = {}
    for kind in ("input_frame", "input_commit", "input_step"):
        keys = Counter((r["connection"], r["tick"]) for r in rows
                       if r["direction"] == "in" and r["type"] == kind
                       and start <= r["time"] < end)
        duplicates[kind] = sum(n - 1 for n in keys.values())
    return {
        "scope": "relay UTF-8 JSON payload, excluding transport headers/compression/retransmissions",
        "steady_seconds": seconds, "steady_tick_range": [300, 435],
        "steady": table, "steady_totals": totals, "steady_duplicate_preparations": duplicates,
        "steady_timing_updates": sum(r.get("has_timing", False) for r in rows
                                     if r["direction"] == "in" and r["type"] == "input_step"
                                     and start <= r["time"] < end),
        "guest_repeated_game_commands": sum(r.get("game_commands", 0) for r in rows
                                            if r["direction"] == "out" and r["role"] == "guest" and r["type"] == "frame"),
        "batches": [r for r in rows if r["direction"] == "in" and r["type"] == "command_batch"],
        "keyframes": [r for r in rows if r["type"] == "keyframe"],
        "keyframe_requests": [r for r in rows if r["direction"] == "in" and r["type"] == "request_keyframe"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("serve", "report"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--host-team", type=int, choices=(0, 1))
    args = parser.parse_args()
    if args.mode == "report":
        print(json.dumps(summarize(args.path), indent=2))
        return
    if args.host_team is not None:
        from unittest.mock import patch
        import secrets
        original = secrets.randbelow
        patch("multiplayer_service_python.matchmaking.secrets.randbelow",
              side_effect=lambda n: args.host_team if n == 2 else original(n)).start()
    import uvicorn
    from multiplayer_service_python.main import app
    from multiplayer_service_python.settings import Settings
    uvicorn.run(TrafficRecorder(app, args.path), host=os.getenv("AOE2_MP_HOST", "127.0.0.1"),
                port=int(os.getenv("AOE2_MP_PORT", "8001")),
                ws_max_size=Settings.from_env().max_message_bytes, ws_max_queue=8)


if __name__ == "__main__":
    main()
