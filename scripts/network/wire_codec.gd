extends RefCounted

## Compact binary wire codec mirroring multiplayer_service_python/wire.py (Protocol v10).
const PKT_CLOCK_PROBE := 0x01
const PKT_CLOCK_REPLY := 0x02
const PKT_SYNC_INIT := 0x03
const PKT_CMD_SUBMIT := 0x04
const PKT_SCHEDULE := 0x05
const PKT_SCHEDULE_ACK := 0x06
const PKT_HEARTBEAT := 0x07
const PKT_HEARTBEAT_ACK := 0x08

const FRAME_TICKS := 3
const MAX_SAFE_INTEGER := 9007199254740991
const MAX_FRAME_BYTES := 262144
const MAX_INPUT_COMMANDS := 62
const MAX_INPUT_LEAD_TICKS := 180
const MAX_MESSAGE_BYTES := 4194304

const OP_TO_ID := {
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
const ID_TO_OP := {
	0x01: "move",
	0x02: "stop",
	0x03: "gather",
	0x04: "build",
	0x05: "attack",
	0x06: "train",
	0x07: "cancel_train",
	0x08: "place_building",
	0x09: "research_age",
	0x0A: "cancel_research_age",
	0x0B: "research_technology",
	0x0C: "cancel_technology",
	0x0D: "place_wall",
	0x0E: "set_gate_state",
	0x0F: "match_end",
}
const GATE_TO_CODE := {"auto": 0, "open": 1, "locked": 2}
const CODE_TO_GATE := {0: "auto", 1: "open", 2: "locked"}
const FORBIDDEN_CMD_KEYS := ["team", "player_id", "match_id", "host_team"]
const ALLOWED_CMD_KEYS := {
	"move": ["op", "unit_id", "pos", "formation_speed"],
	"stop": ["op", "unit_id"],
	"gather": ["op", "unit_id", "target_id"],
	"build": ["op", "unit_id", "building_id"],
	"attack": ["op", "unit_id", "target_id"],
	"train": ["op", "building_id", "unit_def_id"],
	"cancel_train": ["op", "building_id", "queue_id"],
	"place_building": ["op", "builder_id", "building_def_id", "pos", "orientation"],
	"research_age": ["op", "building_id"],
	"cancel_research_age": ["op", "building_id"],
	"research_technology": ["op", "building_id", "technology_id"],
	"cancel_technology": ["op", "building_id", "technology_id"],
	"place_wall": ["op", "builder_id", "building_def_id", "start", "end", "include_gate", "append_queue"],
	"set_gate_state": ["op", "building_id", "gate_state"],
	"match_end": ["op", "winner"],
}

class ByteWriter extends RefCounted:
	var buf := PackedByteArray()
	var ok := true

	func write_u8(v: int) -> void:
		if v < 0 or v > 255: ok = false; return
		buf.append(v)

	func write_u16(v: int) -> void:
		if v < 0 or v > 65535: ok = false; return
		var p := buf.size()
		buf.resize(p + 2)
		buf.encode_u16(p, v)

	func write_u32(v: int) -> void:
		if v < 0 or v > 4294967295: ok = false; return
		var p := buf.size()
		buf.resize(p + 4)
		buf.encode_u32(p, v)

	func write_u64(v: int) -> void:
		if v < 0 or v > MAX_SAFE_INTEGER: ok = false; return
		var p := buf.size()
		buf.resize(p + 8)
		buf.encode_u64(p, v)

	func write_f32(v: Variant) -> void:
		if (v is not int and v is not float) or not is_finite(float(v)): ok = false; return
		var p := buf.size()
		buf.resize(p + 4)
		buf.encode_float(p, float(v))
		if not is_finite(buf.decode_float(p)): ok = false

	func write_varint(v: int) -> void:
		if v < 0 or v > MAX_SAFE_INTEGER: ok = false; return
		var value := v
		while true:
			var b := value & 0x7F
			value >>= 7
			if value != 0:
				buf.append(b | 0x80)
			else:
				buf.append(b)
				return

	func write_str8(s: Variant) -> void:
		if s is not String: ok = false; return
		var text := String(s)
		if text.length() < 1 or text.length() > 128: ok = false; return
		var raw: PackedByteArray = text.to_ascii_buffer()
		if raw.size() != text.length(): ok = false; return
		for ch in raw:
			var valid := (ch >= 97 and ch <= 122) or (ch >= 48 and ch <= 57) or ch == 95
			if not valid: ok = false; return
		buf.append(raw.size())
		buf.append_array(raw)

class ByteReader extends RefCounted:
	var buf: PackedByteArray
	var pos := 0
	var ok := true

	func _init(data: PackedByteArray) -> void:
		buf = data

	func remaining() -> int:
		return buf.size() - pos

	func read_u8() -> int:
		if pos + 1 > buf.size(): ok = false; return 0
		var v := buf[pos]
		pos += 1
		return v

	func read_u16() -> int:
		if pos + 2 > buf.size(): ok = false; return 0
		var v := buf.decode_u16(pos)
		pos += 2
		return v

	func read_u32() -> int:
		if pos + 4 > buf.size(): ok = false; return 0
		var v := buf.decode_u32(pos)
		pos += 4
		return v

	func read_u64() -> int:
		if pos + 8 > buf.size(): ok = false; return 0
		var v := buf.decode_u64(pos)
		pos += 8
		if v < 0 or v > MAX_SAFE_INTEGER: ok = false; return 0
		return v

	func read_f32() -> float:
		if pos + 4 > buf.size(): ok = false; return 0.0
		var v := buf.decode_float(pos)
		pos += 4
		if not is_finite(v): ok = false; return 0.0
		return v

	func read_varint(minimum := 0) -> int:
		var value := 0
		var shift := 0
		var count := 0
		while true:
			var b := read_u8()
			if not ok: return 0
			count += 1
			if count > 8: ok = false; return 0
			if count > 1 and b == 0: ok = false; return 0
			value |= (b & 0x7F) << shift
			if (b & 0x80) == 0:
				break
			shift += 7
		if value < minimum or value > MAX_SAFE_INTEGER: ok = false; return 0
		return value

	func read_str8() -> String:
		var length := read_u8()
		if not ok or length < 1 or length > 128 or pos + length > buf.size():
			ok = false
			return ""
		var sub := buf.slice(pos, pos + length)
		pos += length
		for b in sub:
			var ch := b
			var valid := (ch >= 97 and ch <= 122) or (ch >= 48 and ch <= 57) or ch == 95
			if not valid:
				ok = false
				return ""
		return sub.get_string_from_ascii()

static func checksum32(hex_checksum: String) -> int:
	if hex_checksum.length() < 8: return 0
	return hex_checksum.substr(0, 8).hex_to_int()

static func _int_val(v: Variant, minimum := 0, maximum := MAX_SAFE_INTEGER) -> int:
	if v is not int and v is not float: return -1
	if not is_finite(float(v)) or float(v) != floor(float(v)): return -1
	var iv := int(v)
	if iv < minimum or iv > maximum: return -1
	return iv

static func _tick_val(v: Variant, allow_zero := true) -> int:
	var iv := _int_val(v, 0 if allow_zero else FRAME_TICKS, 4294967295)
	if iv < 0 or iv % FRAME_TICKS != 0: return -1
	return iv

static func _speed_milli(v: Variant) -> int:
	if (v is not int and v is not float) or not is_finite(float(v)): return -1
	var milli := roundi(float(v) * 1000.0)
	if milli < 250 or milli > 4000: return -1
	return milli

static func _f32(v: float) -> float:
	var buf := PackedByteArray()
	buf.resize(4)
	buf.encode_float(0, v)
	return buf.decode_float(0)

static func canonical_command(command: Dictionary) -> Dictionary:
	var out := command.duplicate(true)
	for key in ["pos", "start", "end"]:
		if out.has(key) and out[key] is Array and out[key].size() == 2:
			out[key] = [_f32(float(out[key][0])), _f32(float(out[key][1]))]
	if out.has("formation_speed") and (out.formation_speed is int or out.formation_speed is float):
		out["formation_speed"] = _f32(float(out["formation_speed"]))
	if out.get("op") == "place_wall":
		out["include_gate"] = bool(out.get("include_gate", false))
		out["append_queue"] = bool(out.get("append_queue", false))
	return out

static func encode_command(w: ByteWriter, command: Variant, allow_match_end := false) -> void:
	if command is not Dictionary or command.get("op") is not String: w.ok = false; return
	var op := String(command.op)
	if not OP_TO_ID.has(op): w.ok = false; return
	for key in FORBIDDEN_CMD_KEYS:
		if command.has(key): w.ok = false; return
	var allowed: Array = ALLOWED_CMD_KEYS[op]
	for key in command:
		if key not in allowed: w.ok = false; return
	if op == "match_end" and not allow_match_end: w.ok = false; return
	var op_id: int = OP_TO_ID[op]
	match op:
		"move":
			var pos: Variant = command.get("pos")
			if pos is not Array or pos.size() != 2: w.ok = false; return
			var has_speed: bool = command.has("formation_speed")
			var flags := 1 if has_speed else 0
			w.write_u8(op_id | (flags << 5))
			w.write_varint(_int_val(command.get("unit_id"), 1))
			w.write_f32(pos[0])
			w.write_f32(pos[1])
			if has_speed: w.write_f32(command.formation_speed)
		"stop":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("unit_id"), 1))
		"gather", "attack":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("unit_id"), 1))
			w.write_varint(_int_val(command.get("target_id"), 1))
		"build":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("unit_id"), 1))
			w.write_varint(_int_val(command.get("building_id"), 1))
		"train":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("building_id"), 1))
			w.write_str8(command.get("unit_def_id"))
		"cancel_train":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("building_id"), 1))
			w.write_varint(_int_val(command.get("queue_id"), 1))
		"place_building":
			var flags := 0
			if command.has("orientation"):
				var ori := _int_val(command.orientation, 0, 3)
				if ori < 0: w.ok = false; return
				flags = 0x04 | ori
			var pos: Variant = command.get("pos")
			if pos is not Array or pos.size() != 2: w.ok = false; return
			w.write_u8(op_id | (flags << 5))
			w.write_varint(_int_val(command.get("builder_id"), 1))
			w.write_str8(command.get("building_def_id"))
			w.write_f32(pos[0])
			w.write_f32(pos[1])
		"research_age", "cancel_research_age":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("building_id"), 1))
		"research_technology", "cancel_technology":
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("building_id"), 1))
			w.write_str8(command.get("technology_id"))
		"place_wall":
			var inc: Variant = command.get("include_gate", false)
			var app: Variant = command.get("append_queue", false)
			if inc is not bool or app is not bool: w.ok = false; return
			var s: Variant = command.get("start")
			var e: Variant = command.get("end")
			if s is not Array or s.size() != 2 or e is not Array or e.size() != 2: w.ok = false; return
			var flags := (1 if inc else 0) | (2 if app else 0)
			w.write_u8(op_id | (flags << 5))
			w.write_varint(_int_val(command.get("builder_id"), 1))
			w.write_str8(command.get("building_def_id"))
			w.write_f32(s[0]); w.write_f32(s[1])
			w.write_f32(e[0]); w.write_f32(e[1])
		"set_gate_state":
			var gate: Variant = command.get("gate_state")
			if gate is not String or not GATE_TO_CODE.has(gate): w.ok = false; return
			w.write_u8(op_id)
			w.write_varint(_int_val(command.get("building_id"), 1))
			w.write_u8(GATE_TO_CODE[gate])
		"match_end":
			var winner := _int_val(command.get("winner"), 0, 1)
			if winner < 0: w.ok = false; return
			w.write_u8(op_id)
			w.write_u8(winner)

