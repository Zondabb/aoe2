from __future__ import annotations

import math
import re
import struct
from typing import Any

from .protocol import (
    FRAME_TICKS,
    MAX_FRAME_BYTES,
    MAX_INPUT_COMMANDS,
    MAX_INPUT_LEAD_TICKS,
    MAX_SAFE_INTEGER,
    ProtocolError,
)
from .settings import Settings

PKT_CLOCK_PROBE = 0x01
PKT_CLOCK_REPLY = 0x02
PKT_SYNC_INIT = 0x03
PKT_CMD_SUBMIT = 0x04
PKT_SCHEDULE = 0x05
PKT_SCHEDULE_ACK = 0x06
PKT_HEARTBEAT = 0x07
PKT_HEARTBEAT_ACK = 0x08

OP_TO_ID = {
    "move": 0x01,
    "stop": 0x02,
    "gather": 0x03,
    "build": 0x04,
    "attack": 0x05,
    "train": 0x06,
    "cancel_train": 0x07,
    "place_building": 0x08,
    "research_age": 0x09,
    "cancel_research_age": 0x0A,
    "research_technology": 0x0B,
    "cancel_technology": 0x0C,
    "place_wall": 0x0D,
    "set_gate_state": 0x0E,
    "match_end": 0x0F,
}
ID_TO_OP = {value: key for key, value in OP_TO_ID.items()}

GATE_TO_CODE = {"auto": 0, "open": 1, "locked": 2}
CODE_TO_GATE = {value: key for key, value in GATE_TO_CODE.items()}

_IDENT_RE = re.compile(r"^[a-z0-9_]+$")
_FORBIDDEN_CMD_KEYS = {"team", "player_id", "match_id", "host_team"}
_ALLOWED_CMD_KEYS = {
    "move": {"op", "unit_id", "pos", "formation_speed"},
    "stop": {"op", "unit_id"},
    "gather": {"op", "unit_id", "target_id"},
    "build": {"op", "unit_id", "building_id"},
    "attack": {"op", "unit_id", "target_id"},
    "train": {"op", "building_id", "unit_def_id"},
    "cancel_train": {"op", "building_id", "queue_id"},
    "place_building": {"op", "builder_id", "building_def_id", "pos", "orientation"},
    "research_age": {"op", "building_id"},
    "cancel_research_age": {"op", "building_id"},
    "research_technology": {"op", "building_id", "technology_id"},
    "cancel_technology": {"op", "building_id", "technology_id"},
    "place_wall": {"op", "builder_id", "building_def_id", "start", "end", "include_gate", "append_queue"},
    "set_gate_state": {"op", "building_id", "gate_state"},
    "match_end": {"op", "winner"},
}


def _safe_int(value: Any, minimum: int = 0, maximum: int = MAX_SAFE_INTEGER) -> int:
    if type(value) is not int or value < minimum or value > maximum:
        raise ProtocolError("invalid_sequence", f"Integer must be between {minimum} and {maximum}")
    return value


def _tick(value: Any, allow_zero: bool = True) -> int:
    minimum = 0 if allow_zero else FRAME_TICKS
    tick = _safe_int(value, minimum=minimum, maximum=0xFFFFFFFF)
    if tick % FRAME_TICKS != 0:
        raise ProtocolError("invalid_sequence", "Tick must be aligned to frame boundary")
    return tick


def _team(value: Any) -> int:
    if type(value) is not int or value not in (0, 1):
        raise ProtocolError("invalid_payload", "Team must be 0 or 1")
    return value


def _finite_float(value: Any) -> float:
    if type(value) not in (int, float) or not math.isfinite(float(value)):
        raise ProtocolError("invalid_payload", "Number must be finite")
    return float(value)


def _pos(value: Any) -> tuple[float, float]:
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        raise ProtocolError("invalid_payload", "Position must be a 2-element coordinate")
    return _finite_float(value[0]), _finite_float(value[1])


def _str8(value: Any) -> bytes:
    if not isinstance(value, str) or not (1 <= len(value) <= 128) or _IDENT_RE.fullmatch(value) is None:
        raise ProtocolError("invalid_payload", "Identifier must be 1..128 lowercase ASCII identifier chars")
    raw = value.encode("ascii")
    return bytes([len(raw)]) + raw


