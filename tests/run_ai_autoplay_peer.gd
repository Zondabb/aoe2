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
var instruction_sent_at := 0.0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error("AI AUTOPLAY PEER FAILED: " + label)

func _run() -> void:
	Engine.time_scale = 1.0
	var args := OS.get_cmdline_user_args()
	network = root.get_node("NetworkSession")
	session = root.get_node("GameSession")
	session.ai_service_url = args[1]
	session.ai_team_service_urls = {0: "", 1: ""}
	session.ai_team_service_tokens = {0: "", 1: ""}
	session.ai_service_token = ""
	session.ai_chat_url = ""
	session.ai_llm_base_url = ""
	session.ai_model = "mock-strategist"
	session.ai_tick_interval_sec = 0.2
	session.ai_service_timeout_sec = 10.0
	session.ai_multi_agent_enabled = args.size() < 3 or args[2] != "v2"
	session.ai_fast_tick_interval_sec = 0.25
	session.ai_fast_timeout_sec = 15.0
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
	if elapsed > 90:
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
		if not network.is_host():
			check(not control.set_team_enabled(network.host_team, true), "guest cannot directly control host")
		checkbox.button_pressed = true
		check(control.local_state().enabled, "own checkbox requests AI control")
		if not network.is_host():
			check(control.local_state().status == "pending" and checkbox.disabled, "guest waits for host acknowledgement")
		phase = 1
	elif phase == 1:
		var states: Dictionary = control.capture_states()
		if not states["0"].enabled or not states["1"].enabled or states[str(session.online_team)].status != "active": return false
		check(checkbox.button_pressed and not checkbox.disabled, "authoritative active state returns to checkbox")
		if network.is_host():
			check(control._gateways.size() == 2, "host owns separate external AI gateways for both teams")
			check(control._gateways[0].config.uses_multi_agent_protocol() == session.ai_multi_agent_enabled and control._gateways[1].config.uses_multi_agent_protocol() == session.ai_multi_agent_enabled, "both authoritative gateways honor v3 or explicit legacy mode")
		else:
			check(control._gateways.is_empty(), "guest never creates or executes local AI")
		var input: LineEdit = world.get_node("UILayer/AiAutoplayControls")._instruction
		input.text = "队伍%d：增加食物采集" % session.online_team
		input.text_submitted.emit(input.text)
		check(input.text.is_empty(), "player instruction submitted through the online HUD")
		instruction_sent_at = playing_elapsed
		phase = 2
	elif phase == 2:
		if not _has_orders(session.online_team) or playing_elapsed < 2: return false
		check(true, "external Python orders are simulated and replicated for own team")
		phase = 3
	elif phase == 3:
		var cancel_at := instruction_sent_at + (12.0 if network.is_host() else 14.0)
		if playing_elapsed < cancel_at: return false
		if not network.is_host():
			if control.capture_states()[str(network.host_team)].enabled: return false
			check(not control.capture_states()[str(network.host_team)].enabled and control.capture_states()[str(session.online_team)].enabled, "host cancellation leaves guest AI running")
		checkbox.button_pressed = false
		phase = 4
	elif phase == 4:
		if control.local_state().status != "off": return false
		check(not checkbox.button_pressed and not checkbox.disabled, "cancelled state confirms manual control")
		if not network.is_host():
			var runtime: Node = world.get_node("NetworkMatch")
			for entity in world.get_node("Entities").get_children():
				if entity is UnitAgent and entity.team == session.online_team:
					manual_unit = entity
					check(runtime.submit_command({"op":"stop", "unit_id":runtime.entity_id(entity)}), "guest resumes normal manual command routing")
					break
		phase = 5
	elif phase == 5:
		if network.is_host():
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
