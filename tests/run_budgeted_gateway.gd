extends SceneTree
## Full Gateway preparation through every transport path and real cancellable
## frame waiters, including lifecycle/generation/manual-control boundaries.
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Metrics := preload("res://scripts/ai_gateway/ai_gateway_metrics.gd")
const Parser := preload("res://scripts/ai_gateway/llm_response_parser.gd")
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const BuildingView := preload("res://scenes/entities/building_view.tscn")
const Civ := preload("res://data/civs/teutons.tres")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var entities: Node2D
var state: MatchState
var units: Array[UnitAgent] = []
var gateway_script: GDScript
var client_script: GDScript

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	root.get_node("GameSession").match_ai_mode = "sandbox"
	# AiConfig depends on the initialized autoload; load its client/gateway
	# subclasses after startup, just like the existing lifecycle fixtures.
	gateway_script = load("res://tests/fixtures/budgeted_gateway.gd")
	client_script = load("res://tests/fixtures/budgeted_ai_client.gd")
	_make_world()
	_test_synchronous_builders()
	for operation in ["tick", "chat", "multi", "tick_batch", "chat_batch"]:
		await _test_complete_payload(operation)
		await _test_stop_preparing(operation)
	await _test_restart_while_preparing()
	await _test_old_http_response()
	await _test_manual_during_preparation()
	await _test_deleted_entities()
	await _test_entities_exit()
	await _test_exit(false)
	await _test_exit(true)
	world.free()
	Events.clear()
	Registry.clear()
	check(checks >= 100, "every budgeted transport and lifecycle section completes")
	print("BUDGETED GATEWAY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _make_world() -> void:
	world = Node2D.new()
	root.add_child(world)
	entities = Node2D.new()
	world.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.fog_enabled = false
	state.map_bounds = Rect2(-32, -32, 64, 64)
	for team in 2:
		for index in 3:
			var unit := UnitView.instantiate() as UnitAgent
			unit.def = GameCatalog.get_unit(&"villager")
			unit.civ = Civ
			unit.team = team
			unit.match_state = state
			unit.sim_pos = Vector2(-15 + team * 30 + index, -12 + team * 24)
			entities.add_child(unit)
			unit.set_physics_process(false)
			units.append(unit)
		var building := BuildingView.instantiate() as BuildingAgent
		building.def = GameCatalog.get_building(&"town_center")
		building.civ = Civ
		building.team = team
		building.match_state = state
		building.sim_pos = Vector2(-20 + team * 40, -20 + team * 40)
		entities.add_child(building)

func _new_gateway(operation: String):
	var gateway = gateway_script.new()
	root.add_child(gateway)
	gateway.set_process(false)
	gateway.match_state = state
	gateway.entities = entities
	gateway.match_id = "budgeted_gateway"
	gateway.match_time = 10
	gateway._generation = 7
	gateway._remote_session_ended = true
	gateway.service_status = "online"
	gateway.config = load("res://scripts/ai_gateway/ai_config.gd").new()
	gateway.config.use_local_embedded = false
	gateway.config.protocol = "v3_multi_agent" if operation == "multi" else ("v2_chat" if operation.begins_with("chat") else "v1_tick")
	gateway.config.multi_agent_enabled = false
	gateway.config.use_tick_batch = operation.ends_with("batch")
	gateway.metrics = Metrics.new()
	for team in (2 if operation.ends_with("batch") else 1):
		gateway._teams.append({"team": team, "enemy_team": 1 - team, "civ": Civ})
		var context := Context.new()
		context.match_state = state
		context.entities = entities
		context.team = team
		context.civ = Civ
		context.session_epoch = "7"
		context.require_session_epoch = operation == "multi"
		context.sim_time = 10
		gateway._exec_contexts[team] = context
	var client = client_script.new()
	gateway.add_child(client)
	gateway._http_client = client
	gateway._event_subscriber = Events.subscribe()
	return gateway

func _launch(gateway, sequence: int, captured: Dictionary) -> void:
	captured.done = false
	await gateway._run_tick_requests(sequence)
	captured.done = true

func _wait_for(predicate: Callable, label: String) -> bool:
	var started := Time.get_ticks_msec()
	while not predicate.call() and Time.get_ticks_msec() - started < 4000:
		await process_frame
	var completed := bool(predicate.call())
	check(completed, label)
	return completed

func _observations(payload: Dictionary) -> Array:
	if payload.has("requests"):
		return payload.requests.map(func(request): return request.observation)
	return [payload.observation]

func _check_payload(request: Dictionary, operation: String) -> void:
	check(request.operation == operation, "%s uses the intended transport" % operation)
	var payload: Dictionary = request.payload
	var observations := _observations(payload)
	check(observations.size() == (2 if operation.ends_with("batch") else 1), "%s sends every team's complete observation" % operation)
	for observation: Dictionary in observations:
		for key in ["economy", "derived", "entities", "decision_context", "capabilities", "victory_conditions"]:
			check(observation.has(key), "%s sends final observation field %s" % [operation, key])
		for key in ["catalog", "construction_options", "scouting", "army", "defense_options"]:
			check(observation.decision_context.has(key), "%s sends completed planning stage %s" % [operation, key])
		check(observation.entities.size() >= 6, "%s serializes the fixture entities before sending" % operation)
	var requests: Array = payload.requests if payload.has("requests") else [payload]
	for entry: Dictionary in requests:
		var observed_time := float(entry.observation.derived.match_time_sec)
		var metadata: Dictionary = entry.get("metadata", entry)
		check(is_equal_approx(float(metadata.time_sec), observed_time), "%s metadata preserves its observation-start timestamp across frame yields" % operation)

func _test_synchronous_builders() -> void:
	var gateway = _new_gateway("multi")
	var tick_payload: Dictionary = gateway._build_tick_payload(gateway._teams[0], 0, [])
	var chat_payload: Dictionary = gateway._build_chat_payload(gateway._teams[0], 0, [])
	var multi_payload: Dictionary = gateway._build_multi_agent_payload(gateway._teams[0], 0, [])
	check(tick_payload.has("observation") and chat_payload.has("messages") and multi_payload.has("metadata"), "legacy private payload builders still return immediate Dictionaries")
	check(gateway.audit.waits == 0 and gateway._http_client.calls == 0, "synchronous payload compatibility does not allocate frame waiters or send HTTP")
	gateway.free()

func _test_complete_payload(operation: String) -> void:
	var gateway = _new_gateway(operation)
	var client = gateway._http_client
	var captured := {}
	_launch(gateway, 1, captured)
	check(gateway.audit.waits > 0 and not captured.done and gateway._request_in_flight, "%s snapshot yields while remaining in flight" % operation)
	check(client.calls == 0, "%s never sends partial preparation before its first await" % operation)
	gateway.match_time = 10.5
	if await _wait_for(func(): return client.calls > 0, "%s completes budgeted preparation" % operation):
		_check_payload(client.requests[0], operation)
		check(gateway.audit.pending == 0 and gateway.audit.resumed == gateway.audit.waits, "%s preparation completes every frame waiter before HTTP" % operation)
	gateway.stop()
	check(captured.done and client._frame_waiters.is_empty(), "%s stop unwinds the held response synchronously" % operation)
	gateway.free()

func _test_stop_preparing(operation: String) -> void:
	var gateway = _new_gateway(operation)
	var client = gateway._http_client
	var captured := {}
	_launch(gateway, 2, captured)
	check(client.calls == 0 and gateway.audit.pending == 1, "%s cancellation fixture waits inside preparation" % operation)
	gateway.stop()
	check(captured.done and gateway.audit.pending == 0, "%s stop fully unwinds snapshot before returning" % operation)
	check(client.calls == 0 and client._frame_waiters.is_empty(), "%s cancelled snapshot never sends an incomplete payload" % operation)
	check(gateway.metrics.tick_success_count == 0 and gateway.last_tick_latency_ms == -1, "%s cancelled preparation leaves response metrics untouched" % operation)
	gateway.free()
	await process_frame

func _test_restart_while_preparing() -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	var old := {}
	_launch(gateway, 3, old)
	gateway.stop()
	gateway.enabled = true
	gateway.service_status = "online"
	gateway._event_subscriber = Events.subscribe()
	var current := {}
	_launch(gateway, 4, current)
	check(old.done and not current.done and gateway._request_in_flight, "new preparation survives the cancelled generation's unwind")
	if await _wait_for(func(): return client.calls == 1, "restart sends its current completed snapshot"):
		check(client.requests[0].payload.tick == 4, "stopped preparation never races the restarted request")
	gateway.stop()
	check(current.done, "restart cleanup fully unwinds the new request")
	gateway.free()

func _test_old_http_response() -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	client.release_on_cancel = false
	var old := {}
	_launch(gateway, 5, old)
	if not await _wait_for(func(): return client.calls == 1, "old generation reaches a deliberately late transport"):
		gateway.stop()
		gateway.free()
		return
	var old_ticket = client.requests[0].ticket
	gateway.stop()
	gateway.enabled = true
	gateway.service_status = "online"
	gateway._event_subscriber = Events.subscribe()
	var current := {}
	_launch(gateway, 6, current)
	old_ticket.finish({"team": 0, "for_tick": 5, "commands": []})
	check(old.done and not current.done and gateway._request_in_flight, "late old response cannot clear the new preparation's busy flag")
	check(gateway.metrics.tick_success_count == 0 and gateway._pending_responses.is_empty(), "late old response cannot mutate current queue or success metrics")
	client.release_on_cancel = true
	gateway.stop()
	check(current.done, "new preparation cancels after old transport completion")
	gateway.free()

func _test_manual_during_preparation() -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	var captured := {}
	_launch(gateway, 7, captured)
	var observed_revision := Registry.manual_revision
	var command := {"op": "move", "unit_id": Registry.id_of(units[0]), "pos": [-8, -6]}
	Registry.report_manual_command(command, 0)
	check(Registry.manual_revision > observed_revision, "manual command arrives during the yielded snapshot")
	if await _wait_for(func(): return client.calls == 1, "manual-control fixture completes preparation"):
		check(gateway._exec_contexts[0].observed_manual_revision == observed_revision, "prepared request retains the manual-control fence from before its yield")
		var ai_command := command.duplicate(true)
		ai_command.command_id = "budgeted_before_manual"
		client.requests[0].ticket.finish({"team": 0, "for_tick": 7, "commands": [ai_command]})
		gateway._execute_due_commands(8)
		check(units[0].order != Enums.OrderType.MOVE, "reply from before manual control cannot override the human order fence")
	gateway.stop()
	gateway.free()

func _test_deleted_entities() -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	var temporary := UnitView.instantiate() as UnitAgent
	temporary.def = GameCatalog.get_unit(&"villager")
	temporary.team = 0
	temporary.civ = Civ
	temporary.match_state = state
	temporary.sim_pos = Vector2(-4, -4)
	entities.add_child(temporary)
	temporary.set_physics_process(false)
	var removed_id := Registry.id_of(temporary)
	var captured := {}
	_launch(gateway, 8, captured)
	temporary.free()
	if await _wait_for(func(): return client.calls == 1, "deleted entity does not break resumed preparation"):
		var observation: Dictionary = client.requests[0].payload.observation
		check(not observation.entities.any(func(record): return record.id == removed_id), "deleted-before-serialization entity is omitted from the sent snapshot")
	gateway.stop()
	gateway.free()

func _test_exit(queued: bool) -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	var audit: Dictionary = gateway.audit
	var captured := {}
	_launch(gateway, 9, captured)
	check(audit.pending == 1 and client.calls == 0, "exit fixture suspends before the transport")
	if queued:
		gateway.queue_free()
		await process_frame
		await process_frame
	else:
		gateway.free()
	check(captured.done and audit.pending == 0 and audit.waits == audit.resumed, "%s fully unwinds budget waiters before Node destruction" % ("queue_free" if queued else "free"))

func _test_entities_exit() -> void:
	var gateway = _new_gateway("tick")
	var client = gateway._http_client
	var temporary_entities := Node2D.new()
	world.add_child(temporary_entities)
	var temporary_unit := UnitView.instantiate() as UnitAgent
	temporary_unit.def = GameCatalog.get_unit(&"villager")
	temporary_unit.civ = Civ
	temporary_unit.match_state = state
	temporary_unit.sim_pos = Vector2(-4, -4)
	temporary_entities.add_child(temporary_unit)
	temporary_unit.set_physics_process(false)
	gateway.entities = temporary_entities
	Events.push({"type": "budgeted_entities_exit", "_visible_to": [0]})
	var captured := {}
	_launch(gateway, 10, captured)
	check(gateway.audit.pending == 1, "entity-container exit occurs during observation preparation")
	temporary_entities.free()
	await process_frame
	await process_frame
	check(captured.done and gateway.audit.pending == 0 and client.calls == 0, "freed entity container cancels every preparation waiter without sending HTTP")
	check(Events.peek(gateway._event_subscriber).events.any(func(event): return event.type == "budgeted_entities_exit"), "unsent observation does not acknowledge its event snapshot")
	gateway.stop()
	gateway.free()