def _encode_varint(value: int) -> bytes:
    value = _safe_int(value)
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _encode_f32(value: Any) -> bytes:
    packed = struct.pack("<f", _finite_float(value))
    unpacked = struct.unpack("<f", packed)[0]
    if not math.isfinite(unpacked):
        raise ProtocolError("invalid_payload", "Float overflows 32-bit wire range")
    return packed


class _Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def remaining(self) -> int:
        return len(self.data) - self.pos

    def read_u8(self) -> int:
        if self.pos + 1 > len(self.data):
            raise ProtocolError("invalid_payload", "Truncated binary packet")
        val = self.data[self.pos]
        self.pos += 1
        return val

    def read_u16(self) -> int:
        if self.pos + 2 > len(self.data):
            raise ProtocolError("invalid_payload", "Truncated binary packet")
        val = struct.unpack_from("<H", self.data, self.pos)[0]
        self.pos += 2
        return val

    def read_u32(self) -> int:
        if self.pos + 4 > len(self.data):
            raise ProtocolError("invalid_payload", "Truncated binary packet")
        val = struct.unpack_from("<I", self.data, self.pos)[0]
        self.pos += 4
        return val

    def read_u64(self) -> int:
        if self.pos + 8 > len(self.data):
            raise ProtocolError("invalid_payload", "Truncated binary packet")
        val = struct.unpack_from("<Q", self.data, self.pos)[0]
        self.pos += 8
        if val > MAX_SAFE_INTEGER:
            raise ProtocolError("invalid_sequence", "u64 exceeds MAX_SAFE_INTEGER")
        return val

    def read_f32(self) -> float:
        if self.pos + 4 > len(self.data):
            raise ProtocolError("invalid_payload", "Truncated binary packet")
        val = struct.unpack_from("<f", self.data, self.pos)[0]
        self.pos += 4
        if not math.isfinite(val):
            raise ProtocolError("invalid_payload", "Non-finite wire float")
        return float(val)

    def read_varint(self, minimum: int = 0) -> int:
        value = 0
        shift = 0
        count = 0
        while True:
            byte = self.read_u8()
            count += 1
            if count > 8:
                raise ProtocolError("invalid_sequence", "Varint exceeds 8 bytes")
            if count > 1 and byte == 0:
                raise ProtocolError("invalid_payload", "Non-canonical varint")
            value |= (byte & 0x7F) << shift
            if not (byte & 0x80):
                break
            shift += 7
        if value < minimum or value > MAX_SAFE_INTEGER:
            raise ProtocolError("invalid_sequence", "Varint out of bounds")
        return value

    def read_str8(self) -> str:
        length = self.read_u8()
        if length < 1 or length > 128 or self.pos + length > len(self.data):
            raise ProtocolError("invalid_payload", "Invalid string length")
        raw = self.data[self.pos:self.pos + length]
        self.pos += length
        try:
            text = raw.decode("ascii")
        except UnicodeDecodeError:
            raise ProtocolError("invalid_payload", "Identifier must be ASCII") from None
        if _IDENT_RE.fullmatch(text) is None:
            raise ProtocolError("invalid_payload", "Invalid identifier characters")
        return text