static func decode_command(r: ByteReader, allow_match_end := false) -> Dictionary:
	var op_byte := r.read_u8()
	if not r.ok: return {}
	var op_id := op_byte & 0x1F
	var flags := op_byte >> 5
	if not ID_TO_OP.has(op_id): r.ok = false; return {}
	var op: String = ID_TO_OP[op_id]
	if op == "match_end" and not allow_match_end: r.ok = false; return {}
	match op:
		"move":
			if flags not in [0, 1]: r.ok = false; return {}
			var cmd := {"op": "move", "unit_id": r.read_varint(1), "pos": [r.read_f32(), r.read_f32()]}
			if flags == 1: cmd["formation_speed"] = r.read_f32()
			return cmd
		"stop":
			if flags != 0: r.ok = false; return {}
			return {"op": "stop", "unit_id": r.read_varint(1)}
		"gather", "attack":
			if flags != 0: r.ok = false; return {}
			return {"op": op, "unit_id": r.read_varint(1), "target_id": r.read_varint(1)}
		"build":
			if flags != 0: r.ok = false; return {}
			return {"op": "build", "unit_id": r.read_varint(1), "building_id": r.read_varint(1)}
		"train":
			if flags != 0: r.ok = false; return {}
			return {"op": "train", "building_id": r.read_varint(1), "unit_def_id": r.read_str8()}
		"cancel_train":
			if flags != 0: r.ok = false; return {}
			return {"op": "cancel_train", "building_id": r.read_varint(1), "queue_id": r.read_varint(1)}
		"place_building":
			if flags > 7 or ((flags & 0x04) == 0 and flags != 0): r.ok = false; return {}
			var cmd := {"op": "place_building", "builder_id": r.read_varint(1), "building_def_id": r.read_str8(), "pos": [r.read_f32(), r.read_f32()]}
			if (flags & 0x04) != 0: cmd["orientation"] = flags & 0x03
			return cmd
		"research_age", "cancel_research_age":
			if flags != 0: r.ok = false; return {}
			return {"op": op, "building_id": r.read_varint(1)}
		"research_technology", "cancel_technology":
			if flags != 0: r.ok = false; return {}
			return {"op": op, "building_id": r.read_varint(1), "technology_id": r.read_str8()}
		"place_wall":
			if flags > 3: r.ok = false; return {}
			return {
				"op": "place_wall",
				"builder_id": r.read_varint(1),
				"building_def_id": r.read_str8(),
				"start": [r.read_f32(), r.read_f32()],
				"end": [r.read_f32(), r.read_f32()],
				"include_gate": (flags & 1) != 0,
				"append_queue": (flags & 2) != 0,
			}
		"set_gate_state":
			if flags != 0: r.ok = false; return {}
			var bid := r.read_varint(1)
			var code := r.read_u8()
			if not CODE_TO_GATE.has(code): r.ok = false; return {}
			return {"op": "set_gate_state", "building_id": bid, "gate_state": CODE_TO_GATE[code]}
		"match_end":
			if flags != 0: r.ok = false; return {}
			var winner := r.read_u8()
			if winner not in [0, 1]: r.ok = false; return {}
			return {"op": "match_end", "winner": winner}
	return {}

