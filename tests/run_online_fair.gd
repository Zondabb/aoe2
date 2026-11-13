extends SceneTree
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Fair := preload("res://scripts/network/fair_lockstep.gd")
const Prediction := preload("res://scripts/network/client_prediction.gd")
var checks := 0
var failures: Array[String] = []

class Transport extends Node:
	var sent: Array = []
	var host_team := 0
	func send_fair_message(message: Dictionary) -> bool:
		sent.append(message.duplicate(true))
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
	net.is_host = true
	net._playing = true
	net.synchronized = true
	net.session = Transport.new()
	scene.add_child(net.session)
	net.simulation = Simulation.new()
	net.simulation.setup(net)
	net.fair = Fair.new()
	net.fair.setup(net)
	net.prediction = Prediction.new()
	scene.add_child(net.prediction)
	net.prediction.setup(net)
	net.prediction.set_process(false)
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
	check(net.prediction.submit(1, move), "own movement predicts immediately")
	# Avoid terrain layout dependency here; the live E2E retains navigation.
	net.prediction._nav = null
	net.prediction.advance(0.1)
	check(unit.sim_pos == origin and net.simulation.checksum() == before, "prediction cannot mutate position or any simulation field")
	check(unit.render_global_transform(unit).origin != unit.global_position, "visual transform advances independently")
	check(net.prediction.submit(2, {"op": "stop", "unit_id": id}), "later stop replaces movement preview")
	net.prediction.resolve(1, true)
	check(net.prediction.pending.has(2) and not net.prediction._motions[id].returning, "old confirmation cannot clear latest command")
	net.prediction.resolve(2, false)
	for i in 40: net.prediction.advance(0.05)
	check(not unit._prediction_presentation_active and net.prediction.pending.is_empty(), "rejection smoothly reconciles to actual position")
	check(not net.prediction.submit(3, {"op": "move", "unit_id": net.entity_id(enemy), "pos": [0, 0]}), "enemy cannot be predicted")
	net.spectator = true
	check(not net.prediction.submit(4, move), "spectators cannot predict")
	net.spectator = false
	check(net.prediction.submit(5, move), "prediction resumes for active player")
	net.prediction.advance(4.0)
	check(net.prediction.pending.is_empty(), "lost confirmations expire bounded previews")
	net.prediction.clear()
	check(net.simulation.checksum() == before, "timeout and correction preserve the full authoritative state")

	var delay: int = net.fair.input_delay_ticks
	check(net.fair.enqueue(move, 0, 1, 0, delay), "host schedules future input")
	check(net.fair.enqueue({"op": "stop", "unit_id": net.entity_id(enemy)}, 1, 1, 0, delay), "guest receives identical future tick rule")
	check(not net.fair.enqueue(move, 1, 99, 0, 3), "guest cannot request a shorter input window")
	check(not net.fair.enqueue(move, 0, 99, 0, 3), "host obeys the same minimum input window")
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
	# A shared future policy changes both sides' source-tick rule atomically.
	net.tick = 0
	var adaptive := Fair.new()
	adaptive.setup(net)
	check(adaptive.input_delay_ticks == 9, "2x startup input window is 150ms rather than 600ms")
	adaptive.rtt_usec = 1000
	adaptive._clock_samples = [{"rtt": 1000}, {"rtt": 1000}]
	adaptive._maybe_update_policy(1000000)
	check(adaptive.delay_schedule.size() == 1, "shrinking the input window requires stable samples")
	adaptive._maybe_update_policy(2000000)
	var policy: Dictionary = adaptive.delay_schedule.back()
	check(int(policy.ticks) == 6 and int(policy.from_tick) > adaptive.planned_tick, "low latency shrinks both sides to 100ms with advance notice")
	var replica := Fair.new()
	replica.setup(net)
	check(replica._receive_policy(int(policy.from_tick), int(policy.ticks)), "guest receives the future delay policy")
	for source in [int(policy.from_tick) - 3, int(policy.from_tick), int(policy.from_tick) + 3]:
		check(adaptive.delay_for_source(source) == replica.delay_for_source(source), "host and guest use the same source-tick policy")
	check(replica._receive_policy(int(policy.from_tick), int(policy.ticks)), "identical repeated policy is idempotent")
	check(not replica._receive_policy(int(policy.from_tick), 12), "an announced policy cannot be rewritten")
	check(not replica._receive_policy(3, 12), "out-of-order policy is rejected")
	var gradual := Fair.new()
	gradual.setup(net)
	gradual.input_delay_ticks = 18
	gradual.delay_schedule = [{"from_tick": 0, "ticks": 18}]
	gradual.rtt_usec = 1000
	gradual._clock_samples = [{"rtt": 1000}, {"rtt": 1000}]
	gradual._maybe_update_policy(1000000)
	gradual._maybe_update_policy(2000000)
	var boundary := int(gradual.delay_schedule.back().from_tick)
	check(gradual.delay_for_source(boundary) == 15, "each decrease is limited to one command frame")
	check(boundary + gradual.delay_for_source(boundary) >= boundary - 3 + gradual.delay_for_source(boundary - 3), "shorter delay cannot reverse successive command execution order")
	# Keep the old rule for packets still in flight, including when newer inputs
	# have a lower delay and therefore an earlier execution target.
	net.tick = 84
	var transition := Fair.new()
	transition.setup(net)
	transition.rtt_usec = 1000
	transition.delay_schedule = [{"from_tick": 0, "ticks": 18}, {"from_tick": 90, "ticks": 6}]
	transition.input_delay_ticks = 18
	transition._prepare()
	check(transition.planned_tick == 87, "decrease does not prematurely seal the upcoming shorter window")
	check(transition.enqueue(move, 0, 100, 84, 102), "old in-flight host input keeps its source rule")
	check(transition.enqueue(move, 1, 100, 84, 102), "old in-flight guest input keeps the same source rule")
	check(transition.enqueue(move, 1, 101, 90, 96), "new input uses the announced shorter window")
	check(not transition.enqueue(move, 0, 102, 84, 90), "host cannot apply a lower delay early")
	check(not transition.enqueue(move, 1, 102, 84, 90), "guest cannot apply a lower delay early")
	var timing := {"generations": {}, "controls": {"0": 0, "1": 0}, "input_delay_ticks": 18, "speed": 2.0, "delay_schedule": transition.delay_schedule.duplicate(true)}
	check(net._valid_fair_state(timing), "keyframes preserve old and future timing policies")
	timing.delay_schedule[1].from_tick = 0
	check(not net._valid_fair_state(timing), "keyframes reject ambiguous policy history")
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
	scene.queue_free()
	await process_frame
	print("ONLINE FAIR: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