def encode_command(command: dict[str, Any], *, allow_match_end: bool = False) -> bytes:
    if not isinstance(command, dict) or not isinstance(command.get("op"), str):
        raise ProtocolError("invalid_payload", "Command must contain string op")
    if any(key in command for key in _FORBIDDEN_CMD_KEYS):
        raise ProtocolError("invalid_payload", "Command identity is assigned by the service")
    op = command["op"]
    op_id = OP_TO_ID.get(op)
    if op_id is None or not command.keys() <= _ALLOWED_CMD_KEYS[op]:
        raise ProtocolError("invalid_payload", "Unknown gameplay operation or field")
    if op == "match_end" and not allow_match_end:
        raise ProtocolError("invalid_payload", "match_end is not allowed in player command submission")

    out = bytearray()
    if op == "move":
        x, y = _pos(command.get("pos"))
        has_speed = "formation_speed" in command
        flags = 1 if has_speed else 0
        out.append(op_id | (flags << 5))
        out.extend(_encode_varint(_safe_int(command.get("unit_id"), minimum=1)))
        out.extend(_encode_f32(x))
        out.extend(_encode_f32(y))
        if has_speed:
            out.extend(_encode_f32(command["formation_speed"]))
    elif op == "stop":
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("unit_id"), minimum=1)))
    elif op in ("gather", "attack"):
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("unit_id"), minimum=1)))
        out.extend(_encode_varint(_safe_int(command.get("target_id"), minimum=1)))
    elif op == "build":
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("unit_id"), minimum=1)))
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
    elif op == "train":
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
        out.extend(_str8(command.get("unit_def_id")))
    elif op == "cancel_train":
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
        out.extend(_encode_varint(_safe_int(command.get("queue_id"), minimum=1)))
    elif op == "place_building":
        has_orientation = "orientation" in command
        flags = 0
        if has_orientation:
            orientation = _safe_int(command["orientation"], minimum=0, maximum=3)
            flags = 0x04 | orientation
        out.append(op_id | (flags << 5))
        out.extend(_encode_varint(_safe_int(command.get("builder_id"), minimum=1)))
        out.extend(_str8(command.get("building_def_id")))
        x, y = _pos(command.get("pos"))
        out.extend(_encode_f32(x))
        out.extend(_encode_f32(y))
    elif op in ("research_age", "cancel_research_age"):
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
    elif op in ("research_technology", "cancel_technology"):
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
        out.extend(_str8(command.get("technology_id")))
    elif op == "place_wall":
        include_gate = command.get("include_gate", False)
        append_queue = command.get("append_queue", False)
        if type(include_gate) is not bool or type(append_queue) is not bool:
            raise ProtocolError("invalid_payload", "Wall flags must be booleans")
        flags = (1 if include_gate else 0) | (2 if append_queue else 0)
        out.append(op_id | (flags << 5))
        out.extend(_encode_varint(_safe_int(command.get("builder_id"), minimum=1)))
        out.extend(_str8(command.get("building_def_id")))
        sx, sy = _pos(command.get("start"))
        ex, ey = _pos(command.get("end"))
        out.extend(_encode_f32(sx))
        out.extend(_encode_f32(sy))
        out.extend(_encode_f32(ex))
        out.extend(_encode_f32(ey))
    elif op == "set_gate_state":
        gate_code = GATE_TO_CODE.get(command.get("gate_state"))
        if gate_code is None:
            raise ProtocolError("invalid_payload", "Invalid gate_state")
        out.append(op_id)
        out.extend(_encode_varint(_safe_int(command.get("building_id"), minimum=1)))
        out.append(gate_code)
    elif op == "match_end":
        winner = _team(command.get("winner"))
        out.append(op_id)
        out.append(winner)
    return bytes(out)


