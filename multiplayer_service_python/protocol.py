from __future__ import annotations

import json
import math
import re
import unicodedata
from typing import Any

from .settings import Settings


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, close_code: int | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.close_code = close_code


FIELDS = {
    "join_queue": {"type", "protocol_version", "name", "civ"},
    "cancel_queue": {"type"},
    "ready": {"type"},
    "command": {"type", "seq", "source_tick", "execute_tick", "command"},
    "input_frame": {"type", "tick", "commands"},
    "input_ack": {"type", "tick"},
    "input_commit": {"type", "tick", "execute_at_usec", "speed", "input_delay_ticks", "delay_from_tick"},
    "clock_probe": {"type", "nonce", "sent_usec"},
    "clock_reply": {"type", "nonce", "sent_usec", "received_usec"},
    "frame": {"type", "tick", "commands", "checksum", "results"},
    "ack": {"type", "tick", "checksum"},
    "request_keyframe": {"type"},
    "keyframe": {"type", "request_id", "tick", "state", "checksum"},
    "finish_match": {"type", "winner"},
    "leave": {"type"},
    "ping": {"type"},
    "list_matches": {"type"},
    "watch_match": {"type", "match_id"},
    "watch_ready": {"type"},
}

PROTOCOL_VERSION = 6
TICK_RATE = 30
FRAME_TICKS = 3
MAX_SAFE_INTEGER = 9_007_199_254_740_991
MAX_FRAME_COMMANDS = 64
MAX_FRAME_BYTES = 262_144
MAX_INPUT_COMMANDS = 62
MAX_INPUT_LEAD_TICKS = 180
MAX_FRAME_RESULTS = 256


def _safe_integer(value: Any, minimum: int = 0) -> bool:
    return type(value) is int and minimum <= value <= MAX_SAFE_INTEGER


def _tick(value: Any) -> bool:
    return _safe_integer(value) and value % FRAME_TICKS == 0


def _team(value: Any) -> bool:
    return type(value) is int and value in (0, 1)


def _identifier(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value) is not None


def _command(command: Any, settings: Settings) -> None:
    if not isinstance(command, dict) or not isinstance(command.get("op"), str) or not command["op"]:
        raise ProtocolError("invalid_payload", "command must contain a string op")
    if any(key in command for key in ("team", "player_id", "match_id", "host_team")):
        raise ProtocolError("invalid_payload", "Command identity is assigned by the service")
    if command.get("op") == "ai_instruction":
        text = command.get("text")
        if set(command) != {"op", "text"} or not isinstance(text, str) or not text.strip() or len(text) > 240:
            raise ProtocolError("invalid_payload", "AI instruction requires 1 to 240 characters of text")
    if command.get("op") == "set_ai_control":
        if set(command) != {"op", "enabled"} or type(command["enabled"]) is not bool:
            raise ProtocolError("invalid_payload", "AI control requires only op and a boolean enabled field")
    if len(json.dumps(command, ensure_ascii=True).encode()) > settings.max_command_bytes:
        raise ProtocolError("invalid_payload", "Command exceeds the size limit")


def _object(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _constant(value: str) -> None:
    raise ValueError(f"Non-finite JSON number: {value}")


def _check_tree(root: Any) -> None:
    """Bound work and nesting before forwarding opaque game data."""
    pending = [(root, 0)]
    count = 0
    while pending:
        value, depth = pending.pop()
        count += 1
        if depth > 32 or count > 500_000:
            raise ProtocolError("invalid_payload", "JSON structure is too complex")
        if isinstance(value, float) and not math.isfinite(value):
            raise ProtocolError("invalid_payload", "All numbers must be finite")
        if isinstance(value, dict):
            pending.extend((child, depth + 1) for child in value.values())
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)


