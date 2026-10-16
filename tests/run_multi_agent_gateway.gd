extends SceneTree
## v3 fast path, reliable event acknowledgement, private progress and receipts.

const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Metrics := preload("res://scripts/ai_gateway/ai_gateway_metrics.gd")
const UnitScene := preload("res://scenes/entities/unit_view.tscn")
const BuildingScene := preload("res://scenes/entities/building_view.tscn")
const Villager := preload("res://data/units/villager.tres")
const Civ := preload("res://data/civs/teutons.tres")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var entities: Node2D
var state: MatchState
var unit: UnitAgent
var ctx: CommandExecutionContext

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	_test_delivery()
	_test_privacy()
	world = Node2D.new()
	root.add_child(world)
	entities = Node2D.new()
	world.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-48, -48, 96, 96)
	unit = UnitScene.instantiate() as UnitAgent
	unit.def = Villager
	unit.civ = Civ
	unit.team = Enums.Team.PLAYER
	unit.match_state = state
	unit.sim_pos = Vector2(2, 2)
	entities.add_child(unit)
	unit.set_physics_process(false)
	ctx = Context.new()
	ctx.entities = entities
	ctx.match_state = state
	ctx.team = Enums.Team.PLAYER
	ctx.civ = Civ
	ctx.session_epoch = "7"
	ctx.require_session_epoch = true
	ctx.sim_time = 12.0
	await _test_fast_path()
	await _test_manual_inflight()
	await _test_shared_gateway_manual_boundary()
	_test_receipts_and_guards()
	_test_progress_and_manual()
	_test_config()
	world.free()
	Registry.clear()
	Events.clear()
	print("MULTI AGENT GATEWAY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_delivery() -> void:
	Events.clear()
	var consumer := Events.subscribe()
	Events.push({"type": "first"})
	var pending := Events.peek(consumer)
	check(pending.events.size() == 1 and not pending.gap, "new event delivery has no gap")
	check(Events.peek(consumer).events == pending.events, "peek/retry never consumes unacknowledged events")
	Events.push({"type": "while_http_in_flight"})
	Events.acknowledge(consumer, pending.to_seq)
	check(Events.peek(consumer).events.size() == 1 and Events.peek(consumer).events[0].type == "while_http_in_flight", "ack only removes the response's event snapshot")
	Events.acknowledge(consumer, 0)
	check(Events.peek(consumer).events.size() == 1, "stale acknowledgement cannot rewind the cursor")
	for index in Events.MAX_BUFFERED_EVENTS + 2:
		Events.push({"type": "overflow", "index": index})
	var overflow := Events.peek(consumer)
	check(overflow.gap and overflow.resync_required and overflow.events.size() == Events.MAX_BUFFERED_EVENTS, "slow consumer receives explicit bounded-buffer gap and resync requirement")
	Events.acknowledge(consumer, overflow.to_seq)
	check(Events.peek(consumer).events.is_empty() and not Events.peek(consumer).gap, "acknowledged resync clears only delivered gap")
	Events.unsubscribe(consumer)
	Events.clear()

func _test_privacy() -> void:
	var event := {"type": "entity_spawned", "_visible_to": [0, 1], "entity": {
		"id": 88, "team": 1, "kind": "building", "hp": 100,
		"production": {"queue_ids": [4]}, "research": {"technology_id": "secret"},
		"train_queue": ["secret"], "move_goal": [8, 9], "movement": {"path_pending": true}, "target_id": 999,
	}}
	var enemy: Dictionary = Events.for_team([event], 0, true)[0].entity
	check(enemy.hp == 100 and not enemy.has("production") and not enemy.has("research") and not enemy.has("train_queue"), "visible enemy spawn exposes appearance but hides private production/research")
	check(not enemy.has("move_goal") and not enemy.has("target_id") and not enemy.has("movement"), "enemy lifecycle event hides private orders and path state")
	check(Events.for_team([event], 1, true)[0].entity.has("production"), "owner retains private spawn state")
	check(event.entity.has("production"), "privacy projection does not mutate event shared by subscribers")
	check(Events.for_team([{"type": "human_command", "_visible_to": [0]}], 1, false).is_empty(), "manual order events stay private even without fog")

func _new_gateway():
	var gateway = load("res://scripts/ai_gateway/ai_gateway.gd").new()
	root.add_child(gateway)
	gateway.set_process(false)
	gateway.match_state = state
	gateway.entities = entities
	gateway.match_id = "v3_gateway_test"
	gateway.match_time = 12.0
	gateway._generation = 7
	gateway._remote_session_ended = true
	gateway.service_status = "online"
	gateway.config = load("res://scripts/ai_gateway/ai_config.gd").new()
	gateway.config.use_local_embedded = false
	gateway.config.backend = "openai"
	gateway.config.multi_agent_enabled = true
	gateway.config.tick_interval_sec = 10.0
	gateway.metrics = Metrics.new()
	gateway._teams.append({"team": 0, "enemy_team": 1, "civ": Civ})
	gateway._exec_contexts[0] = ctx
	var client = load("res://tests/fixtures/delayed_v3_client.gd").new()
	gateway.add_child(client)
	gateway._http_client = client
	gateway._event_subscriber = Events.subscribe()
	return gateway

func _response(sequence: int, commands: Array = []) -> Dictionary:
	return {"protocol_version": 3, "match_id": "v3_gateway_test", "team": 0,
		"session_epoch": "7", "for_tick": sequence, "acknowledged_observation_seq": sequence,
		"commands": commands, "agent_status": {"combat": {"state": "march"}}, "goals": {"victory": "destroy_enemy_tc"}}

func _move(id: String = "v3_move") -> Dictionary:
	return {"op": "move", "unit_id": Registry.id_of(unit), "pos": [8, 4],
		"command_id": id, "task_id": "scout-route", "session_epoch": "7", "expires_at_sim_time": 100.0}

func _test_fast_path() -> void:
	Events.clear()
	var gateway = _new_gateway()
	var client = gateway._http_client
	Events.push({"type": "receipt_to_retry", "_visible_to": [0]})
	gateway._run_tick_requests(1)
	check(client.calls == 1 and gateway._request_in_flight, "v3 starts exactly one asynchronous fast request")
	check(client.last_payload.messages.is_empty() and client.last_payload.tools.is_empty(), "fast request sends observation once without duplicating huge model prompts")
	check(client.last_payload.metadata.session_epoch == "7" and client.last_payload.metadata.observation_seq == 1, "request carries string session epoch and observation sequence")
	check(gateway._tick_interval() == 1.0, "v3 uses one-second loop independent of old ten-second tick")
	client.response = {}
	client.completed.emit()
	await process_frame
	check(not gateway._request_in_flight and Events.peek(gateway._event_subscriber).events.size() == 1, "HTTP failure keeps event unacknowledged for next observation")
	gateway._run_tick_requests(2)
	check(client.last_payload.events[0].type == "receipt_to_retry", "next request resends retained receipt")
	Events.push({"type": "new_event_during_request", "_visible_to": [0]})
	client.response = _response(2, [_move()])
	client.completed.emit()
	await process_frame
	check(unit.order == Enums.OrderType.MOVE and unit._requested_move_target == Vector2(8, 4), "valid v3 command executes immediately without another AI tick")
	check(gateway._pending_responses.is_empty(), "v3 avoids legacy delayed command queue")
	check(gateway.goals.get("victory") == "destroy_enemy_tc", "dictionary goals survive response parsing")
	var retained: Array = Events.peek(gateway._event_subscriber).events
	check(retained.size() == 2 and retained[0].type == "new_event_during_request" and retained[1].type == "command_result", "accepted response acknowledges old events while new event and generated receipt stay pending")
	check(retained[1].task_id == "scout-route" and retained[1].session_epoch == "7", "command result preserves task and string epoch lineage")
	gateway._run_tick_requests(3)
	client.response = _response(3, [_move("wrong_epoch")])
	client.response.session_epoch = "6"
	client.completed.emit()
	await process_frame
	check(not ctx.executed_command_ids.has("wrong_epoch") and not Events.peek(gateway._event_subscriber).events.is_empty(), "stale session response neither executes nor acknowledges events")
	gateway._run_tick_requests(4)
	client.response = _response(4, [_move("late_cancelled")])
	gateway.stop()
	client.completed.emit()
	await process_frame
	check(not ctx.executed_command_ids.has("late_cancelled") and gateway._event_subscriber == 0, "cancel immediately invalidates awaited v3 response and releases subscription")
	check(unit.order == Enums.OrderType.MOVE, "cancel takeover preserves orders already accepted by simulation")
	gateway.free()

func _test_receipts_and_guards() -> void:
	var expired := _move("expired")
	expired.expires_at_sim_time = 11.0
	check(Executor.execute(expired, ctx).reason == "command_expired", "late command deadline is checked at actual execution")
	var stale := _move("stale")
	stale.session_epoch = "7-trailing"
	check(Executor.execute(stale, ctx).reason == "stale_session_epoch", "epoch compares exact strings instead of integer prefix conversion")
	var missing := _move("missing")
	missing.erase("session_epoch")
	check(Executor.execute(missing, ctx).reason == "missing_session_epoch", "v3 commands require epoch lineage")
	var build := {"op": "place_building", "building_def_id": "house", "pos": [24, 24], "builder_id": Registry.id_of(unit), "command_id": "build-receipt", "task_id": "house-task", "session_epoch": "7"}
	var built := Executor.execute(build, ctx)
	check(built.ok and int(built.get("created_entity_id", -1)) > 0, "accepted placement returns actual created foundation ID")
	check(built.get("created_entity_id") == built.get("building_id"), "foundation receipt links build continuation to registered building")
	var foundation := Registry.resolve(int(built.get("created_entity_id", -1)))
	check(foundation != null and foundation.get_meta("ai_command_lineage", {}).get("task_id") == "house-task", "foundation retains originating construction task")
	var town := BuildingScene.instantiate() as BuildingAgent
	town.def = load("res://data/buildings/town_center.tres")
	town.team = Enums.Team.PLAYER
	town.civ = Civ
	town.match_state = state
	town.sim_pos = Vector2(-16, -16)
	entities.add_child(town)
	Registry.sample_owned_state(entities, 0, 12.0)
	var train := {"op": "train", "building_id": Registry.id_of(town), "unit_def_id": "villager", "command_id": "train-receipt", "task_id": "worker-task", "session_epoch": "7"}
	var trained := Executor.execute(train, ctx)
	town.set_physics_process(false)
	check(trained.ok and trained.get("queue_id") == town.train_queue_ids[-1], "training receipt returns stable queue ID")
	check(town.get_meta("ai_queue_lineage", {}).get(trained.get("queue_id"), {}).get("task_id") == "worker-task", "production queue retains request-to-task correlation")
	Events.clear()
	Registry.sample_owned_state(entities, 0, 13.0)
	var emitted := Events.for_team(Events.drain(), 0, false)
	check(emitted.any(func(event): return event.type == "production_state_changed" and event.production.state == "training"), "producer transition reports actual training state")
	Registry.report_manual_command({"op": "cancel_train", "building_id": Registry.id_of(town), "queue_id": trained.queue_id}, 0)
	var before := town.train_queue.size()
	train.command_id = "human_producer_guard"
	check(Executor.execute(train, ctx).reason == "manual_control_hold" and town.train_queue.size() == before, "manual producer operation blocks an in-flight AI train without charging resources")
	ctx.observed_manual_revision = Registry.manual_revision
	ctx.sim_time = 16.0
	check(Executor.execute(train, ctx).ok, "producer local guard expires after a fresh observation and simulation hold")

func _test_manual_inflight() -> void:
	var gateway = _new_gateway()
	var client = gateway._http_client
	gateway._run_tick_requests(5)
	var player = load("res://scripts/input/player_commands.gd")
	player.unit_order(world, unit, "move", Vector2(-15, 4))
	client.response = _response(5, [_move("pre_manual_snapshot")])
	client.completed.emit()
	await process_frame
	check(unit._requested_move_target == Vector2(-15, 4) and not ctx.executed_command_ids.has("pre_manual_snapshot"), "manual order during in-flight HTTP survives the old AI response")
	var feedback: Array = Events.peek(gateway._event_subscriber).events
	check(feedback.any(func(event): return event.type == "command_result" and event.get("reason") == "manual_control_hold"), "overridden stale AI command emits explicit manual-control rejection")
	ctx.sim_time = 30.0
	check(Executor.execute(_move("old_snapshot_late"), ctx).reason == "manual_control_hold", "manual revision rejects old snapshot even after short local hold expires")
	ctx.observed_manual_revision = Registry.manual_revision
	ctx.sim_time = 13.0
	check(Executor.execute(_move("fresh_snapshot_early"), ctx).reason == "manual_control_hold", "fresh snapshot still honors short simulation-time hold")
	ctx.sim_time = 15.0
	check(Executor.execute(_move("fresh_snapshot_after_hold"), ctx).ok, "fresh observations can resume AI after local hold expires")
	gateway.free()

func _test_shared_gateway_manual_boundary() -> void:
	var other := UnitScene.instantiate() as UnitAgent
	other.def = Villager
	other.civ = Civ
	other.team = Enums.Team.AI
	other.match_state = state
	other.sim_pos = Vector2(10, 10)
	entities.add_child(other)
	other.set_physics_process(false)
	var other_id := Registry.id_of(other)
	var other_context := Context.new()
	other_context.entities = entities
	other_context.match_state = state
	other_context.team = Enums.Team.AI
	other_context.civ = Civ
	other_context.session_epoch = "7"
	other_context.require_session_epoch = true
	var gateway = _new_gateway()
	gateway._teams.append({"team": 1, "enemy_team": 0, "civ": Civ})
	gateway._exec_contexts[1] = other_context
	var client = gateway._http_client
	Events.clear()
	gateway._run_tick_requests(6)
	var revision_at_send := Registry.manual_revision
	other.command_move(Vector2(20, 10))
	Registry.report_manual_command({"op": "move", "unit_id": other_id, "pos": [20, 10]}, 1)
	gateway.match_time = 16.0
	client.response = _response(6)
	client.completed.emit()
	await process_frame
	check(client.calls == 2 and client.last_payload.metadata.team == 1, "shared gateway requests second team after first asynchronous response")
	check(not client.last_payload.events.any(func(event): return event.type == "human_command"), "second request still carries the round's original event snapshot")
	check(other_context.observed_manual_revision == revision_at_send, "second team manual fence remains aligned with shared event snapshot")
	check(gateway.match_time > float(other.get_meta("manual_control_until_sim_time", 0)), "shared-round regression exceeds short local hold and relies on revision fence")
	var command := _move("second_team_pre_manual")
	command.unit_id = other_id
	client.response = _response(6, [command])
	client.response.team = 1
	client.completed.emit()
	await process_frame
	check(other._requested_move_target == Vector2(20, 10) and not other_context.executed_command_ids.has(command.command_id), "late second-team response cannot overwrite the unseen manual order")
	var pending: Array = Events.peek(gateway._event_subscriber).events
	check(pending.any(func(event): return event.type == "human_command") and pending.any(func(event): return event.get("reason") == "manual_control_hold"), "manual event and rejected response survive shared batch acknowledgement")
	# Invalid ownership must not reveal private control metadata through reasons.
	command.command_id = "probe_enemy_manual_state"
	check(Executor.execute(command, ctx).reason == "unit_wrong_team", "enemy actor returns ownership rejection without consulting private manual metadata")
	# One team accepting a later observation must not consume the failed team's
	# private events. Both receive the retained batch again on the next round.
	gateway._run_tick_requests(7)
	client.response = _response(7)
	client.completed.emit()
	await process_frame
	check(client.last_payload.events.any(func(event): return event.type == "human_command"), "next round finally delivers second team's manual event")
	client.response = {}
	client.completed.emit()
	await process_frame
	check(not Events.peek(gateway._event_subscriber).events.is_empty(), "one team's HTTP failure prevents shared event acknowledgement")
	gateway._run_tick_requests(8)
	client.response = _response(8)
	client.completed.emit()
	await process_frame
	client.response = _response(8)
	client.response.team = 1
	client.completed.emit()
	await process_frame
	check(Events.peek(gateway._event_subscriber).events.is_empty(), "both teams accepting retry acknowledges the shared batch exactly once")
	gateway.free()
	other.free()

func _test_progress_and_manual() -> void:
	unit.command_stop()
	Registry.sample_owned_state(entities, 0, 20.0)
	Executor.execute(_move("stalled_move"), ctx)
	Registry.sample_owned_state(entities, 0, 21.0)
	Events.clear()
	Registry.sample_owned_state(entities, 0, 30.0)
	var stalled := Events.drain()
	check(stalled.any(func(event): return event.type == "unit_stalled" and event.get("task_id") == "scout-route"), "blocked order reports lack of observed progress with task lineage")
	check(Events.for_team(stalled, 1, false).is_empty(), "execution progress is private to controlling team")
	Registry.sample_owned_state(entities, 0, 31.0)
	check(Events.drain().is_empty(), "unchanged stall is throttled instead of flooding every tick")
	unit.sim_pos += Vector2(1, 0)
	Registry.sample_owned_state(entities, 0, 32.0)
	Registry.sample_owned_state(entities, 0, 35.0)
	check(Events.drain().is_empty(), "actual displacement resets stalled-order timer")
	var player = load("res://scripts/input/player_commands.gd")
	player.unit_order(world, unit, "move", Vector2(-8, 4))
	var manual := Events.drain()
	check(manual.size() == 1 and manual[0].type == "human_command" and manual[0].unit_id == Registry.id_of(unit), "offline player command emits actor ID for human-priority lease")
	check(not unit.has_meta("ai_command_lineage") and Events.for_team(manual, 1, false).is_empty(), "manual takeover clears obsolete AI lineage without disclosing orders")

func _test_config() -> void:
	var config = load("res://scripts/ai_gateway/ai_config.gd").from_game_settings()
	check(config.multi_agent_enabled and config.uses_multi_agent_protocol(), "packaged external LLM config enables multi-agent fast channel")
	check(config.multi_agent_tick_url().ends_with("/v3/ai/tick"), "v3 URL resolves from configured service address")
	config.multi_agent_enabled = false
	config.protocol = "v2_chat"
	check(not config.uses_multi_agent_protocol() and config.uses_chat_protocol(), "explicit rollback retains legacy v2 chat protocol")