def _decode_command(reader: _Reader, *, allow_match_end: bool = False) -> dict[str, Any]:
    op_byte = reader.read_u8()
    op_id = op_byte & 0x1F
    flags = op_byte >> 5
    op = ID_TO_OP.get(op_id)
    if op is None:
        raise ProtocolError("invalid_payload", "Unknown binary command op")
    if op == "match_end" and not allow_match_end:
        raise ProtocolError("invalid_payload", "match_end is forbidden in command submission")

    if op == "move":
        if flags not in (0, 1):
            raise ProtocolError("invalid_payload", "Invalid move flags")
        cmd: dict[str, Any] = {
            "op": "move",
            "unit_id": reader.read_varint(1),
            "pos": [reader.read_f32(), reader.read_f32()],
        }
        if flags == 1:
            cmd["formation_speed"] = reader.read_f32()
        return cmd
    if op == "stop":
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": "stop", "unit_id": reader.read_varint(1)}
    if op in ("gather", "attack"):
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": op, "unit_id": reader.read_varint(1), "target_id": reader.read_varint(1)}
    if op == "build":
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": "build", "unit_id": reader.read_varint(1), "building_id": reader.read_varint(1)}
    if op == "train":
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": "train", "building_id": reader.read_varint(1), "unit_def_id": reader.read_str8()}
    if op == "cancel_train":
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": "cancel_train", "building_id": reader.read_varint(1), "queue_id": reader.read_varint(1)}
    if op == "place_building":
        if flags > 7 or ((flags & 0x04) == 0 and flags != 0):
            raise ProtocolError("invalid_payload", "Invalid place_building flags")
        cmd = {
            "op": "place_building",
            "builder_id": reader.read_varint(1),
            "building_def_id": reader.read_str8(),
            "pos": [reader.read_f32(), reader.read_f32()],
        }
        if flags & 0x04:
            cmd["orientation"] = flags & 0x03
        return cmd
    if op in ("research_age", "cancel_research_age"):
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": op, "building_id": reader.read_varint(1)}
    if op in ("research_technology", "cancel_technology"):
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        return {"op": op, "building_id": reader.read_varint(1), "technology_id": reader.read_str8()}
    if op == "place_wall":
        if flags > 3:
            raise ProtocolError("invalid_payload", "Invalid place_wall flags")
        return {
            "op": "place_wall",
            "builder_id": reader.read_varint(1),
            "building_def_id": reader.read_str8(),
            "start": [reader.read_f32(), reader.read_f32()],
            "end": [reader.read_f32(), reader.read_f32()],
            "include_gate": bool(flags & 1),
            "append_queue": bool(flags & 2),
        }
    if op == "set_gate_state":
        if flags != 0:
            raise ProtocolError("invalid_payload", "Unexpected flags")
        building_id = reader.read_varint(1)
        gate_state = CODE_TO_GATE.get(reader.read_u8())
        if gate_state is None:
            raise ProtocolError("invalid_payload", "Invalid gate code")
        return {"op": "set_gate_state", "building_id": building_id, "gate_state": gate_state}
    # match_end
    if flags != 0:
        raise ProtocolError("invalid_payload", "Unexpected flags")
    return {"op": "match_end", "winner": _team(reader.read_u8())}


def _speed_to_milli(speed: Any) -> int:
    if type(speed) not in (int, float) or not math.isfinite(float(speed)):
        raise ProtocolError("invalid_payload", "Speed must be finite")
    milli = round(float(speed) * 1000.0)
    if not (250 <= milli <= 4000):
        raise ProtocolError("invalid_payload", "Match speed must be between 0.25 and 4")
    return milli


def _validate_timing_fields(speed_milli: int, input_delay_ticks: int, delay_from_tick: int) -> None:
    if not (250 <= speed_milli <= 4000):
        raise ProtocolError("invalid_payload", "Match speed must be between 0.25 and 4")
    if input_delay_ticks % FRAME_TICKS != 0 or not (FRAME_TICKS <= input_delay_ticks <= MAX_INPUT_LEAD_TICKS):
        raise ProtocolError("invalid_payload", "Input delay must be a bounded positive frame interval")
    if delay_from_tick % FRAME_TICKS != 0:
        raise ProtocolError("invalid_payload", "Input delay activation must align to frame boundary")


