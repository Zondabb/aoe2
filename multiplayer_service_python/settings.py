from __future__ import annotations

from dataclasses import dataclass, fields
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    leaderboard_db: str = str(Path(__file__).resolve().parent / "data" / "leaderboard.sqlite3")
    max_connections: int = 128
    max_queue: int = 128
    max_message_bytes: int = 524_288
    max_command_bytes: int = 16_384
    outgoing_queue_size: int = 8
    messages_per_second: float = 90.0
    message_burst: float = 180.0
    bytes_per_second: float = 4_194_304.0
    byte_burst: float = 8_388_608.0
    idle_timeout: float = 30.0
    queue_timeout: float = 120.0
    ready_timeout: float = 30.0
    match_timeout: float = 10_800.0
    send_timeout: float = 5.0
    sweep_interval: float = 1.0

    def __post_init__(self) -> None:
        import math

        for field in fields(self):
            value = getattr(self, field.name)
            if field.name == "leaderboard_db":
                if not isinstance(value, str) or not value.strip():
                    raise ValueError("leaderboard_db must be a nonempty path")
                continue
            if not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{field.name} must be a positive finite number")

    @classmethod
    def from_env(cls) -> "Settings":
        defaults = cls()
        values = {}
        for field in fields(defaults):
            value = os.getenv(f"AOE2_MP_{field.name.upper()}")
            if value is not None:
                values[field.name] = type(getattr(defaults, field.name))(value)
        return cls(**values)
