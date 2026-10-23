extends SceneTree

const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error("AI AUTOPLAY FAILED: " + label)

func wait_for(predicate: Callable, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call(): return true
		await process_frame
	return false

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Run tools/test_ai_autoplay_e2e.py with a local mock upstream")
		quit(1)
		return
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "local"
	session.ai_service_url = args[0]
	session.ai_service_token = ""
	session.ai_chat_url = ""
	session.ai_llm_base_url = ""
	session.ai_model = "mock-strategist"
	session.ai_tick_interval_sec = 0.2
	session.ai_service_timeout_sec = 10.0
	session.ai_multi_agent_enabled = args.size() < 3 or args[2] != "v2"
	session.ai_fast_tick_interval_sec = 0.25
	session.ai_fast_timeout_sec = 3.0
	# The opt-in selects the Python service independently of obsolete provider settings.
	session.ai_backend = "rules_compat"
	session.ai_protocol = "v1_tick"
	session.ai_use_local_embedded = true
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var control: Node = world.get_node("PlayerAiControl")
	var checkbox: CheckBox = world.get_node("UILayer/AiAutoplayControls/Panel/Row/AutoplayCheck")
	var opponent: Node = world.get_node("AiController")
	check(not checkbox.button_pressed and not checkbox.disabled, "single-player defaults to manual control")
	check(not control.set_team_enabled(1, true), "offline opt-in cannot take over opponent")
	checkbox.button_pressed = true
	check(control.local_state().enabled and control.local_state().status == "connecting", "checkbox starts external player AI")
	var gateway: Node = control._gateways[0]
	var first_gateway_id := gateway.get_instance_id()
	check(not gateway.config.use_local_embedded and gateway.config.protocol == "v2_chat", "player opt-in forces external Python AI service")
	check(gateway.config.uses_multi_agent_protocol() == session.ai_multi_agent_enabled, "player opt-in honors v3 setting and v2 rollback")
	check(await wait_for(func(): return gateway.metrics.tick_success_count >= 1), "actual external HTTP decision completed")
	check(await wait_for(func(): return gateway.tick >= 2 and _has_orders(world, 0)), "external commands execute for own team")
	if session.ai_multi_agent_enabled:
		check(await wait_for(func(): return _all_roles_planned(gateway), 15.0), "all seven real propose_plan responses are applied to player specialists")
	check(is_instance_valid(opponent) and opponent.is_processing(), "opponent AI continues independently")
	var tc: Node = _town_center(world, 0)
	control.match_state.population_cap[0] = 100
	check(tc.enqueue_train(load("res://data/units/villager.tres")), "fixture starts a real production item before cancellation")
	var queued: int = tc.train_queue.size()
	var before_food: int = control.match_state.get_resource(0, Enums.ResourceType.FOOD)
	gateway._queue_response({"team":0, "for_tick":gateway.tick + 10, "commands":[{
		"op":"train", "building_id":Registry.id_of(tc), "unit_def_id":"villager", "command_id":"cancelled_autoplay_train",
	}]})
	checkbox.button_pressed = false
	check(not control.local_state().enabled and not gateway.enabled and gateway._pending_responses.is_empty(), "uncheck immediately stops and clears queued decisions")
	gateway._execute_due_commands(gateway.tick + 100)
	check(tc.train_queue.size() == queued and control.match_state.get_resource(0, Enums.ResourceType.FOOD) == before_food, "cancelled future order cannot spend resources")
	check(queued > 0 and tc.train_queue.size() == queued, "existing production remains after cancellation")
	await process_frame
	checkbox.button_pressed = true
	var resumed: Node = control._gateways[0]
	check(resumed.get_instance_id() != first_gateway_id, "reenable creates a fresh gateway")
	check(await wait_for(func(): return resumed._request_in_flight), "new request is in flight")
	var previous_match_id: String = resumed.match_id
	checkbox.button_pressed = false
	await create_timer(0.8).timeout
	check(control._gateways.is_empty() and not checkbox.button_pressed, "cancel during HTTP leaves manual control")
	checkbox.button_pressed = true
	check(await wait_for(func(): return control._gateways[0].service_status == "online"), "can enable again after in-flight cancellation")
	check(control._gateways[0].match_id != previous_match_id, "new session has isolated Python commander memory")
	checkbox.button_pressed = false
	await process_frame
	# A dead local endpoint fails visibly and leaves the checkbox retryable.
	session.ai_service_url = args[1]
	session.ai_service_timeout_sec = 0.5
	checkbox.button_pressed = true
	check(await wait_for(func(): return control.local_state().status == "error"), "offline Python service produces clear error")
	check(not checkbox.button_pressed and not checkbox.disabled and control._gateways.is_empty(), "connection failure restores manual control and allows retry")
	session.ai_service_url = args[0]
	session.ai_service_timeout_sec = 10.0
	checkbox.button_pressed = true
	check(await wait_for(func(): return control.local_state().status == "active"), "service can recover after retry")
	control.match_state.set_winner(0)
	check(not control.local_state().enabled and not control.local_state().available and checkbox.disabled, "winner stops player AI and disables checkbox")
	world.queue_free()
	await process_frame
	print("AI AUTOPLAY SINGLE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _has_orders(world: Node, team: int) -> bool:
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == team and entity.order != Enums.OrderType.NONE:
			return true
	return false

func _all_roles_planned(gateway: Node) -> bool:
	for role in ["commander", "construction", "economy", "technology", "scout", "combat", "defense"]:
		if gateway.planning_status.get(role, {}).get("state") != "applied":
			return false
	return true

func _town_center(world: Node, team: int) -> Node:
	for entity in world.get_node("Entities").get_children():
		if entity is BuildingAgent and entity.team == team and entity.def.id == &"town_center":
			return entity
	return null