def encode_packet(message: dict[str, Any]) -> bytes:
    kind = message.get("type")
    if kind == "clock_probe":
        return struct.pack(
            "<BIQ",
            PKT_CLOCK_PROBE,
            _safe_int(message.get("nonce"), 1, 0xFFFFFFFF),
            _safe_int(message.get("sent_usec")),
        )
    if kind == "clock_reply":
        return struct.pack(
            "<BIQQ",
            PKT_CLOCK_REPLY,
            _safe_int(message.get("nonce"), 1, 0xFFFFFFFF),
            _safe_int(message.get("sent_usec")),
            _safe_int(message.get("received_usec")),
        )
    if kind == "sync_init":
        speed_milli = _speed_to_milli(message.get("speed"))
        delay = _tick(message.get("input_delay_ticks"), allow_zero=False)
        if delay > MAX_INPUT_LEAD_TICKS:
            raise ProtocolError("invalid_payload", "Input delay exceeds max")
        delay_from = _tick(message.get("delay_from_tick"))
        return struct.pack(
            "<BIQHBII",
            PKT_SYNC_INIT,
            _tick(message.get("tick")),
            _safe_int(message.get("epoch_usec"), 1),
            speed_milli,
            delay,
            delay_from,
            _safe_int(message.get("checksum32"), 0, 0xFFFFFFFF),
        )
    if kind == "command_batch":
        commands = message.get("commands")
        if not isinstance(commands, list) or not (1 <= len(commands) <= 64):
            raise ProtocolError("invalid_payload", "Batch requires 1 to 64 commands")
        seq = _safe_int(message.get("seq"), 1)
        if seq + len(commands) - 1 > MAX_SAFE_INTEGER:
            raise ProtocolError("invalid_sequence", "Sequence overflow")
        source = _tick(message.get("source_tick"))
        execute = _tick(message.get("execute_tick"), allow_zero=False)
        if not (source < execute <= source + MAX_INPUT_LEAD_TICKS):
            raise ProtocolError("invalid_sequence", "Invalid command execution tick")
        team = _team(message.get("team", 0))
        out = bytearray([PKT_CMD_SUBMIT, team])
        out.extend(_encode_varint(seq))
        out.extend(struct.pack("<IIB", source, execute, len(commands)))
        for command in commands:
            out.extend(encode_command(command, allow_match_end=False))
        if len(out) > MAX_FRAME_BYTES:
            raise ProtocolError("invalid_payload", "Command batch exceeds size limit")
        return bytes(out)
    if kind == "schedule":
        sched_id = _safe_int(message.get("id"), 1, 0xFFFFFFFF)
        tick = _tick(message.get("tick"), allow_zero=False)
        epoch_usec = _safe_int(message.get("epoch_usec"), 1)
        commands = message.get("commands", [])
        rejected = message.get("rejected", [])
        timing = message.get("timing")
        if not isinstance(commands, list) or len(commands) > MAX_INPUT_COMMANDS:
            raise ProtocolError("invalid_payload", "Schedule commands exceed limit")
        if not isinstance(rejected, list) or len(rejected) > 255:
            raise ProtocolError("invalid_payload", "Schedule rejected list exceeds limit")
        flags = (1 if timing is not None else 0) | (2 if rejected else 0)
        if not commands and flags == 0:
            raise ProtocolError("invalid_payload", "Empty schedule is not allowed")
        out = bytearray(struct.pack("<BIIQBB", PKT_SCHEDULE, sched_id, tick, epoch_usec, flags, len(commands)))
        if timing is not None:
            if not isinstance(timing, dict):
                raise ProtocolError("invalid_payload", "Timing must be a dict")
            speed_milli = _speed_to_milli(timing.get("speed"))
            delay = _tick(timing.get("input_delay_ticks"), allow_zero=False)
            if delay > MAX_INPUT_LEAD_TICKS:
                raise ProtocolError("invalid_payload", "Input delay exceeds limit")
            delay_from = _tick(timing.get("delay_from_tick"))
            out.extend(struct.pack("<HBI", speed_milli, delay, delay_from))
        seen_cmds: set[tuple[int, int]] = set()
        for entry in commands:
            if not isinstance(entry, dict) or set(entry) != {"team", "seq", "command"}:
                raise ProtocolError("invalid_payload", "Invalid scheduled command entry")
            team = _team(entry["team"])
            seq = _safe_int(entry["seq"])
            cmd = entry["command"]
            op = cmd.get("op") if isinstance(cmd, dict) else None
            if (seq == 0) != (op == "match_end"):
                raise ProtocolError("invalid_payload", "seq=0 is reserved for match_end")
            if seq > 0:
                if (team, seq) in seen_cmds:
                    raise ProtocolError("invalid_payload", "Duplicate scheduled command sequence")
                seen_cmds.add((team, seq))
            out.append(team)
            out.extend(_encode_varint(seq))
            out.extend(encode_command(cmd, allow_match_end=True))
        if rejected:
            out.append(len(rejected))
            seen_rej: set[tuple[int, int]] = set()
            for item in rejected:
                if not isinstance(item, dict) or set(item) != {"team", "seq"}:
                    raise ProtocolError("invalid_payload", "Invalid rejected entry")
                team = _team(item["team"])
                seq = _safe_int(item["seq"], 1)
                if (team, seq) in seen_rej:
                    raise ProtocolError("invalid_payload", "Duplicate rejected sequence")
                seen_rej.add((team, seq))
                out.append(team)
                out.extend(_encode_varint(seq))
        if len(out) > MAX_FRAME_BYTES:
            raise ProtocolError("invalid_payload", "Schedule exceeds size limit")
        return bytes(out)
    if kind == "schedule_ack":
        accepted = message.get("accepted")
        if type(accepted) is not bool:
            raise ProtocolError("invalid_payload", "accepted must be boolean")
        return struct.pack(
            "<BIBI",
            PKT_SCHEDULE_ACK,
            _safe_int(message.get("id"), 1, 0xFFFFFFFF),
            1 if accepted else 0,
            _tick(message.get("guest_tick")),
        )
    if kind == "heartbeat":
        return struct.pack(
            "<BIII",
            PKT_HEARTBEAT,
            _tick(message.get("tick")),
            _safe_int(message.get("checksum32"), 0, 0xFFFFFFFF),
            _safe_int(message.get("sent_usec32"), 1, 0xFFFFFFFF),
        )
    if kind == "heartbeat_ack":
        return struct.pack(
            "<BIII",
            PKT_HEARTBEAT_ACK,
            _tick(message.get("ack_tick")),
            _safe_int(message.get("checksum32"), 0, 0xFFFFFFFF),
            _safe_int(message.get("echo_usec32"), 0, 0xFFFFFFFF),
        )
    raise ProtocolError("unknown_type", f"Unsupported binary packet type: {kind}")


