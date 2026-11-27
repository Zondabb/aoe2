extends SceneTree
## Protocol v10 binary + JSON transport contracts, independent of gameplay simulation.
const Session := preload("res://scripts/network/network_session.gd")
const WireCodec := preload("res://scripts/network/wire_codec.gd")
const HASH := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const MATCH_ID := "0123456789abcdef0123456789abcdef"
var checks := 0
var failures: Array[String] = []
var received: Array = []

class RecordingSession extends Session:
	var sent: Array = []
	var sent_binary: Array = []
	func _send(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
		return true
	func _send_binary(payload: PackedByteArray) -> bool:
		sent_binary.append(payload)
		return true

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func info(side := 0, host := 1) -> Dictionary:
	return {"type": "match_found", "match_id": MATCH_ID, "team": side, "host_team": host,
		"protocol_version": 10, "seed": 1923, "tick_rate": 30, "frame_ticks": 3,
		"players": [{"team": 0, "name": "甲", "civ": "chinese"}, {"team": 1, "name": "乙", "civ": "teutons"}]}

func configured(side := 0, host := 1) -> RecordingSession:
	var session := RecordingSession.new()
	session.state = "queued"
	session._handle_message(JSON.parse_string(JSON.stringify(info(side, host))))
	var start := info(side, host)
	start.type = "start"
	session._handle_message(start)
	return session

func _run() -> void:
	for host in [0, 1]:
		var authoritative := configured(host, host)
		check(authoritative.state == "playing" and authoritative.is_host(), "either team can be selected host")
		check(authoritative.send_command({"op": "stop", "unit_id": 2}), "host input can use binary command transport")
		check(not authoritative.send_heartbeat_ack(0, 123, 0) and not authoritative.request_keyframe(), "host cannot impersonate a replica")
		check(authoritative.send_fair_message({"type": "sync_init", "tick": 0, "epoch_usec": 1000000, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0, "checksum32": 0x12345678}), "host can send binary sync_init")
		check(authoritative.send_fair_message({"type": "heartbeat", "tick": 30, "checksum32": 0xAABBCCDD, "sent_usec32": 99}), "host can send binary heartbeat")
		check(authoritative.send_keyframe(MATCH_ID, 0, {"world": {}}, HASH), "host can answer initial tick zero keyframe")
		authoritative.finish_match(1 - host, 30)
		check(authoritative.sent.back().type == "finish_match" and authoritative.sent.back().tick == 30, "actual host may finish match with final tick")
		authoritative.free()

		var guest := configured(1 - host, host)
		check(guest.state == "playing" and not guest.is_host(), "other team is an active simulation peer")
		check(guest.send_command({"op": "move", "unit_id": 3, "pos": [1.125, 2.25]}), "either guest team can submit commands")
		check(not guest.send_fair_message({"type": "sync_init", "tick": 0, "epoch_usec": 1000, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0, "checksum32": 1}) and not guest.send_keyframe(MATCH_ID, 0, {"world": {}}, HASH), "guest cannot publish sync_init or keyframes")
		check(guest.send_heartbeat_ack(0, 0x12345678, 0) and guest.request_keyframe(), "guest can synchronize initial state")
		var before := guest.sent.size()
		guest.finish_match(0, 30)
		guest.send_snapshot({"winner": 0})
		check(guest.sent.size() == before, "legacy snapshots and guest result writes are blocked")
		guest.message_received.connect(func(message: Dictionary): received.append(message.duplicate(true)))
		guest._handle_message({"type": "error", "code": "keyframe_rate_limited", "message": "retry"})
		check(guest.state == "playing" and received.back().code == "keyframe_rate_limited", "keyframe retry remains recoverable")
		guest.free()

	# WireCodec round-trip for all 15 command ops and all 8 binary packet types
	var all_commands: Array = [
		{"op": "move", "unit_id": 1, "pos": [1.5, -2.25]},
		{"op": "move", "unit_id": 300, "pos": [10.0, 20.0], "formation_speed": 3.5},
		{"op": "stop", "unit_id": 2},
		{"op": "gather", "unit_id": 3, "target_id": 400},
		{"op": "build", "unit_id": 4, "building_id": 55},
		{"op": "attack", "unit_id": 5, "target_id": 88},
		{"op": "train", "building_id": 2, "unit_def_id": "villager"},
		{"op": "cancel_train", "building_id": 2, "queue_id": 19},
		{"op": "place_building", "builder_id": 6, "building_def_id": "house", "pos": [32.0, -16.0]},
		{"op": "place_building", "builder_id": 6, "building_def_id": "gate", "pos": [32.0, -16.0], "orientation": 3},
		{"op": "research_age", "building_id": 1},
		{"op": "cancel_research_age", "building_id": 1},
		{"op": "research_technology", "building_id": 1, "technology_id": "loom"},
		{"op": "cancel_technology", "building_id": 1, "technology_id": "loom"},
		{"op": "place_wall", "builder_id": 3, "building_def_id": "stone_wall", "start": [0.0, 0.0], "end": [12.0, 0.0], "include_gate": true, "append_queue": false},
		{"op": "set_gate_state", "building_id": 22, "gate_state": "open"},
	]
	var raw_batch := WireCodec.encode_packet({"type": "command_batch", "team": 1, "seq": 10, "source_tick": 6, "execute_tick": 12, "commands": all_commands})
	check(not raw_batch.is_empty(), "all gameplay command ops encode cleanly")
	var dec_batch := WireCodec.decode_packet(raw_batch)
	check(dec_batch.get("commands") == all_commands and dec_batch.get("seq") == 10, "all gameplay command ops round-trip identically")

	var packets: Array = [
		{"type": "clock_probe", "nonce": 7, "sent_usec": 123456},
		{"type": "clock_reply", "nonce": 7, "sent_usec": 123456, "received_usec": 234567},
		{"type": "sync_init", "tick": 0, "epoch_usec": 1000000, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0, "checksum32": 0x89ABCDEF},
		{"type": "schedule", "id": 1, "tick": 6, "epoch_usec": 1200000, "timing": {"speed": 2.5, "input_delay_ticks": 9, "delay_from_tick": 6},
			"commands": [{"team": 0, "seq": 1, "command": {"op": "stop", "unit_id": 2}}, {"team": 1, "seq": 0, "command": {"op": "match_end", "winner": 1}}],
			"rejected": [{"team": 0, "seq": 99}]},
		{"type": "schedule_ack", "id": 1, "accepted": false, "guest_tick": 9},
		{"type": "heartbeat", "tick": 60, "checksum32": 0x11223344, "sent_usec32": 42},
		{"type": "heartbeat_ack", "ack_tick": 60, "checksum32": 0x11223344, "echo_usec32": 42},
	]
	for pkt in packets:
		var encoded := WireCodec.encode_packet(pkt)
		check(not encoded.is_empty(), "binary packet encodes: " + str(pkt.type))
		var decoded := WireCodec.decode_packet(encoded)
		check(decoded == pkt, "binary packet round-trips: " + str(pkt.type))
		var trailing := encoded.duplicate()
		trailing.append(0)
		check(WireCodec.decode_packet(trailing).is_empty(), "trailing byte rejected: " + str(pkt.type))
		if encoded.size() > 1:
			check(WireCodec.decode_packet(encoded.slice(0, encoded.size() - 1)).is_empty(), "truncated packet rejected: " + str(pkt.type))

	check(WireCodec.encode_packet({"type": "command_batch", "team": 0, "seq": 1, "source_tick": 0, "execute_tick": 6, "commands": [{"op": "match_end", "winner": 0}]}).is_empty(), "match_end forbidden in command_batch")
	check(WireCodec.encode_packet({"type": "schedule", "id": 1, "tick": 6, "epoch_usec": 1000, "commands": []}).is_empty(), "empty schedule forbidden")

	var session := configured()
	check(not session._valid_incremental_message({"type": "keyframe_request", "request_id": "bad"}), "invalid request_id rejected")
	check(not session.send_command({"op": "stop", "team": 1, "unit_id": 5}), "caller cannot forge command identity")
	check(not session.send_command({"op": "set_ai_control", "enabled": 1}), "AI toggle must contain boolean")
	var fractional_host := info()
	fractional_host.host_team = 0.5
	check(not session._valid_match(fractional_host), "fractional host rejected")
	for ver in [1, 5, 6, 7, 8, 9]:
		var old := info()
		old.protocol_version = ver
		check(not session._valid_match(old), "legacy protocol v%d rejected" % ver)

	var batch: Array = []
	for i in 50: batch.append({"op": "move", "unit_id": i + 1, "pos": [float(i), 2.0], "formation_speed": 4.0})
	var batch_before := session.sent_binary.size()
	check(session.send_command_batch(batch, 100, 0, 6), "50-unit formation uses one compact binary packet")
	check(session.sent_binary.size() == batch_before + 1 and session._command_seq == 149, "batch preserves sequence reservation")
	var wire_decoded := WireCodec.decode_packet(session.sent_binary.back())
	check(wire_decoded.commands == batch and session.sent_binary.back().size() < 900, "50-unit binary batch is under 900 bytes")
	check(not session.send_command_batch([], 150, 0, 6), "empty batch rejected")
	batch.append({"op": "stop", "team": 1, "unit_id": 1})
	check(not session.send_command_batch(batch, 150, 0, 6), "spoofed member rejects entire transport batch")

	var snapshot := {"world": {"name": "压缩测试", "entities": []}, "simulation": {"positions": [1.125, -2.25], "counter": 123456}}
	for i in 100: snapshot.world.entities.append({"id": i, "kind": "villager", "position": [i, i]})
	var expected_snapshot: Dictionary = JSON.parse_string(JSON.stringify(snapshot, "", true, true))
	var packed := Session.SnapshotCodec.encode(snapshot)
	check(Session.SnapshotCodec.decode(packed) == expected_snapshot, "compressed keyframe preserves Unicode and numeric state")
	check(JSON.stringify(packed).length() < JSON.stringify(snapshot).length(), "repeated world state shrinks after base64 encoding")
	for invalid_size in [0, -1, 1.5, true, Session.SnapshotCodec.MAX_RAW_BYTES + 1]:
		var bad := packed.duplicate(true)
		bad.raw_size = invalid_size
		check(Session.SnapshotCodec.decode(bad).is_empty(), "snapshot expanded size is strictly bounded")
	var invalid_codec := packed.duplicate(true)
	invalid_codec.codec = "unknown"
	check(Session.SnapshotCodec.decode(invalid_codec).is_empty(), "unknown compression rejected")
	var envelope := {"type": "keyframe", "request_id": MATCH_ID, "tick": 0, "checksum": HASH}
	envelope.merge(packed)
	session.message_received.connect(func(message: Dictionary): received.append(message))
	session._handle_message(envelope)
	check(received.back().get("state") == expected_snapshot and not received.back().has("data"), "runtime receives decoded keyframe through normal validation path")
	var changed := info()
	changed.seed = 999
	check(not session._same_match_parameters(changed), "start cannot change the agreed simulation seed")
	session._handle_message({"type": "match_ended", "match_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "winner": 0, "reason": "completed"})
	check(session.state == "playing", "stale result cannot end a different match")
	session._handle_message({"type": "queued"})
	check(session.state == "playing", "late queue response cannot reset playing state")
	session._handle_message({"type": "match_ended", "match_id": MATCH_ID, "winner": 1, "reason": "completed", "tick": 60})
	check(session.state == "idle" and session.last_result.winner == 1 and session.last_result.tick == 60, "current match result accepted with tick")
	session.free()

	print("INCREMENTAL TRANSPORT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
