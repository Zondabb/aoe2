extends SceneTree
## Independent event delivery and cancellation at real coroutine boundaries.

const EVENTS := preload("res://scripts/ai_gateway/event_buffer.gd")
const METRICS := preload("res://scripts/ai_gateway/ai_gateway_metrics.gd")
const CONTEXT := preload("res://scripts/ai_gateway/command_execution_context.gd")
const PARSER := preload("res://scripts/ai_gateway/llm_response_parser.gd")
const REGISTRY := preload("res://scripts/ai_gateway/entity_registry.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER := preload("res://data/units/villager.tres")
const CIV := preload("res://data/civs/teutons.tres")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var entities: Node2D
var state: MatchState
var unit: UnitAgent
var unit_id := -1

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	_test_subscribers()
	world = Node2D.new()
	root.add_child(world)
	entities = Node2D.new()
	world.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-32, -32, 64, 64)
	unit = UNIT.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.civ = CIV
	unit.team = Enums.Team.PLAYER
	unit.match_state = state
	unit.sim_pos = Vector2(2, 2)
	entities.add_child(unit)
	unit.set_physics_process(false)
	unit_id = REGISTRY.register(unit)
	for operation in ["chat", "tick", "chat_batch", "tick_batch"]:
		await _test_request_cancel(operation)
	await _test_restart_generation()
	await _test_start_cancel(false)
	await _test_start_cancel(true)
	await _test_gateway_coexistence()
	await _test_unauthorized_health()
	_test_exit_cleanup()
	world.free()
	EVENTS.clear()
	check(checks >= 50, "all lifecycle test sections run to completion")
	print("AI GATEWAY LIFECYCLE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_subscribers() -> void:
	EVENTS.clear()
	EVENTS.push({"type":"before"})
	var first := EVENTS.subscribe()
	var second := EVENTS.subscribe()
	EVENTS.push({"type":"private", "_visible_to":[1]})
	check(EVENTS.drain().size() == 2, "legacy drain retains its own complete pending events")
	var first_read := EVENTS.read(first)
	check(first_read.size() == 1 and first_read[0].type == "private", "subscriber starts at its subscription time")
	first_read[0]["type"] = "changed_by_consumer"
	EVENTS.push({"type":"next"})
	var second_read := EVENTS.read(second)
	check(second_read.size() == 2 and second_read[0].type == "private", "consumers cannot steal or mutate another consumer's events")
	check(EVENTS.for_team(second_read, 0, false).size() == 1, "independent delivery still hides private team feedback")
	check(EVENTS.read(first).size() == 1, "each subscriber reads new events once")
	check(EVENTS.read(first).is_empty(), "repeated reads do not replay events")
	var late := EVENTS.subscribe()
	check(EVENTS.read(late).is_empty(), "new gateway does not receive another gateway's old feedback")
	EVENTS.clear()
	EVENTS.push({"type":"after_clear"})
	check(EVENTS.read(first).size() == 1 and EVENTS.read(second).size() == 1, "explicit match reset preserves usable subscriber cursors")
	EVENTS.unsubscribe(first)
	EVENTS.unsubscribe(second)
	EVENTS.unsubscribe(late)
	check(EVENTS._subscriber_events.is_empty(), "last unsubscribe releases subscriber history")
	check(EVENTS.read(first).is_empty(), "stopped subscribers cannot read subsequent events")
	EVENTS.clear()
	var slow := EVENTS.subscribe()
	for index in EVENTS.MAX_BUFFERED_EVENTS + 5:
		EVENTS.push({"type":"bounded", "index":index})
	check(EVENTS.peek_count() == EVENTS.MAX_BUFFERED_EVENTS, "legacy buffer has bounded memory even with no drain caller")
	var bounded := EVENTS.read(slow)
	check(bounded.size() == EVENTS.MAX_BUFFERED_EVENTS and bounded[0].index == 5, "slow subscribers retain the latest bounded event window")
	check(EVENTS._subscriber_events.is_empty(), "consumed subscriber history is pruned immediately")
	EVENTS.unsubscribe(slow)
	EVENTS.clear()

func _new_gateway():
	var gateway = load("res://scripts/ai_gateway/ai_gateway.gd").new()
	root.add_child(gateway)
	gateway.set_process(false)
	gateway.match_state = state
	gateway.entities = entities
	gateway.match_id = "lifecycle_test"
	gateway.service_status = "online"
	gateway.config = load("res://scripts/ai_gateway/ai_config.gd").new()
	gateway.config.use_local_embedded = false
	gateway.config.protocol = "v2_chat"
	gateway.config.history_turns = 2
	gateway.metrics = METRICS.new()
	gateway._teams.append({"team":0, "enemy_team":1, "civ":CIV})
	gateway._teams.append({"team":1, "enemy_team":0, "civ":CIV})
	var ctx := CONTEXT.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.PLAYER
	ctx.civ = CIV
	gateway._exec_contexts[0] = ctx
	var client = load("res://tests/fixtures/delayed_ai_client.gd").new()
	gateway.add_child(client)
	gateway._http_client = client
	gateway._event_subscriber = EVENTS.subscribe()
	return gateway

func _move_command() -> Dictionary:
	return {"command_id":"test_move", "op":"move", "unit_id":unit_id, "pos":[8,4]}

func _wait_for_transport(client, expected_calls: int) -> void:
	# Observation preparation now has its own cancellable frame boundaries.
	# These tests deliberately cancel after reaching the held transport instead.
	var started := Time.get_ticks_msec()
	while client.calls < expected_calls and Time.get_ticks_msec() - started < 2000:
		await process_frame

func _test_request_cancel(operation: String) -> void:
	var gateway = _new_gateway()
	var client = gateway._http_client
	var entry: Dictionary = gateway._teams[0]
	var response := {"team":0, "for_tick":1, "commands":[_move_command()]}
	client.response = PARSER.wrap_commands([_move_command()]) if operation.begins_with("chat") else response
	gateway._queue_response(response)
	match operation:
		"chat": gateway._request_chat_for_team(entry, 1, [])
		"tick": gateway._request_tick_for_team(entry, 1, [])
		"chat_batch": gateway._request_chat_batch(1)
		"tick_batch": gateway._request_tick_batch(1)
	await _wait_for_transport(client, 1)
	check(client.calls == 1, "%s request reaches its asynchronous boundary" % operation)
	gateway.stop()
	check(gateway._pending_responses.is_empty() and client.cancels == 1, "%s stop clears pending commands and cancels transport immediately" % operation)
	client.completed.emit()
	await process_frame
	check(gateway._pending_responses.is_empty(), "%s late response cannot enqueue commands" % operation)
	check(gateway.metrics.tick_success_count == 0 and gateway.last_tick_latency_ms == -1.0, "%s late response cannot update tick metrics" % operation)
	gateway._queue_response(response)
	gateway._apply_response(response)
	check(gateway._pending_responses.is_empty() and unit.order != Enums.OrderType.MOVE, "%s stopped gateway rejects direct queue and execution too" % operation)
	check(gateway.service_status == "stopped" and gateway._event_subscriber == 0, "%s stop preserves its status and unregisters event subscription" % operation)
	gateway.free()

func _test_restart_generation() -> void:
	var gateway = _new_gateway()
	var client = gateway._http_client
	client.response = PARSER.wrap_commands([_move_command()])
	gateway.config.use_tick_batch = false
	gateway._run_tick_requests(1)
	await _wait_for_transport(client, 1)
	check(client.calls == 1 and gateway._request_in_flight, "sequential team requests share one active coroutine")
	gateway.stop()
	# Re-enabling the same object cannot make its earlier awaited response valid.
	gateway.enabled = true
	gateway.service_status = "online"
	client.completed.emit()
	await process_frame
	check(client.calls == 1 and gateway._pending_responses.is_empty(), "generation guard rejects old response and prevents a second team's old request after restart")
	check(not gateway._request_in_flight, "cancelled old coroutine cannot leave the new gateway busy")
	gateway._request_chat_for_team(gateway._teams[0], 2, [])
	await _wait_for_transport(client, 2)
	client.completed.emit()
	await process_frame
	check(gateway._pending_responses.size() == 1, "new generation still accepts its own current response")
	gateway._execute_due_commands(3)
	check(unit.order == Enums.OrderType.MOVE, "current enabled response executes through the real validator")
	unit.order = Enums.OrderType.NONE
	gateway.free()

func _test_start_cancel(at_match_start: bool) -> void:
	var gateway = _new_gateway()
	var client = gateway._http_client
	client.health_delay = not at_match_start
	client.start_delay = at_match_start
	gateway.service_status = "starting"
	gateway._on_match_start()
	check(client.start_calls == (1 if at_match_start else 0), "startup reaches the requested health/match-start cancellation boundary")
	gateway.stop()
	client.completed.emit()
	await process_frame
	check(gateway.service_status == "stopped" and not gateway.enabled, "late startup result cannot revive a cancelled gateway")
	check(client.calls == 0 and gateway._pending_responses.is_empty(), "cancelled startup never launches chat requests")
	gateway.free()

func _test_unauthorized_health() -> void:
	var gateway = _new_gateway()
	var client = gateway._http_client
	client.health_reply = {"ok":false, "reason":"http_401"}
	gateway.service_status = "starting"
	await gateway._on_match_start()
	check(not gateway.enabled and gateway.service_status == "unauthorized", "authorization failure preserves a useful terminal status")
	check(gateway._event_subscriber == 0 and client.start_calls == 0, "failed startup releases its subscription without beginning a match")
	gateway.free()

func _test_gateway_coexistence() -> void:
	EVENTS.clear()
	var opponent = _new_gateway()
	EVENTS.push({"type":"command_result", "_visible_to":[1], "op":"train"})
	var player = _new_gateway()
	await player._on_match_start()
	check(EVENTS.read(opponent._event_subscriber).size() == 1, "starting player takeover does not erase the opponent gateway's pending events")
	EVENTS.push({"type":"both_readers", "_visible_to":[0,1]})
	check(EVENTS.read(player._event_subscriber).size() == 1 and EVENTS.read(opponent._event_subscriber).size() == 1, "simultaneous actual gateways receive their own event copies")
	player.stop()
	EVENTS.push({"type":"opponent_after_cancel"})
	check(EVENTS.read(opponent._event_subscriber).size() == 1, "cancelling player takeover preserves the opponent subscription")
	player.free()
	opponent.free()

func _test_exit_cleanup() -> void:
	var gateway = _new_gateway()
	var subscription: int = gateway._event_subscriber
	gateway.remove_child(gateway._http_client)
	gateway._http_client.free()
	gateway._http_client = null
	root.remove_child(gateway)
	check(not gateway.enabled and not EVENTS._subscribers.has(subscription), "scene exit stops gateway and releases its event subscriber")
	gateway.free()