def parse_binary_message(raw: bytes, settings: Settings) -> dict[str, Any]:
    if len(raw) > settings.max_message_bytes:
        raise ProtocolError("message_too_large", "Message exceeds the size limit", 1009)
    if not raw:
        raise ProtocolError("invalid_payload", "Empty binary packet")
    reader = _Reader(raw)
    pkt = reader.read_u8()
    result: dict[str, Any]
    if pkt == PKT_CLOCK_PROBE:
        nonce = reader.read_u32()
        if nonce < 1:
            raise ProtocolError("invalid_payload", "Clock probe nonce must be positive")
        sent_usec = reader.read_u64()
        result = {"type": "clock_probe", "nonce": nonce, "sent_usec": sent_usec}
    elif pkt == PKT_CLOCK_REPLY:
        nonce = reader.read_u32()
        if nonce < 1:
            raise ProtocolError("invalid_payload", "Clock reply nonce must be positive")
        sent_usec = reader.read_u64()
        received_usec = reader.read_u64()
        result = {"type": "clock_reply", "nonce": nonce, "sent_usec": sent_usec, "received_usec": received_usec}
    elif pkt == PKT_SYNC_INIT:
        tick = _tick(reader.read_u32())
        epoch_usec = reader.read_u64()
        if epoch_usec < 1:
            raise ProtocolError("invalid_sequence", "Sync epoch must be positive")
        speed_milli = reader.read_u16()
        delay = reader.read_u8()
        delay_from = reader.read_u32()
        _validate_timing_fields(speed_milli, delay, delay_from)
        checksum32 = reader.read_u32()
        result = {
            "type": "sync_init",
            "tick": tick,
            "epoch_usec": epoch_usec,
            "speed": speed_milli / 1000.0,
            "input_delay_ticks": delay,
            "delay_from_tick": delay_from,
            "checksum32": checksum32,
        }
    elif pkt == PKT_CMD_SUBMIT:
        if len(raw) > MAX_FRAME_BYTES:
            raise ProtocolError("invalid_payload", "Command batch exceeds size limit")
        team = _team(reader.read_u8())
        seq = reader.read_varint(1)
        source = _tick(reader.read_u32())
        execute = _tick(reader.read_u32(), allow_zero=False)
        if not (source < execute <= source + MAX_INPUT_LEAD_TICKS):
            raise ProtocolError("invalid_sequence", "Invalid command execution tick")
        count = reader.read_u8()
        if not (1 <= count <= 64) or seq + count - 1 > MAX_SAFE_INTEGER:
            raise ProtocolError("invalid_payload", "Invalid batch command count or sequence overflow")
        commands = [_decode_command(reader, allow_match_end=False) for _ in range(count)]
        result = {
            "type": "command_batch",
            "team": team,
            "seq": seq,
            "source_tick": source,
            "execute_tick": execute,
            "commands": commands,
        }
    elif pkt == PKT_SCHEDULE:
        if len(raw) > MAX_FRAME_BYTES:
            raise ProtocolError("invalid_payload", "Schedule exceeds size limit")
        sched_id = reader.read_u32()
        if sched_id < 1:
            raise ProtocolError("invalid_sequence", "Schedule ID must be positive")
        tick = _tick(reader.read_u32(), allow_zero=False)
        epoch_usec = reader.read_u64()
        if epoch_usec < 1:
            raise ProtocolError("invalid_sequence", "Schedule epoch must be positive")
        flags = reader.read_u8()
        if flags > 3:
            raise ProtocolError("invalid_payload", "Invalid schedule flags")
        cmd_count = reader.read_u8()
        if cmd_count > MAX_INPUT_COMMANDS or (cmd_count == 0 and flags == 0):
            raise ProtocolError("invalid_payload", "Invalid schedule command count")
        result = {"type": "schedule", "id": sched_id, "tick": tick, "epoch_usec": epoch_usec}
        if flags & 1:
            speed_milli = reader.read_u16()
            delay = reader.read_u8()
            delay_from = reader.read_u32()
            _validate_timing_fields(speed_milli, delay, delay_from)
            result["timing"] = {
                "speed": speed_milli / 1000.0,
                "input_delay_ticks": delay,
                "delay_from_tick": delay_from,
            }
        commands = []
        seen_cmds: set[tuple[int, int]] = set()
        for _ in range(cmd_count):
            team = _team(reader.read_u8())
            seq = reader.read_varint(0)
            cmd = _decode_command(reader, allow_match_end=True)
            if (seq == 0) != (cmd["op"] == "match_end"):
                raise ProtocolError("invalid_payload", "seq=0 is reserved for match_end")
            if seq > 0:
                if (team, seq) in seen_cmds:
                    raise ProtocolError("invalid_payload", "Duplicate scheduled sequence")
                seen_cmds.add((team, seq))
            commands.append({"team": team, "seq": seq, "command": cmd})
        result["commands"] = commands
        if flags & 2:
            rej_count = reader.read_u8()
            if rej_count < 1:
                raise ProtocolError("invalid_payload", "Rejected flag set with empty list")
            rejected = []
            seen_rej: set[tuple[int, int]] = set()
            for _ in range(rej_count):
                team = _team(reader.read_u8())
                seq = reader.read_varint(1)
                if (team, seq) in seen_rej:
                    raise ProtocolError("invalid_payload", "Duplicate rejected sequence")
                seen_rej.add((team, seq))
                rejected.append({"team": team, "seq": seq})
            result["rejected"] = rejected
    elif pkt == PKT_SCHEDULE_ACK:
        sched_id = reader.read_u32()
        if sched_id < 1:
            raise ProtocolError("invalid_sequence", "Schedule ack ID must be positive")
        acc = reader.read_u8()
        if acc not in (0, 1):
            raise ProtocolError("invalid_payload", "Schedule ack accepted must be 0 or 1")
        guest_tick = _tick(reader.read_u32())
        result = {"type": "schedule_ack", "id": sched_id, "accepted": acc == 1, "guest_tick": guest_tick}
    elif pkt == PKT_HEARTBEAT:
        tick = _tick(reader.read_u32())
        checksum32 = reader.read_u32()
        sent_usec32 = reader.read_u32()
        if sent_usec32 < 1:
            raise ProtocolError("invalid_payload", "Heartbeat timestamp must be nonzero")
        result = {"type": "heartbeat", "tick": tick, "checksum32": checksum32, "sent_usec32": sent_usec32}
    elif pkt == PKT_HEARTBEAT_ACK:
        ack_tick = _tick(reader.read_u32())
        checksum32 = reader.read_u32()
        echo_usec32 = reader.read_u32()
        result = {"type": "heartbeat_ack", "ack_tick": ack_tick, "checksum32": checksum32, "echo_usec32": echo_usec32}
    else:
        raise ProtocolError("unknown_type", "Unknown binary packet type")

    if reader.remaining() != 0:
        raise ProtocolError("invalid_payload", "Trailing bytes in binary packet")
    return result
