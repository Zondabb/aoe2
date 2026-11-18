extends SceneTree
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Fair := preload("res://scripts/network/fair_lockstep.gd")
var checks := 0
var failures: Array[String] = []

class Transport extends Node:
	var sent: Array = []
	var host_team := 0
	func send_fair_message(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
		return true
	func send_command_batch(commands: Array, seq: int, source: int, target: int) -> bool:
		sent.append({"type": "command_batch", "seq": seq, "source_tick": source, "execute_tick": target, "commands": commands.duplicate(true)})
		return true
	func leave() -> void: pass
	func send_frame(_tick: int, _commands: Array, _hash: String, _results: Array = []) -> bool: return true
	func finish_match(_winner: int) -> void: pass

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
	check(net.fair.enqueue(move, 0, 1, 0, delay), "host schedules future input")
	check(net.fair.enqueue({"op": "stop", "unit_id": net.entity_id(enemy)}, 1, 1, 0, delay), "guest receives identical future tick rule")
	check(not net.fair.enqueue(move, 1, 99, 0, 1), "guest cannot request a shorter input window")
	check(not net.fair.enqueue(move, 0, 99, 0, 1), "host obeys the same minimum input window")
	check(not net.fair.enqueue(move, 0, 2, 0, 0), "past execution rejected for host")
	check(not net.fair.enqueue(move, 1, 2, 0, 0), "past execution rejected for guest")
	net.fair._prepare()
	check(net.simulation.checksum() == before, "preparing inputs executes nothing")
	net.fair._commit(Time.get_ticks_usec())
	check(net.fair.commits.is_empty(), "host cannot commit before guest receives the plan")
	net.fair.ready_tick = net.fair.planned_tick
	var now := Time.get_ticks_usec()
	net.fair._commit(now)
	check(not net.fair.commits.is_empty(), "received plans get common execution deadlines")
	net._guest_ack_tick = 0
	check(net.fair.advance(now, 2) == 0 and net.tick == 0, "neither command nor simulation advances ahead of deadline")
	var deadline: int = net.fair.commits[3].execute_at_usec
	check(net.fair.advance(deadline, 2) == 1, "first fixed step starts at the scheduled deadline")
	check(net.tick == 0 and net._frame_step == 1, "remaining fixed steps retain their cadence")
	check(net.simulation.checksum() != before, "only actual scheduled simulation advances game state")
	# Prepared AI commands retain their own lineage and cannot overwrite an
	# intervening human order. They must not be reported as manual commands.
	net._frame_step = 0
	# The three-tick mode already executed the earlier manual order. Reset its
	# takeover hold before testing independent fresh AI command lineage.
	unit.set_meta("manual_command_revision", 0)
	unit.set_meta("manual_control_until_sim_time", -1.0)
	var context := CommandExecutionContext.new()
	context.match_state = net.match_state
	context.entities = net.entities
	context.team = Enums.Team.PLAYER
	context.civ = bootstrap.player_civ
	context.session_epoch = "fair-test"
	var original := {"op": "move", "command_id": "fair-ai-1", "session_epoch": "fair-test", "task_id": "scout"}
	check(net.fair.enqueue_ai(move, context, original).ok, "AI enters the same future input pipeline")
	check(not net.fair.enqueue_ai(move, context, original).ok, "pending AI ID cannot be enqueued twice")
	var stale: Dictionary = net.fair.pending.back().duplicate(true)
	stale.erase("target")
	net.fair._generations[id] = 1
	var previous_order: String = net.simulation.checksum()
	net.fair._begin({"tick": delay, "commands": [stale]})
	check(net.simulation.checksum() == previous_order, "AI prepared before a human order is a deterministic no-op")
	original.command_id = "fair-ai-2"
	check(net.fair.enqueue_ai(move, context, original).ok, "fresh AI generation can queue")
	var fresh: Dictionary = net.fair.pending.back().duplicate(true)
	fresh.erase("target")
	var manual_revision := int(unit.get_meta("manual_command_revision", 0))
	net.fair._begin({"tick": delay, "commands": [fresh]})
	check(unit.get_meta("ai_command_lineage", {}).get("command_id") == "fair-ai-2", "confirmed AI preserves task lineage for observations")
	check(int(unit.get_meta("manual_command_revision", 0)) == manual_revision, "scheduled AI is never a manual takeover")
	# Saturated frame slots are split between teams even if one arrived first.
	var saturated := Fair.new()
	saturated.setup(net)
	saturated.input_delay_ticks = 3
	saturated.delay_schedule = [{"from_tick": 0, "ticks": 3}]
	for side in [0, 1]:
		for seq in range(1, 41): saturated.enqueue({"op": "stop", "unit_id": id}, side, seq, 0, 3)
	saturated._prepare()
	var counts := {0: 0, 1: 0}
	for item in saturated.plans[3].commands: counts[int(item.team)] += 1
	check(counts[0] == 31 and counts[1] == 31, "arrival order cannot monopolize a saturated frame")
	check(saturated.rejected.size() == 18, "overflow commands receive explicit results")
	# A clock-calibrated startup is the only receipt barrier. Later plans and
	# deadlines travel together, even if the next receipt has not returned yet.
	net.tick = 0
	net._frame_step = 0
	net.match_speed = 2.0
	var pipeline := Fair.new()
	pipeline.setup(net)
	pipeline._prepare()
	pipeline.ready_tick = pipeline.planned_tick
	pipeline._commit(now)
	var first_commit: int = pipeline.committed_tick
	net.tick = 3
	pipeline._prepare()
	pipeline._commit(now + 50000)
	check(pipeline.committed_tick > first_commit and pipeline.ready_tick == first_commit, "steady state commits without another round trip")
	check(net.session.sent.back().type == "input_step" and not net.session.sent.back().has("timing"), "steady frame combines commands and deadline without repeating settings")
	var sent_step: Dictionary = net.session.sent.back().duplicate(true)
	var sent_before: int = net.session.sent.size()
	pipeline.resend()
	var replays: Array = net.session.sent.slice(sent_before)
	check(sent_step in replays, "recovery replays immutable combined packets")
	# Guest consumption, one receipt per synchronization, and snapshot recovery.
	net.is_host = false
	net.tick = int(sent_step.tick) - 3
	var compact := Fair.new()
	compact.setup(net)
	compact.clock_ready = true
	var before_step: String = net.simulation.checksum()
	compact.receive(sent_step)
	check(compact.committed_tick == sent_step.tick and compact.plans.has(int(sent_step.tick)), "combined frame installs plan and deadline atomically")
	check(net.simulation.checksum() == before_step, "receiving combined frame does not execute it")
	var after_first_receipt: int = net.session.sent.size()
	compact.receive(sent_step)
	compact._ack_plans()
	check(net.session.sent.size() == after_first_receipt, "duplicate frames and clock samples do not repeat preparation ACKs")
	var next_step := {"type": "input_step", "tick": int(sent_step.tick) + 3, "execute_at_usec": int(sent_step.execute_at_usec) + 50000, "commands": []}
	compact.receive(next_step)
	check(net.session.sent.size() == after_first_receipt, "steady frame emits no preparation ACK")
	compact.reset(int(sent_step.tick))
	compact.receive(next_step)
	check(net.session.sent.size() == after_first_receipt + 1 and compact.committed_tick == next_step.tick, "recovery accepts combined replay and acknowledges once")
	net.is_host = true
	# Changing the timing policy is announced once, while unchanged policies
	# stay absent from subsequent frames; the snapshot carries the full history.
	net.tick = int(next_step.tick)
	pipeline.delay_schedule.append({"from_tick": net.tick + 30, "ticks": 9})
	var before_policy: int = net.session.sent.size()
	pipeline._prepare()
	pipeline._commit(now + 150000)
	var announcements: Array = net.session.sent.slice(before_policy).filter(func(packet: Dictionary): return packet.has("timing"))
	check(announcements.size() == 1 and announcements[0].timing.input_delay_ticks == 9, "changed timing is included once in the combined frame")
	net.tick += 3
	pipeline._prepare()
	pipeline._commit(now + 200000)
	check(not net.session.sent.back().has("timing"), "unchanged timing is omitted again after announcement")
	# The same real-time budget scales ticks with the configured game speed.
	for speed in [1.0, 2.0, 3.0, 4.0]:
		net.match_speed = speed
		var fixed := Fair.new()
		fixed.setup(net)
		fixed.rtt_usec = 400000
		check(fixed.input_delay_ticks == int(3 * speed) and fixed.delay_for_source(900) == int(3 * speed), "100ms input delay scales with game speed, independent of RTT")
		check(is_equal_approx(float(fixed.input_delay_ticks) / (30.0 * speed), 0.1), "1x/2x/3x/4x all retain the same real-time input budget")
	net.match_speed = 2.0
	# Source rules still validate older packets even with independent lookahead.
	net.tick = 84
	var transition := Fair.new()
	transition.setup(net)
	transition.rtt_usec = 1000
	transition.delay_schedule = [{"from_tick": 0, "ticks": 18}, {"from_tick": 90, "ticks": 6}]
	transition.input_delay_ticks = 18
	transition._prepare()
	check(transition.planned_tick == 90, "transport lookahead is independent of a shorter input window")
	check(transition.enqueue(move, 0, 100, 84, 102), "old in-flight host input keeps its source rule")
	check(transition.enqueue(move, 1, 100, 84, 102), "old in-flight guest input keeps the same source rule")
	check(transition.enqueue(move, 1, 101, 90, 96), "new input uses the announced shorter window")
	check(not transition.enqueue(move, 0, 102, 84, 90), "host cannot apply a lower delay early")
	check(not transition.enqueue(move, 1, 102, 84, 90), "guest cannot apply a lower delay early")
	var timing := {"generations": {}, "controls": {"0": 0, "1": 0}, "input_delay_ticks": 18, "speed": 2.0, "delay_schedule": transition.delay_schedule.duplicate(true)}
	check(net._valid_fair_state(timing), "keyframes preserve old and future timing policies")
	timing.delay_schedule[1].from_tick = 0
	check(not net._valid_fair_state(timing), "keyframes reject ambiguous policy history")
	var short_window := Fair.new()
	short_window.setup(net)
	short_window.rtt_usec = 400000
	short_window._clock_samples = [{"rtt": 400000}, {"rtt": 400000}]
	check(short_window.delay_for_source(1000) == 6, "high RTT cannot enlarge the 100ms input budget")
	short_window.planned_tick = 108
	for side in [0, 1]:
		check(short_window.enqueue(move, side, 201, 90, 96), "both teams defer a late valid command instead of dropping it")
		check(int(short_window.pending.back().target) == 111, "late command goes to the first open frame")
		check(short_window.enqueue(move, side, 202, 93, 99), "subsequent command remains ordered")
		check(int(short_window.pending.back().target) >= int(short_window.pending[-2].target), "late commands cannot invert sequence order")
	short_window.planned_tick = 300
	check(not short_window.enqueue(move, 1, 203, 90, 96), "extremely stale input remains bounded")
	# At 2x, keep 60 simulation steps/sec even across a 160ms RTT link.
	net.tick = 0
	var paced := Fair.new()
	paced.setup(net)
	paced.rtt_usec = 160000
	paced._prepare()
	check(paced.planned_tick >= 9 and paced.input_delay_ticks == 6, "network buffers enough frames without enlarging the input rule")
	paced.ready_tick = paced.planned_tick
	var wall := 1000000
	paced._commit(wall)
	var initial_deadline := int(paced.commits[3].execute_at_usec)
	for frame in range(1, 41):
		var target_tick := frame * 3
		var due := initial_deadline + (frame - 1) * 50000
		check(int(paced.commits[target_tick].execute_at_usec) == due, "committed cadence stays at 50ms regardless of RTT")
		net.tick = target_tick
		paced._prepare()
		paced._commit(due + 40000)
	var immutable: Dictionary = paced.plans[paced.planned_tick].duplicate(true)
	var sampled_source: int = net.tick
	check(paced.enqueue(move, 1, 300, sampled_source, sampled_source + 6), "input arriving behind transport lookahead is preserved")
	check(paced.plans[paced.planned_tick] == immutable and int(paced.pending.back().target) > paced.planned_tick, "late input cannot overwrite an already published frame")
	var clocks := Fair.new()
	clocks.setup(net)
	net._guest_ack_tick = -1
	check(not clocks._can_sample_clock(Time.get_ticks_usec()), "host does not measure RTT while the guest loads its initial world")
	net._guest_ack_tick = 0
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
	var unchanged_position := unit.position
	var unchanged_state: String = net.simulation.checksum()
	check(net.submit_command(move), "runtime accepts a delayed order for a future execution frame")
	check(unit.position == unchanged_position and net.simulation.checksum() == unchanged_state, "submitting in delay-only mode changes no gameplay state or presentation")
	net.is_host = false
	var batch: Array = []
	for i in 65: batch.append({"op": "move", "unit_id": id, "pos": [target.x + i, target.y]})
	var before_batch: int = net.session.sent.size()
	var before_seq: int = net._local_input_seq
	check(net.submit_commands(batch), "large group splits into bounded batches")
	var packets: Array = net.session.sent.slice(before_batch)
	check(packets.size() == 2 and packets[0].commands.size() == 64 and packets[1].commands.size() == 1, "65 orders use two envelopes")
	check(packets[0].seq == before_seq + 1 and packets[1].seq == before_seq + 65 and packets[0].source_tick == packets[1].source_tick, "chunks keep common source and contiguous sequence order")
	check(net.simulation.checksum() == unchanged_state, "batch submission never executes early")
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