static func encode_packet(message: Dictionary) -> PackedByteArray:
	var w := ByteWriter.new()
	var kind := str(message.get("type", ""))
	match kind:
		"clock_probe":
			w.write_u8(PKT_CLOCK_PROBE)
			w.write_u32(_int_val(message.get("nonce"), 1, 4294967295))
			w.write_u64(_int_val(message.get("sent_usec"), 0))
		"clock_reply":
			w.write_u8(PKT_CLOCK_REPLY)
			w.write_u32(_int_val(message.get("nonce"), 1, 4294967295))
			w.write_u64(_int_val(message.get("sent_usec"), 0))
			w.write_u64(_int_val(message.get("received_usec"), 0))
		"sync_init":
			w.write_u8(PKT_SYNC_INIT)
			w.write_u32(_tick_val(message.get("tick"), true))
			w.write_u64(_int_val(message.get("epoch_usec"), 1))
			w.write_u16(_speed_milli(message.get("speed")))
			var delay := _tick_val(message.get("input_delay_ticks"), false)
			if delay > MAX_INPUT_LEAD_TICKS: return PackedByteArray()
			w.write_u8(delay)
			w.write_u32(_tick_val(message.get("delay_from_tick"), true))
			w.write_u32(_int_val(message.get("checksum32"), 0, 4294967295))
		"command_batch":
			var commands: Variant = message.get("commands")
			if commands is not Array or commands.is_empty() or commands.size() > 64: return PackedByteArray()
			var seq := _int_val(message.get("seq"), 1)
			if seq < 1 or seq + commands.size() - 1 > MAX_SAFE_INTEGER: return PackedByteArray()
			var source := _tick_val(message.get("source_tick"), true)
			var execute := _tick_val(message.get("execute_tick"), false)
			if source < 0 or execute <= source or execute > source + MAX_INPUT_LEAD_TICKS: return PackedByteArray()
			w.write_u8(PKT_CMD_SUBMIT)
			w.write_u8(_int_val(message.get("team", 0), 0, 1))
			w.write_varint(seq)
			w.write_u32(source)
			w.write_u32(execute)
			w.write_u8(commands.size())
			for cmd in commands: encode_command(w, cmd, false)
			if w.buf.size() > MAX_FRAME_BYTES: return PackedByteArray()
		"schedule":
			var commands: Variant = message.get("commands", [])
			var rejected: Variant = message.get("rejected", [])
			var has_timing: bool = message.has("timing") and message.timing != null
			if commands is not Array or commands.size() > MAX_INPUT_COMMANDS: return PackedByteArray()
			if rejected is not Array or rejected.size() > 255: return PackedByteArray()
			var flags := (1 if has_timing else 0) | (2 if not rejected.is_empty() else 0)
			if commands.is_empty() and flags == 0: return PackedByteArray()
			w.write_u8(PKT_SCHEDULE)
			w.write_u32(_int_val(message.get("id"), 1, 4294967295))
			w.write_u32(_tick_val(message.get("tick"), false))
			w.write_u64(_int_val(message.get("epoch_usec"), 1))
			w.write_u8(flags)
			w.write_u8(commands.size())
			if has_timing:
				var timing: Variant = message.timing
				if timing is not Dictionary: return PackedByteArray()
				w.write_u16(_speed_milli(timing.get("speed")))
				var delay := _tick_val(timing.get("input_delay_ticks"), false)
				if delay > MAX_INPUT_LEAD_TICKS: return PackedByteArray()
				w.write_u8(delay)
				w.write_u32(_tick_val(timing.get("delay_from_tick"), true))
			var seen_cmds := {}
			for entry in commands:
				if entry is not Dictionary or entry.size() != 3: return PackedByteArray()
				var side := _int_val(entry.get("team"), 0, 1)
				var seq := _int_val(entry.get("seq"), 0)
				var cmd: Variant = entry.get("command")
				if side < 0 or seq < 0 or cmd is not Dictionary: return PackedByteArray()
				if (seq == 0) != (cmd.get("op") == "match_end"): return PackedByteArray()
				if seq > 0:
					var key := "%d:%d" % [side, seq]
					if seen_cmds.has(key): return PackedByteArray()
					seen_cmds[key] = true
				w.write_u8(side)
				w.write_varint(seq)
				encode_command(w, cmd, true)
			if not rejected.is_empty():
				w.write_u8(rejected.size())
				var seen_rej := {}
				for item in rejected:
					if item is not Dictionary or not item.has("team") or not item.has("seq"): return PackedByteArray()
					var side := _int_val(item.get("team"), 0, 1)
					var seq := _int_val(item.get("seq"), 1)
					if side < 0 or seq < 1: return PackedByteArray()
					var key := "%d:%d" % [side, seq]
					if seen_rej.has(key): return PackedByteArray()
					seen_rej[key] = true
					w.write_u8(side)
					w.write_varint(seq)
			if w.buf.size() > MAX_FRAME_BYTES: return PackedByteArray()
		"schedule_ack":
			var accepted: Variant = message.get("accepted")
			if accepted is not bool: return PackedByteArray()
			w.write_u8(PKT_SCHEDULE_ACK)
			w.write_u32(_int_val(message.get("id"), 1, 4294967295))
			w.write_u8(1 if accepted else 0)
			w.write_u32(_tick_val(message.get("guest_tick"), true))
		"heartbeat":
			w.write_u8(PKT_HEARTBEAT)
			w.write_u32(_tick_val(message.get("tick"), true))
			w.write_u32(_int_val(message.get("checksum32"), 0, 4294967295))
			w.write_u32(_int_val(message.get("sent_usec32"), 1, 4294967295))
		"heartbeat_ack":
			w.write_u8(PKT_HEARTBEAT_ACK)
			w.write_u32(_tick_val(message.get("ack_tick"), true))
			w.write_u32(_int_val(message.get("checksum32"), 0, 4294967295))
			w.write_u32(_int_val(message.get("echo_usec32"), 0, 4294967295))
		_:
			return PackedByteArray()
	return w.buf if w.ok else PackedByteArray()

