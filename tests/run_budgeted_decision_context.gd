extends SceneTree
## Default callers stay synchronous; optional frame slices never expose partial
## decisions and must tolerate scene/actor destruction at each boundary.
const Decision := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")

var checks := 0
var failures := 0
var world: Node2D
var entities: Node2D
var state: MatchState
var snapshots: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	# Stop simulation while retaining normal planning/unlock rules. Frame yields
	# still occur, so byte equality verifies the complete staged orchestration.
	world.process_mode = Node.PROCESS_MODE_DISABLED
	state = world.get_node("Bootstrap").match_state
	entities = world.get_node("Entities")
	for team in 2:
		state.set_age(team, 1)
		for type in 4: state.resources[team][type] = 10000
	state.fog.rebuild(entities.get_children())
	for team in 2:
		snapshots[team] = Observation.build(state, entities, team, 1 - team, 240.0)
		for defense_only in [false, true]: await _test_frozen(team, defense_only)
	await _test_list_lifetimes()
	await _test_cancellation()
	await _test_detached_and_freed_scene()
	await _test_actor_deletion()
	check(checks >= 25, "all context scheduling sections ran")
	print("BUDGETED DECISION CONTEXT: %d checks, %d failures" % [checks, failures])
	world.free()
	quit(0 if failures == 0 else 1)

func _test_frozen(team: int, defense_only: bool) -> void:
	var observation: Dictionary = snapshots[team]
	var immediate: Variant = Decision.build(state, entities, team, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, defense_only)
	check(immediate is Dictionary, "legacy build immediately returns a Dictionary without await")
	var counts := {"frames": 0}
	var next_frame := func() -> bool:
		counts.frames += 1
		await process_frame
		return true
	var staged := await Decision.build_budgeted(state, entities, team, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, defense_only, next_frame, 50)
	check(counts.frames > 1, "small positive budget yields across multiple boundaries")
	check(JSON.stringify(Protocol.json_safe(staged)).to_utf8_buffer() == JSON.stringify(Protocol.json_safe(immediate)).to_utf8_buffer(), "frozen full/defense context bytes equal synchronous planning for team %d" % team)
	var disabled_count := {"calls": 0}
	var forbidden := func() -> bool:
		disabled_count.calls += 1
		return false
	var disabled := await Decision.build_budgeted(state, entities, team, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, defense_only, forbidden, 0)
	check(disabled_count.calls == 0 and JSON.stringify(disabled) == JSON.stringify(immediate), "zero budget never invokes callback and preserves context")

func _test_list_lifetimes() -> void:
	var active := Node2D.new()
	var queued := Node2D.new()
	var freed := Node2D.new()
	entities.add_child(active)
	entities.add_child(queued)
	entities.add_child(freed)
	var own: Array[Node2D] = [active, queued, freed]
	var builders: Array[Node2D] = own.duplicate()
	var known: Array = own.duplicate()
	var placement: Array = own.duplicate()
	freed.free()
	queued.queue_free()
	var during := {"pruned": false}
	var destroy_active := func() -> bool:
		during.pruned = own.size() == 1 and builders.size() == 1 and known.size() == 1 and placement.size() == 1
		active.free()
		await process_frame
		return true
	var budget := Decision.PreparationBudget.new(destroy_active, 1, entities, [own, builders, known, placement])
	budget.started_usec = Time.get_ticks_usec() - 10
	check(await budget.checkpoint(), "deleting actors at a boundary keeps a live scene usable")
	check(during.pruned, "all four node lists are pruned before yielding")
	check(own.is_empty() and builders.is_empty() and known.is_empty() and placement.is_empty(), "all four node lists are pruned after yielding")

func _test_cancellation() -> void:
	var observation: Dictionary = snapshots[1]
	var calls := {"count": 0}
	var cancel := func() -> bool:
		calls.count += 1
		await process_frame
		return false
	var result := await Decision.build_budgeted(state, entities, 1, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, false, cancel, 1)
	check(calls.count == 1 and result.is_empty(), "cancelled frame callback returns no partial decision context")

func _test_detached_and_freed_scene() -> void:
	var observation: Dictionary = snapshots[1]
	for mode in ["detach", "queue_free", "free"]:
		var temporary := Node2D.new()
		root.add_child(temporary)
		var stop_scene := func() -> bool:
			if mode == "detach": root.remove_child(temporary)
			elif mode == "queue_free": temporary.queue_free()
			else: temporary.free()
			await process_frame
			return true
		var result := await Decision.build_budgeted(state, temporary, 1, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, false, stop_scene, 1)
		check(result.is_empty(), mode + " during callback safely cancels planning")
		if is_instance_valid(temporary): temporary.free()

func _test_actor_deletion() -> void:
	var observation: Dictionary = snapshots[1]
	var deleted := {"done": false}
	var kill_actors := func() -> bool:
		if not deleted.done:
			deleted.done = true
			for actor in entities.get_children():
				if actor is UnitAgent and actor.team == 1: actor.free()
			var old_holder: Variant = world.get_meta("fog_holder", null)
			if is_instance_valid(old_holder): old_holder.free()
		await process_frame
		return true
	var result := await Decision.build_budgeted(state, entities, 1, observation.entities, observation.derived, Observation.DEFAULT_DEFEND_RADIUS, false, kill_actors, 128)
	check(deleted.done and result.has("army") and result.has("scouting"), "actors/fog holder can disappear between collection slices without script errors")
	check(result.construction_options.is_empty() and result.defense_options.is_empty(), "deleted builders cannot be offered as construction options")
	check(result.army.ready_unit_ids.is_empty() and result.army.scout_ids.is_empty(), "deleted own units do not survive the collected actor lists")
