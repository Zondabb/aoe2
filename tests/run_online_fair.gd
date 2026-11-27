extends SceneTree
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Fair := preload("res://scripts/network/fair_lockstep.gd")
const WireCodec := preload("res://scripts/network/wire_codec.gd")
var checks := 0
var failures: Array[String] = []

class Transport extends Node:
	var sent: Array = []
	var host_team := 0
	func send_fair_message(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
		return true
	func send_heartbeat_ack(ack_tick: int, csum32: int, echo32: int) -> bool:
		sent.append({"type": "heartbeat_ack", "ack_tick": ack_tick, "checksum32": csum32, "echo_usec32": echo32})
		return true
	func send_command_batch(commands: Array, seq: int, source: int, target: int) -> bool:
		sent.append({"type": "command_batch", "seq": seq, "source_tick": source, "execute_tick": target, "commands": commands.duplicate(true)})
		return true
	func send_scheduled_command(command: Dictionary, seq: int, source: int, target: int) -> bool:
		return send_command_batch([command], seq, source, target)
	func request_keyframe() -> bool:
		sent.append({"type": "request_keyframe"})
		return true
	func leave() -> void: pass
	func send_frame(_tick: int, _commands: Array, _hash: String, _results: Array = []) -> bool: return true
	func finish_match(_winner: int, _tick := -1) -> void: pass

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)
		push_error(label)