def parse_message(raw: str, settings: Settings) -> dict:
    if len(raw.encode("utf-8")) > settings.max_message_bytes:
        raise ProtocolError("message_too_large", "Message exceeds the size limit", 1009)
    try:
        data = json.loads(raw, object_pairs_hook=_object, parse_constant=_constant)
    except (ValueError, RecursionError):
        raise ProtocolError("invalid_json", "Expected a valid JSON object") from None
    if not isinstance(data, dict) or not isinstance(data.get("type"), str):
        raise ProtocolError("invalid_payload", "A string type field is required")
    kind = data["type"]
    if kind not in FIELDS:
        raise ProtocolError("unknown_type", "Unknown message type")
    if set(data) != FIELDS[kind]:
        raise ProtocolError("invalid_payload", "Missing or unexpected message fields")
    _check_tree(data)
    if kind == "join_queue":
        if type(data["protocol_version"]) is not int or data["protocol_version"] != PROTOCOL_VERSION:
            raise ProtocolError("protocol_mismatch", "Only protocol_version 6 (adaptive fair scheduled lockstep) is supported; update the game client")
        name = data["name"]
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 24:
            raise ProtocolError("invalid_name", "Player name must contain 1 to 24 characters")
        if any(unicodedata.category(char).startswith("C") for char in name):
            raise ProtocolError("invalid_name", "Player name contains control characters")
        data["name"] = name.strip()
        if data["civ"] not in ("chinese", "teutons"):
            raise ProtocolError("invalid_civ", "Supported civilizations: chinese, teutons")
    elif kind == "watch_match":
        match_id = data["match_id"]
        if not _identifier(match_id):
            raise ProtocolError("invalid_payload", "match_id must be a valid match identifier")
    elif kind == "command":
        if not _safe_integer(data["seq"], 1):
            raise ProtocolError("invalid_sequence", "seq must be a positive safe integer")
        source, execute = data["source_tick"], data["execute_tick"]
        if not _tick(source) or not _tick(execute) or not source < execute <= source + MAX_INPUT_LEAD_TICKS:
            raise ProtocolError("invalid_sequence", "Input ticks must be frame boundaries with a bounded future execution tick")
        _command(data["command"], settings)
    elif kind in ("input_frame", "input_ack", "input_commit"):
        if not _tick(data["tick"]) or data["tick"] == 0:
            raise ProtocolError("invalid_sequence", "Input tick must be a positive frame boundary")
        if kind == "input_frame":
            commands = data["commands"]
            if not isinstance(commands, list) or len(commands) > MAX_INPUT_COMMANDS:
                raise ProtocolError("invalid_payload", "An input frame may contain at most 62 commands")
            seen = set()
            for entry in commands:
                if (not isinstance(entry, dict) or set(entry) not in ({"team", "seq", "command"}, {"team", "seq", "command", "ai"})
                        or not _team(entry["team"]) or not _safe_integer(entry["seq"])):
                    raise ProtocolError("invalid_payload", "Each input requires a team, sequence and command")
                identity = (entry["team"], entry["seq"])
                if entry["seq"] > 0:
                    if identity in seen:
                        raise ProtocolError("invalid_payload", "Input sequences may not repeat within a frame")
                    seen.add(identity)
                _command(entry["command"], settings)
                if entry["command"]["op"] == "ai_instruction":
                    raise ProtocolError("invalid_payload", "Player instructions are private to the host")
                if "ai" in entry and (entry["seq"] != 0 or not isinstance(entry["ai"], dict)
                                      or len(json.dumps(entry["ai"], ensure_ascii=True).encode()) > 4096):
                    raise ProtocolError("invalid_payload", "AI metadata requires an internal input and a small object")
            if len(raw.encode("utf-8")) > MAX_FRAME_BYTES:
                raise ProtocolError("invalid_payload", "Input frame exceeds the size limit")
        elif kind == "input_commit":
            if not _safe_integer(data["execute_at_usec"], 1):
                raise ProtocolError("invalid_sequence", "Execution time must be a positive safe integer")
            speed, delay = data["speed"], data["input_delay_ticks"]
            if type(speed) not in (int, float) or not 0.25 <= speed <= 4.0:
                raise ProtocolError("invalid_payload", "Match speed must be between 0.25 and 4")
            if not _tick(delay) or not FRAME_TICKS <= delay <= MAX_INPUT_LEAD_TICKS:
                raise ProtocolError("invalid_payload", "Input delay must be a bounded positive frame interval")
            if not _tick(data["delay_from_tick"]):
                raise ProtocolError("invalid_payload", "Input delay activation must be a nonnegative safe frame boundary")
    elif kind in ("clock_probe", "clock_reply"):
        if not _safe_integer(data["nonce"], 1) or not _safe_integer(data["sent_usec"]):
            raise ProtocolError("invalid_payload", "Clock probes require safe integer nonce and timestamp")
        if kind == "clock_reply" and not _safe_integer(data["received_usec"]):
            raise ProtocolError("invalid_payload", "Clock replies require a safe integer receive timestamp")
    elif kind in ("frame", "ack", "keyframe"):
        tick = data["tick"]
        if not _tick(tick):
            raise ProtocolError("invalid_sequence", "tick must be a nonnegative safe integer at a frame boundary")
        if not isinstance(data["checksum"], str) or re.fullmatch(r"[0-9a-f]{64}", data["checksum"]) is None:
            raise ProtocolError("invalid_payload", "checksum must be a SHA-256 hex string")
        if kind == "frame":
            results = data["results"]
            if not isinstance(results, list) or len(results) > MAX_FRAME_RESULTS:
                raise ProtocolError("invalid_payload", "A frame may contain at most 256 input results")
            seen = set()
            for result in results:
                if (not isinstance(result, dict) or set(result) != {"team", "seq", "accepted"}
                        or not _team(result["team"]) or not _safe_integer(result["seq"], 1)
                        or type(result["accepted"]) is not bool):
                    raise ProtocolError("invalid_payload", "Each result requires a team, positive sequence and boolean acceptance")
                identity = (result["team"], result["seq"])
                if identity in seen:
                    raise ProtocolError("invalid_payload", "Input results may not repeat within a frame")
                seen.add(identity)
            commands = data["commands"]
            if not isinstance(commands, list) or len(commands) > MAX_FRAME_COMMANDS:
                raise ProtocolError("invalid_payload", "A frame may contain at most 64 commands")
            for entry in commands:
                if not isinstance(entry, dict) or set(entry) != {"team", "command"} or type(entry["team"]) is not int or entry["team"] not in (0, 1):
                    raise ProtocolError("invalid_payload", "Each frame command requires a team and command")
                _command(entry["command"], settings)
                if entry["command"]["op"] == "ai_instruction":
                    raise ProtocolError("invalid_payload", "Player instructions are private to the host")
            if len(raw.encode("utf-8")) > MAX_FRAME_BYTES:
                raise ProtocolError("invalid_payload", "Frame exceeds the size limit")
        elif kind == "keyframe":
            if not _identifier(data["request_id"]):
                raise ProtocolError("invalid_payload", "request_id must be a valid request identifier")
            if not isinstance(data["state"], dict) or not data["state"]:
                raise ProtocolError("invalid_payload", "state must be a nonempty object")
    elif kind == "finish_match":
        if type(data["winner"]) is not int or data["winner"] not in (0, 1):
            raise ProtocolError("invalid_payload", "winner must be team 0 or team 1")
    return data
