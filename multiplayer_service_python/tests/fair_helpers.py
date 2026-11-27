"""Helpers for Protocol v10 binary test packets."""
from __future__ import annotations

from multiplayer_service_python.settings import Settings
from multiplayer_service_python.wire import encode_packet, parse_binary_message


def make_sync_init(tick: int = 0, checksum32: int = 0x12345678, speed: float = 2.0) -> dict:
    return {
        "type": "sync_init",
        "tick": tick,
        "epoch_usec": 1_000_000,
        "speed": speed,
        "input_delay_ticks": 6,
        "delay_from_tick": 0,
        "checksum32": checksum32,
    }


def make_schedule(sched_id: int = 1, tick: int = 6, commands: list | None = None, **extra) -> dict:
    if commands is None:
        commands = [{"team": 0, "seq": 1, "command": {"op": "stop", "unit_id": 1}}]
    return {
        "type": "schedule",
        "id": sched_id,
        "tick": tick,
        "epoch_usec": tick * 100_000,
        "commands": commands,
        **extra,
    }


async def send_bin(mm, player, message: dict) -> bytes:
    raw = encode_packet(message)
    parsed = parse_binary_message(raw, Settings())
    await mm.handle_binary(player, parsed, raw)
    return raw