func _run() -> void:
	var game := root.get_node("GameSession")
	game.online_active = false
	game.match_ai_mode = "sandbox"
	game.match_map_data = {}
	game.pending_save_data = {}
	var scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	var bootstrap: Node = scene.get_node("Bootstrap")
	var net := Runtime.new()
	net.name = "NetworkMatch"
	scene.add_child(net)
	net.set_process(false)
	net.set_physics_process(false)
	net.match_state = bootstrap.match_state
	net.match_state.fog_enabled = false
	net.entities = scene.get_node("Entities")
	net.map_bounds = bootstrap.map_bounds
	net._civs = {0: bootstrap.player_civ, 1: bootstrap.ai_civ}
	net.local_team = 0
	net.match_speed = 2.0
	net.is_host = true
	net._playing = true
	net.synchronized = true
	net.session = Transport.new()
	scene.add_child(net.session)
	net.simulation = Simulation.new()
	net.simulation.setup(net)
	net.fair = Fair.new()
	net.fair.setup(net)
	net.last_checksum = str(net.simulation.frame_checksum())
	net.fair.record_checksum(0, net.last_checksum)

	var unit: UnitAgent
	var enemy: UnitAgent
	for entity in net.entities.get_children():
		if entity is UnitAgent:
			if entity.team == 0 and unit == null: unit = entity
			elif entity.team == 1 and enemy == null: enemy = entity
	check(unit != null and enemy != null, "fixture has both players")
	var id := net.entity_id(unit)
	var origin := unit.sim_pos
	var target := origin + Vector2(1, 0)
	var move := {"op": "move", "unit_id": id, "pos": [target.x, target.y]}
	var before: String = net.simulation.checksum()
	var delay: int = net.fair.input_delay_ticks

	# 1. Input delay validation and silent startup handshake (SYNC_INIT)
	check(net.fair.enqueue(move, 0, 1, 0, delay), "host schedules future input")
	check(net.fair.enqueue({"op": "stop", "unit_id": net.entity_id(enemy)}, 1, 1, 0, delay), "guest receives identical future tick rule")
	check(not net.fair.enqueue(move, 1, 99, 0, 1), "guest cannot request a shorter input window")
	check(not net.fair.enqueue(move, 0, 99, 0, 1), "host obeys the same minimum input window")
	check(not net.fair.enqueue(move, 0, 2, 0, 0), "past execution rejected for host")
	check(not net.fair.enqueue(move, 1, 2, 0, 0), "past execution rejected for guest")
	check(net.simulation.checksum() == before, "enqueueing executes nothing")

	var now := Time.get_ticks_usec()
	check(net.fair.advance(now, 2) == 0 and net.tick == 0, "cannot advance before SYNC_INIT")
	# Guest sends initial HEARTBEAT_ACK(0, csum32, 0)
	net.fair.receive({"type": "heartbeat_ack", "ack_tick": 0, "checksum32": WireCodec.checksum32(net.last_checksum), "echo_usec32": 0, "team": 1})
	check(net.fair.timeline_ready, "matching checksum32 enables zero-keyframe timeline")
	check(net.session.sent.any(func(p: Dictionary): return p.type == "sync_init"), "host sends SYNC_INIT")
	check(not net.fair.in_flight.is_empty(), "queued inputs emit one SCHEDULE packet")
	var sched_pkt: Dictionary = net.fair.in_flight.duplicate(true)
	check(net.fair.advance(int(sched_pkt.epoch_usec) + 500000, 4) == 0 or net.tick < int(sched_pkt.tick), "host pauses before scheduled tick until SCHEDULE_ACK")

	# Confirm schedule -> advances on epoch clock
	net.fair.receive({"type": "schedule_ack", "id": int(sched_pkt.id), "accepted": true, "guest_tick": 0, "team": 1})
	check(net.fair.in_flight.is_empty() and net.fair.confirmed_schedules.has(int(sched_pkt.tick)), "accepted schedule becomes confirmed")
	var due := int(sched_pkt.epoch_usec)
	check(net.fair.advance(due - 500000, 2) == 0, "host does not advance before scheduled epoch")
	while net.tick < int(sched_pkt.tick):
		net._guest_ack_tick = net.tick
		if net.fair.advance(due + 2000000, 4) == 0: break
	check(net.tick == int(sched_pkt.tick) and net.simulation.checksum() != before, "simulation executes at scheduled tick")

	# 2. Silent advancement across 40 empty frames (0 schedule packets sent, only 1 Hz heartbeat at tick % 60 == 0)
	var before_silent: int = net.session.sent.size()
	var silent_start_tick: int = net.tick
	var wall := due + 2000000
	for _i in 40:
		net._guest_ack_tick = net.tick
		wall += 50000
		while net.fair.advance(wall, 4) > 0:
			net._guest_ack_tick = net.tick
			net.fair.poll(wall)
	var silent_packets: Array = net.session.sent.slice(before_silent)
	check(net.tick >= silent_start_tick + 90, "silent timeline advances normally without empty frame packets")
	check(not silent_packets.any(func(p: Dictionary): return p.type == "schedule"), "empty frames emit zero schedule packets")
	var hbs := silent_packets.filter(func(p: Dictionary): return p.type == "heartbeat")
	check(hbs.size() >= 1 and hbs.all(func(p: Dictionary): return int(p.tick) % 60 == 0), "2x speed emits 1 Hz heartbeat at exact 60-tick boundaries")

	# 3. Guest SYNC_INIT mismatch requests keyframe, match clears it
	net.is_host = false
	var guest_fair := Fair.new()
	guest_fair.setup(net)
	guest_fair.clock_ready = true
	guest_fair.record_checksum(net.tick, net.last_checksum)
	var bad_before: int = net.session.sent.size()
	guest_fair.receive({"type": "sync_init", "tick": net.tick, "epoch_usec": wall, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0, "checksum32": WireCodec.checksum32(net.last_checksum) ^ 0xFF})
	check(net.session.sent.slice(bad_before).any(func(p: Dictionary): return p.type == "request_keyframe"), "startup checksum mismatch falls back to keyframe")
	net._awaiting_keyframe = false
	net.synchronized = true
	guest_fair.reset(net.tick)
	guest_fair.record_checksum(net.tick, net.last_checksum)
	guest_fair.receive({"type": "sync_init", "tick": net.tick, "epoch_usec": wall, "speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0, "checksum32": WireCodec.checksum32(net.last_checksum)})
	check(guest_fair.timeline_ready, "matching SYNC_INIT arms guest silent timeline")

	# 4. Guest late-arrival lossless reschedule (SCHEDULE_ACK accepted=false)
	var late_tick: int = net.tick
	guest_fair.receive({"type": "schedule", "id": 10, "tick": late_tick, "epoch_usec": wall, "commands": [{"team": 0, "seq": 50, "command": move}]})
	var ack_reply: Dictionary = net.session.sent.back()
	check(ack_reply.type == "schedule_ack" and ack_reply.accepted == false and int(ack_reply.guest_tick) == late_tick, "late schedule is rejected with guest_tick")
	check(guest_fair.advance(wall + 500000, 4) == 0, "guest pauses at reschedule barrier until rescheduled packet arrives")
	guest_fair.receive({"type": "schedule", "id": 11, "tick": late_tick + 3, "epoch_usec": wall + 50000, "commands": [{"team": 0, "seq": 50, "command": move}]})
	ack_reply = net.session.sent.back()
	check(ack_reply.type == "schedule_ack" and ack_reply.accepted == true and guest_fair._reschedule_barrier_tick == -1, "rescheduled packet clears barrier and preserves command")

	# Host side of reschedule_rejected
	net.is_host = true
	var host_resched := Fair.new()
	host_resched.setup(net)
	host_resched.timeline_ready = true
	host_resched.epoch_tick = net.tick
	host_resched.epoch_usec = wall
	host_resched.last_scheduled_tick = net.tick
	var cur_tick: int = net.tick
	host_resched.enqueue(move, 0, 60, cur_tick, cur_tick + 6)
	host_resched._schedule(wall)
	var first_sched_id: int = int(host_resched.in_flight.id)
	var first_sched_tick: int = int(host_resched.in_flight.tick)
	host_resched.receive({"type": "schedule_ack", "id": first_sched_id, "accepted": false, "guest_tick": first_sched_tick, "team": 1})
	check(net.tick == first_sched_tick and not host_resched.in_flight.is_empty() and int(host_resched.in_flight.tick) > first_sched_tick, "host steps to guest_tick and reschedules commands losslessly")
	net.tick = cur_tick

	# 5. AI lineage and manual priority
	net._frame_step = 0
	unit.set_meta("manual_command_revision", 0)
	unit.set_meta("manual_control_until_sim_time", -1.0)
	var context := CommandExecutionContext.new()
	context.match_state = net.match_state
	context.entities = net.entities
	context.team = Enums.Team.PLAYER
	context.civ = bootstrap.player_civ
	context.session_epoch = "fair-test"
	var original := {"op":"move", "unit_id":EntityRegistry.id_of(unit), "pos":move.pos, "command_id":"local-only", "session_epoch":"fair-test"}
	check(CommandExecutor.execute(original, context).ok, "AI uses ordinary player submission")
	var queued: Dictionary = net.fair.pending.back().duplicate(true)
	queued.erase("target")
	net.fair._begin({"tick":net.tick + 6, "commands":[queued]})
	check(unit.get_meta("ai_command_lineage", {}).get("command_id") == "local-only", "local observation retains lineage")
	check(net.submit_command(move), "player issues ordinary order")
	original.command_id = "response-during-manual-input"
	check(net.queue_ai_command(original, context).get("reason") == "manual_control_hold", "pending human input takes priority before transmission")

	# 6. Saturated frame fairness & overflow rejection
	var saturated := Fair.new()
	saturated.setup(net)
	saturated.timeline_ready = true
	saturated.epoch_tick = net.tick
	saturated.epoch_usec = wall
	saturated.input_delay_ticks = 3
	saturated.delay_schedule = [{"from_tick": 0, "ticks": 3}]
	for side in [0, 1]:
		for seq in range(1, 41): saturated.enqueue({"op": "stop", "unit_id": id}, side, seq, net.tick, net.tick + 3)
	saturated._schedule(wall)
	var counts := {0: 0, 1: 0}
	for item in saturated.in_flight.commands: counts[int(item.team)] += 1
	check(counts[0] == 31 and counts[1] == 31, "arrival order cannot monopolize a saturated frame")
	check(saturated.in_flight.get("rejected", []).size() == 18, "overflow commands travel in schedule rejected list")

	# 7. Real-time 100ms input budget across speeds
	for speed in [1.0, 2.0, 3.0, 4.0]:
		net.match_speed = speed
		var fixed := Fair.new()
		fixed.setup(net)
		fixed.rtt_usec = 400000
		check(fixed.input_delay_ticks == int(3 * speed) and fixed.delay_for_source(900) == int(3 * speed), "100ms input delay scales with game speed, independent of RTT")
		check(is_equal_approx(float(fixed.input_delay_ticks) / (30.0 * speed), 0.1), "1x/2x/3x/4x all retain the same real-time input budget")
	net.match_speed = 2.0

	# 8. Clock sampling isolation from world loading
	var clocks := Fair.new()
	clocks.setup(net)
	net._awaiting_keyframe = true
	check(not clocks._can_sample_clock(Time.get_ticks_usec()), "clock does not sample while awaiting keyframe")
	net._awaiting_keyframe = false
	net.synchronized = false
	check(not clocks._can_sample_clock(Time.get_ticks_usec()), "unsynchronized peers do not measure world loading as network delay")
	net.synchronized = true
	clocks._nonce = 7
	clocks._probes[7] = 1234
	clocks._clock_samples = [{"rtt": 1200000, "offset": 0}]
	clocks.reset_clock_sampling()
	check(clocks._probes.is_empty() and clocks._clock_samples.is_empty() and clocks._nonce == 7, "heavy world work discards in-flight samples without reusing nonces")
	check(not clocks._can_sample_clock(Time.get_ticks_usec()), "post-load cooldown excludes queued pre-load clock requests")
	var sent_count: int = net.session.sent.size()
	clocks.receive({"type": "clock_probe", "nonce": 9, "sent_usec": 1234})
	check(net.session.sent.size() == sent_count, "queued probes are not answered immediately after a loading stall")
	clocks._clock_resume_usec = 0
	clocks.receive({"type": "clock_reply", "nonce": 7, "sent_usec": 1234, "received_usec": 1234})
	check(clocks._clock_samples.is_empty(), "stale pre-load reply cannot poison the fresh RTT window")
	var real_sent := Time.get_ticks_usec() - 800000
	clocks._probes[8] = real_sent
	clocks.receive({"type": "clock_reply", "nonce": 8, "sent_usec": real_sent, "received_usec": real_sent + 400000})
	check(clocks._clock_samples.size() == 1 and clocks.rtt_usec >= 800000, "genuine high RTT after loading is still measured without a hard cap")

	# 9. Batch coalescing (submit_commands + AI begin_command_batch/end_command_batch)
	net.is_host = false
	var batch: Array = []
	for i in 65: batch.append({"op": "move", "unit_id": id, "pos": [target.x + i, target.y]})
	var before_batch: int = net.session.sent.size()
	var before_seq: int = net._local_input_seq
	check(net.submit_commands(batch), "large group splits into bounded batches")
	var packets: Array = net.session.sent.slice(before_batch)
	check(packets.size() == 2 and packets[0].commands.size() == 64 and packets[1].commands.size() == 1, "65 orders use two envelopes")
	check(packets[0].seq == before_seq + 1 and packets[1].seq == before_seq + 65 and packets[0].source_tick == packets[1].source_tick, "chunks keep common source and contiguous sequence order")

	# AI begin_command_batch coalesces multiple submit_command calls into one command_batch
	var ai_before: int = net.session.sent.size()
	net.begin_command_batch()
	check(net.submit_command(move) and net.submit_command({"op": "stop", "unit_id": id}), "AI batch accepts individual submit_command calls")
	check(net.session.sent.size() == ai_before, "commands buffer until end_command_batch")
	net.end_command_batch()
	check(net.session.sent.size() == ai_before + 1 and net.session.sent.back().commands.size() == 2, "end_command_batch flushes one combined batch")

	net.is_host = true
	net.fair = Fair.new()
	net.fair.setup(net)
	var routed: Dictionary = packets[0].duplicate(true)
	routed.team = 1
	net._on_message(routed)
	check(net.fair.pending.size() == 64 and net._command_sequences[1] == before_seq + 64, "host expands batch into individually ordered pending commands")
	net._on_message(routed)
	check(net.fair.pending.size() == 64, "replayed batch cannot enqueue duplicates")

	scene.queue_free()
	await process_frame
	print("ONLINE FAIR: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
