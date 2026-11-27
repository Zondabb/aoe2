"""Test-only relay byte accounting at the ASGI WebSocket boundary.

Records message metadata and payload lengths for both JSON text and binary frames,
never game-state contents. Reports both raw WebSocket payload rates and estimated
TCP/IP + WebSocket wire rates.
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

from multiplayer_service_python.protocol import ProtocolError
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.wire import parse_binary_message


class TrafficRecorder:
    def __init__(self, app, path: Path):
        self.app = app
        self.output = path.open("w", encoding="utf-8", buffering=1)
        self.connection = 0
        self.completed_tick = 0
        self.settings = Settings.from_env()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "websocket":
            return await self.app(scope, receive, send)
        self.connection += 1
        connection = self.connection
        role = "loading"

        def record(packet, direction):
            nonlocal role
            raw_text = packet.get("text")
            raw_bytes = packet.get("bytes")
            is_binary = raw_bytes is not None
            if raw_text is not None:
                try:
                    message = json.loads(raw_text)
                except (ValueError, TypeError):
                    return
                if not isinstance(message, dict):
                    return
                payload_bytes = len(raw_text.encode("utf-8"))
            elif raw_bytes is not None:
                try:
                    message = parse_binary_message(bytes(raw_bytes), self.settings)
                except ProtocolError:
                    return
                payload_bytes = len(raw_bytes)
            else:
                return

            kind = message.get("type", "unknown")
            if direction == "out" and kind == "match_found":
                role = "host" if message["team"] == message["host_team"] else "guest"
            tick = message.get("tick", message.get("ack_tick"))
            if direction == "in" and kind in ("heartbeat", "sync_init") and tick is not None:
                self.completed_tick = max(self.completed_tick, int(tick))
            cmds = message.get("commands", [])
            wire_bytes = payload_bytes + (58 if direction == "in" else 54)
            self.output.write(json.dumps({
                "time": time.monotonic(),
                "connection": connection,
                "role": role,
                "direction": direction,
                "encoding": "binary" if is_binary else "json",
                "type": kind,
                "bytes": payload_bytes,
                "wire_bytes": wire_bytes,
                "tick": tick,
                "completed_tick": self.completed_tick,
                "commands": len(cmds),
                "game_commands": sum(1 for entry in cmds if entry.get("command", entry).get("op") != "match_end"),
                "has_timing": "timing" in message,
                "codec": message.get("codec"),
                "raw_size": message.get("raw_size"),
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
    heartbeats = {r["tick"]: r["time"] for r in rows
                  if r["direction"] == "in" and r["type"] == "heartbeat" and r["tick"] is not None}
    last_kf_time = max((r["time"] for r in rows if r["type"] == "keyframe"), default=0.0)
    steady_ticks = sorted(t for t, ts in heartbeats.items() if t >= 300 and ts > last_kf_time)
    if len(steady_ticks) < 2:
        steady_ticks = sorted(t for t, ts in heartbeats.items() if t >= 270 and ts > last_kf_time)
    assert len(steady_ticks) >= 2, f"insufficient post-keyframe heartbeat markers: {sorted(heartbeats)}"
    start_tick, end_tick = steady_ticks[0], steady_ticks[-1]
    assert end_tick - start_tick >= 60, f"steady window too short: {[start_tick, end_tick]}"
    start, end = heartbeats[start_tick], heartbeats[end_tick]
    seconds = end - start
    assert seconds > 0
    assert not any(r["type"] == "keyframe" and start <= r["time"] < end for r in rows), (
        "keyframe inside measurement window; select a stable interval")
    counts, sizes, wire_sizes = Counter(), Counter(), Counter()
    for r in rows:
        if start <= r["time"] < end:
            assert r["role"] in ("host", "guest"), f"unclassified active connection: {r}"
            key = (r["role"], r["direction"], r["type"])
            counts[key] += 1
            sizes[key] += r["bytes"]
            wire_sizes[key] += r.get("wire_bytes", r["bytes"] + (58 if r["direction"] == "in" else 54))
    table = [{
        "role": k[0], "direction": k[1], "type": k[2],
        "messages": n, "bytes": sizes[k], "wire_bytes": wire_sizes[k],
        "messages_per_second": n / seconds,
        "bytes_per_second": sizes[k] / seconds,
        "kbps": sizes[k] * 8.0 / seconds / 1000.0,
        "wire_kbps": wire_sizes[k] * 8.0 / seconds / 1000.0,
    } for k, n in sorted(counts.items())]
    totals = []
    for role in ("host", "guest"):
        for direction in ("in", "out"):
            group = [r for r in table if r["role"] == role and r["direction"] == direction]
            bps = sum(r["bytes_per_second"] for r in group)
            wbps = sum(r["wire_kbps"] for r in group)
            totals.append({
                "role": role,
                "direction": direction,
                "bytes_per_second": bps,
                "payload_kbps": bps * 8.0 / 1000.0,
                "tcp_ip_kbps": wbps,
                "messages_per_second": sum(r["messages_per_second"] for r in group),
            })
    out_totals = [t for t in totals if t["direction"] == "out"]
    in_msgs_per_sec = sum(t["messages_per_second"] for t in totals if t["direction"] == "in")
    relay_out_payload_kbps = sum(t["payload_kbps"] for t in out_totals)
    relay_out_tcp_ip_kbps = sum(t["tcp_ip_kbps"] for t in out_totals)
    estimated_nic_outbound_kbps = relay_out_tcp_ip_kbps + in_msgs_per_sec * 52.0 * 8.0 / 1000.0
    return {
        "scope": "relay payload (JSON + binary) and estimated TCP/IP+WS framing",
        "steady_seconds": seconds,
        "steady_tick_range": [start_tick, end_tick],
        "steady": table,
        "steady_totals": totals,
        "relay_outbound_payload_kbps": relay_out_payload_kbps,
        "relay_outbound_tcp_ip_kbps": relay_out_tcp_ip_kbps,
        "estimated_nic_outbound_kbps": estimated_nic_outbound_kbps,
        "steady_timing_updates": sum(r.get("has_timing", False) for r in rows
                                     if r["direction"] == "in" and r["type"] == "schedule"
                                     and start <= r["time"] < end),
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