static func decode_packet(raw: PackedByteArray, local_team := -1) -> Dictionary:
	if raw.is_empty() or raw.size() > MAX_MESSAGE_BYTES: return {}
	var r := ByteReader.new(raw)
	var pkt := r.read_u8()
	var result := {}
	match pkt:
		PKT_CLOCK_PROBE:
			var nonce := r.read_u32()
			var sent := r.read_u64()
			if not r.ok or nonce < 1: return {}
			result = {"type": "clock_probe", "nonce": nonce, "sent_usec": sent}
			if local_team in [0, 1]: result["team"] = 1 - local_team
		PKT_CLOCK_REPLY:
			var nonce := r.read_u32()
			var sent := r.read_u64()
			var received := r.read_u64()
			if not r.ok or nonce < 1: return {}
			result = {"type": "clock_reply", "nonce": nonce, "sent_usec": sent, "received_usec": received}
			if local_team in [0, 1]: result["team"] = 1 - local_team
		PKT_SYNC_INIT:
			var tick := r.read_u32()
			var epoch := r.read_u64()
			var speed_milli := r.read_u16()
			var delay := r.read_u8()
			var delay_from := r.read_u32()
			var csum := r.read_u32()
			if not r.ok or epoch < 1 or tick % FRAME_TICKS != 0 or speed_milli < 250 or speed_milli > 4000 or delay < FRAME_TICKS or delay > MAX_INPUT_LEAD_TICKS or delay % FRAME_TICKS != 0 or delay_from % FRAME_TICKS != 0:
				return {}
			result = {"type": "sync_init", "tick": tick, "epoch_usec": epoch, "speed": float(speed_milli) / 1000.0, "input_delay_ticks": delay, "delay_from_tick": delay_from, "checksum32": csum}
		PKT_CMD_SUBMIT:
			if raw.size() > MAX_FRAME_BYTES: return {}
			var side := r.read_u8()
			var seq := r.read_varint(1)
			var source := r.read_u32()
			var execute := r.read_u32()
			var count := r.read_u8()
			if not r.ok or side not in [0, 1] or source % FRAME_TICKS != 0 or execute < FRAME_TICKS or execute % FRAME_TICKS != 0 or execute <= source or execute > source + MAX_INPUT_LEAD_TICKS or count < 1 or count > 64 or seq + count - 1 > MAX_SAFE_INTEGER:
				return {}
			var commands: Array = []
			for _i in count:
				commands.append(decode_command(r, false))
				if not r.ok: return {}
			result = {"type": "command_batch", "team": side, "seq": seq, "source_tick": source, "execute_tick": execute, "commands": commands}
		PKT_SCHEDULE:
			if raw.size() > MAX_FRAME_BYTES: return {}
			var sched_id := r.read_u32()
			var tick := r.read_u32()
			var epoch := r.read_u64()
			var flags := r.read_u8()
			var cmd_count := r.read_u8()
			if not r.ok or sched_id < 1 or tick < FRAME_TICKS or tick % FRAME_TICKS != 0 or epoch < 1 or flags > 3 or cmd_count > MAX_INPUT_COMMANDS or (cmd_count == 0 and flags == 0):
				return {}
			result = {"type": "schedule", "id": sched_id, "tick": tick, "epoch_usec": epoch}
			if (flags & 1) != 0:
				var speed_milli := r.read_u16()
				var delay := r.read_u8()
				var delay_from := r.read_u32()
				if not r.ok or speed_milli < 250 or speed_milli > 4000 or delay < FRAME_TICKS or delay > MAX_INPUT_LEAD_TICKS or delay % FRAME_TICKS != 0 or delay_from % FRAME_TICKS != 0:
					return {}
				result["timing"] = {"speed": float(speed_milli) / 1000.0, "input_delay_ticks": delay, "delay_from_tick": delay_from}
			var commands: Array = []
			var seen_cmds := {}
			for _i in cmd_count:
				var side := r.read_u8()
				var seq := r.read_varint(0)
				var cmd := decode_command(r, true)
				if not r.ok or side not in [0, 1] or (seq == 0) != (cmd.get("op") == "match_end"): return {}
				if seq > 0:
					var key := "%d:%d" % [side, seq]
					if seen_cmds.has(key): return {}
					seen_cmds[key] = true
				commands.append({"team": side, "seq": seq, "command": cmd})
			result["commands"] = commands
			if (flags & 2) != 0:
				var rej_count := r.read_u8()
				if not r.ok or rej_count < 1: return {}
				var rejected: Array = []
				var seen_rej := {}
				for _i in rej_count:
					var side := r.read_u8()
					var seq := r.read_varint(1)
					if not r.ok or side not in [0, 1]: return {}
					var key := "%d:%d" % [side, seq]
					if seen_rej.has(key): return {}
					seen_rej[key] = true
					rejected.append({"team": side, "seq": seq})
				result["rejected"] = rejected
		PKT_SCHEDULE_ACK:
			var sched_id := r.read_u32()
			var acc := r.read_u8()
			var guest_tick := r.read_u32()
			if not r.ok or sched_id < 1 or acc not in [0, 1] or guest_tick % FRAME_TICKS != 0: return {}
			result = {"type": "schedule_ack", "id": sched_id, "accepted": acc == 1, "guest_tick": guest_tick}
			if local_team in [0, 1]: result["team"] = 1 - local_team
		PKT_HEARTBEAT:
			var tick := r.read_u32()
			var csum := r.read_u32()
			var sent32 := r.read_u32()
			if not r.ok or tick % FRAME_TICKS != 0 or sent32 < 1: return {}
			result = {"type": "heartbeat", "tick": tick, "checksum32": csum, "sent_usec32": sent32}
		PKT_HEARTBEAT_ACK:
			var ack_tick := r.read_u32()
			var csum := r.read_u32()
			var echo32 := r.read_u32()
			if not r.ok or ack_tick % FRAME_TICKS != 0: return {}
			result = {"type": "heartbeat_ack", "ack_tick": ack_tick, "checksum32": csum, "echo_usec32": echo32}
			if local_team in [0, 1]: result["team"] = 1 - local_team
		_:
			return {}
	if not r.ok or r.remaining() != 0: return {}
	return result
