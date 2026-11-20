extends SceneTree
## Protocol v8 transport contracts, independent of gameplay simulation.
const Session := preload("res://scripts/network/network_session.gd")
const HASH := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const MATCH_ID := "0123456789abcdef0123456789abcdef"
var checks := 0
var failures: Array[String] = []
var received: Array = []

class RecordingSession extends Session:
	var sent: Array = []
	func _send(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
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
		"protocol_version": 9, "seed": 1923, "tick_rate": 30, "frame_ticks": 3,
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
		check(authoritative.send_command({"op": "stop", "unit_id": 2}), "host input can use command transport")
		check(authoritative.send_frame(3, [{"team": 1 - host, "command": {"op": "stop", "unit_id": 2}}], HASH), "random host publishes ordered frame")
		check(not authoritative.send_ack(0, HASH) and not authoritative.request_keyframe(), "host cannot impersonate a replica")
		check(authoritative.send_keyframe(MATCH_ID, 0, {"world": {}}, HASH), "host can answer initial tick zero keyframe")
		authoritative.finish_match(1 - host)
		check(authoritative.sent.back().type == "finish_match", "actual host may finish match")
		authoritative.free()

		var guest := configured(1 - host, host)
		check(guest.state == "playing" and not guest.is_host(), "other team is an active simulation peer")
		check(guest.send_command({"op": "move", "unit_id": 3, "pos": [1.125, 2.25]}), "either guest team can submit commands")
		check(not guest.send_frame(3, [], HASH) and not guest.send_keyframe(MATCH_ID, 0, {"world": {}}, HASH), "guest cannot publish authoritative frames or keyframes")
		check(guest.send_ack(0, HASH) and guest.request_keyframe(), "guest can synchronize initial state")
		var before := guest.sent.size()
		guest.finish_match(0)
		guest.send_snapshot({"winner": 0})
		check(guest.sent.size() == before, "legacy snapshots and guest result writes are blocked")
		guest.message_received.connect(func(message: Dictionary): received.append(message.duplicate(true)))
		for tick in [3, 6, 9]:
			guest._handle_message({"type": "frame", "tick": tick, "commands": [], "checksum": HASH})
		check(received.slice(received.size() - 3).map(func(frame: Dictionary): return frame.tick) == [3, 6, 9], "every delta frame is delivered in order without coalescing")
		guest._handle_message({"type": "error", "code": "keyframe_rate_limited", "message": "retry"})
		check(guest.state == "playing" and received.back().code == "keyframe_rate_limited", "keyframe retry remains recoverable")
		guest.free()

	var session := configured()
	check(not session._valid_incremental_message({"type": "frame", "tick": 4, "commands": [], "checksum": HASH}), "nonboundary frame rejected")
	check(not session._valid_incremental_message({"type": "frame", "tick": 3.5, "commands": [], "checksum": HASH}), "fractional frame rejected")
	check(not session._valid_incremental_message({"type": "frame", "tick": 3, "commands": [], "checksum": "wrong"}), "malformed checksum rejected")
	check(not session._valid_incremental_message({"type": "frame", "tick": 3, "commands": [{"team": 0.5, "command": {"op": "stop"}}], "checksum": HASH}), "fractional command identity rejected")
	check(not session.send_command({"op": "stop", "team": 1, "unit_id": 5}), "caller cannot forge command identity")
	check(not session.send_command({"op": "set_ai_control", "enabled": 1}), "AI toggle must contain boolean")
	var fractional_host := info()
	fractional_host.host_team = 0.5
	check(not session._valid_match(fractional_host), "fractional host rejected")
	var old := info()
	old.protocol_version = 1
	check(not session._valid_match(old), "legacy protocol rejected")
	old.protocol_version = 5
	check(not session._valid_match(old), "v5 cannot join compact v8")
	var commitment := {"type": "input_commit", "tick": 3, "execute_at_usec": 1000000, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 30}
	check(session._valid_incremental_message(commitment), "startup commit contains a future source-tick policy")
	for invalid in [-3, 1, 3.5, "30"]:
		commitment.delay_from_tick = invalid
		check(not session._valid_incremental_message(commitment), "commit rejects invalid policy boundary")
	commitment.erase("delay_from_tick")
	check(not session._valid_incremental_message(commitment), "commit requires an explicit policy boundary")
	old.protocol_version = 6
	check(not session._valid_match(old), "v6 cannot join compact v8")
	var step := {"type": "input_step", "tick": 6, "execute_at_usec": 1100000, "commands": []}
	check(session._valid_incremental_message(step), "compact step needs no repeated timing policy")
	step.timing = {"speed": 3.0, "input_delay_ticks": 9, "delay_from_tick": 0}
	check(session._valid_incremental_message(step), "compact step can announce changed timing")
	step.timing.speed = true
	check(not session._valid_incremental_message(step), "compact timing rejects booleans")
	step.erase("timing")
	step.execute_at_usec = 1.5
	check(not session._valid_incremental_message(step), "compact deadline requires an integer")
	old.protocol_version = 7
	check(not session._valid_match(old), "v7 cannot join v8")
	var batch: Array = []
	for i in 50: batch.append({"op": "move", "unit_id": i + 1, "pos": [float(i), 2.0], "formation_speed": 4.0})
	var batch_before := session.sent.size()
	check(session.send_command_batch(batch, 100, 0, 6), "50-unit formation can use one transport message")
	check(session.sent.size() == batch_before + 1 and session.sent.back().commands == batch and session._command_seq == 149, "batch preserves targets and reserves consecutive sequence numbers")
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
	session._handle_message({"type": "match_ended", "match_id": MATCH_ID, "winner": 1, "reason": "completed"})
	check(session.state == "idle" and session.last_result.winner == 1, "current match result accepted")
	session.free()

	var observer := RecordingSession.new()
	observer._intent = "watch"
	observer.state = "connecting"
	var watched := info()
	watched.type = "spectate_started"
	watched.role = "spectator"
	watched.erase("team")
	observer._handle_message(watched)
	check(observer.state == "watching" and observer.team == -1 and observer.host_team == 1 and not observer.is_host(), "observer has no team or authority")
	check(not observer.request_keyframe(), "observer waits until scene is ready before requesting state")
	check(observer.send_watch_ready() and observer.request_keyframe(), "ready observer requests fresh host state")
	check(not observer.send_command({"op": "stop", "unit_id": 1}), "observer cannot issue orders")
	check(not observer.send_frame(3, [], HASH) and not observer.send_keyframe(MATCH_ID, 0, {"world": {}}, HASH), "observer cannot issue state updates")
	check(observer._valid_incremental_message({"type": "keyframe", "request_id": MATCH_ID, "tick": 0, "state": {"world": {}}, "checksum": HASH}), "observer accepts initial full keyframe envelope")
	check(observer._valid_incremental_message({"type": "frame", "tick": 3, "commands": [], "checksum": HASH}), "observer accepts subsequent deltas")
	check(not observer._valid_incremental_message({"type": "command", "team": 0, "seq": 1, "command": {"op": "stop"}}), "observer does not receive unvalidated player requests")
	observer.free()
	print("INCREMENTAL TRANSPORT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
