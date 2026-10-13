extends SceneTree

var network: Node
var session: Node
var world: Node
var control: Node
var checkbox: CheckBox
var elapsed := 0.0
var playing_elapsed := 0.0
var phase := 0
var checks := 0
var failures: Array[String] = []
var guest_resumed := false
var manual_unit: Node

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error("AI AUTOPLAY PEER FAILED: " + label)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	network = root.get_node("NetworkSession")
	session = root.get_node("GameSession")
	session.ai_service_url = args[1]
	session.ai_service_token = ""
	session.ai_chat_url = ""
	session.ai_llm_base_url = ""
	session.ai_model = "mock-strategist"
	session.ai_tick_interval_sec = 0.2
	session.ai_service_timeout_sec = 10.0
	network.matched.connect(_matched)
	network.ended.connect(_ended)
	network.message_received.connect(func(message: Dictionary):
		if message.get("type") == "command" and message.get("command", {}).get("op") == "stop":
			guest_resumed = true)
	check(network.join_queue(args[0], "Autoplay test", "chinese") == OK, "join real relay")

func _matched(info: Dictionary) -> void:
	session.online_active = true
	session.online_team = int(info.team)
	session.player_civ_id = StringName(info.players[0].civ)
	session.ai_civ_id = StringName(info.players[1].civ)
	session.match_ai_mode = "sandbox"
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > 30:
		check(false, "timeout phase=%d team=%d" % [phase, session.online_team])
		_finish()
		return false
	if world == null or network.state != "playing": return false
	control = world.get_node_or_null("PlayerAiControl")
	if control == null or not control.local_state().available: return false
	checkbox = world.get_node("UILayer/AiAutoplayControls/Panel/Row/AutoplayCheck")
	playing_elapsed += delta
	if phase == 0:
		check(not checkbox.button_pressed and not checkbox.disabled, "online starts with an available manual checkbox")
		if session.online_team == 1:
			check(not control.set_team_enabled(0, true), "guest cannot directly control host")
		checkbox.button_pressed = true
		check(control.local_state().enabled, "own checkbox requests AI control")
		if session.online_team == 1:
			check(control.local_state().status == "pending" and checkbox.disabled, "guest waits for host acknowledgement")
		phase = 1
	elif phase == 1:
		var states: Dictionary = control.capture_states()
		if not states["0"].enabled or not states["1"].enabled or states[str(session.online_team)].status != "active": return false
		check(checkbox.button_pressed and not checkbox.disabled, "authoritative active state returns to checkbox")
		if session.online_team == 0:
			check(control._gateways.size() == 2, "host owns separate external AI gateways for both teams")
		else:
			check(control._gateways.is_empty(), "guest never creates or executes local AI")
		phase = 2
	elif phase == 2:
		if not _has_orders(session.online_team) or playing_elapsed < 2: return false
		check(true, "external Python orders are simulated and replicated for own team")
		phase = 3
	elif phase == 3:
		var cancel_at := 4.0 if session.online_team == 0 else 7.0
		if playing_elapsed < cancel_at: return false
		if session.online_team == 1:
			if control.capture_states()["0"].enabled: return false
			check(not control.capture_states()["0"].enabled and control.capture_states()["1"].enabled, "host cancellation leaves guest AI running")
		checkbox.button_pressed = false
		phase = 4
	elif phase == 4:
		if control.local_state().status != "off": return false
		check(not checkbox.button_pressed and not checkbox.disabled, "cancelled state confirms manual control")
		if session.online_team == 1:
			var runtime: Node = world.get_node("NetworkMatch")
			for entity in world.get_node("Entities").get_children():
				if entity is UnitAgent and entity.team == 1:
					manual_unit = entity
					check(runtime.submit_command({"op":"stop", "unit_id":runtime.entity_id(entity)}), "guest resumes normal manual command routing")
					break
		phase = 5
	elif phase == 5:
		if session.online_team == 0:
			if not guest_resumed or not control._gateways.is_empty(): return false
			check(control._gateways.is_empty(), "both cancelled teams leave no active AI gateways")
		else:
			if manual_unit == null or manual_unit.order != Enums.OrderType.NONE: return false
		_finish()
	return false

func _ended(_info: Dictionary) -> void:
	await process_frame
	check(phase >= 5, "peer finishes only after both cancellation checks")
	check(control._gateways.is_empty() and not control.local_state().enabled, "disconnect stops all player AI")
	_finish()

func _has_orders(team: int) -> bool:
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == team and entity.order != Enums.OrderType.NONE:
			return true
	return false

func _finish() -> void:
	print("AI AUTOPLAY PEER: team=%d %d checks, %d failures" % [session.online_team, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
