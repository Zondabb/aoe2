extends SceneTree

## Two real online peers; only the authoritative host talks to the AI services.
var network: Node
var session: Node
var world: Node
var control: Node
var elapsed := 0.0
var phase_time := 0.0
var phase := 0
var checks := 0
var failures: Array[String] = []
var urls: Array[String] = []
var report_path := ""
var healthy_gateway: Node
var healthy_tick := 0
var guest_resumed := false
var report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error("DUAL AI PEER FAILED: " + label)


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	network = root.get_node("NetworkSession")
	session = root.get_node("GameSession")
	urls.assign([args[1], args[2], args[3]])
	report_path = args[4]
	session.ai_service_url = urls[0]
	session.ai_team_service_urls = {0: urls[0], 1: urls[1]}
	session.ai_service_token = ""
	session.ai_team_service_tokens = {0: "", 1: ""}
	session.ai_multi_agent_enabled = true
	session.ai_fast_tick_interval_sec = 0.25
	session.ai_fast_timeout_sec = 1.0
	network.matched.connect(_matched)
	network.ended.connect(_ended)
	network.message_received.connect(func(message: Dictionary):
		if message.get("type") == "command" and message.get("command", {}).get("op") == "stop":
			guest_resumed = true)
	check(network.join_queue(args[0], "Dual AI test", "chinese") == OK, "join real relay")


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
	phase_time += delta
	if elapsed > 42:
		check(false, "timeout phase=%d team=%d" % [phase, session.online_team])
		_finish()
		return false
	if world == null or network.state != "playing": return false
	control = world.get_node_or_null("PlayerAiControl")
	if control == null or not control.local_state().available: return false
	var team := int(session.online_team)
	var states: Dictionary = control.capture_states()
	if phase == 0:
		# The guest becomes playable before its first authoritative state arrives.
		if team == 1 and (control.team_service_url(0).is_empty() or control.team_service_url(1).is_empty()): return false
		check(control.team_service_url(0) == urls[0] and control.team_service_url(1) == urls[1], "distinct initial team service addresses")
		if team == 1:
			check(not control.request_team_service_url(0, urls[2]), "guest cannot change host service")
			check(not control.request_team_service_url(1, urls[2]), "guest cannot change its authoritative service")
			check(not control.set_team_enabled(0, true), "guest cannot directly enable host AI")
		else:
			check(control.request_team_service_url(0, urls[0]), "host configures its service")
			check(control.request_team_service_url(1, urls[1]), "host configures guest service")
		check(control.request_local_enabled(true), "player requests own AI control")
		phase = 1
		phase_time = 0
	elif phase == 1:
		if states["0"].status != "active" or states["1"].status != "active": return false
		if not _has_orders(team) or phase_time < 8: return false
		check(true, "both independent Python services execute and replicate orders")
		if team == 0:
			check(control._gateways.size() == 2, "host owns two team gateways")
			check(control._gateways[0].config.service_url == urls[0] and control._gateways[1].config.service_url == urls[1], "each gateway uses its assigned endpoint")
			healthy_gateway = control._gateways[1]
			healthy_tick = healthy_gateway.tick
			report["reroute_time"] = Time.get_unix_time_from_system()
			check(control.request_team_service_url(0, urls[2]), "host changes running team zero to unreachable service")
		else:
			check(control._gateways.is_empty(), "guest never executes either external AI locally")
		phase = 2
		phase_time = 0
	elif phase == 2:
		if team == 0:
			if phase_time < 5: return false
			check(control._gateways.get(1) == healthy_gateway, "changing one endpoint preserves the other gateway instance")
			check(healthy_gateway.tick > healthy_tick + 8 and states["1"].status == "active", "healthy service keeps advancing while other service is unreachable")
			check(control.set_team_enabled(0, false), "host cancels only team zero AI")
			healthy_tick = healthy_gateway.tick
		else:
			if states["0"].enabled or states["1"].status != "active": return false
			check(control.team_service_url(0) == urls[2], "changed endpoint is replicated to guest")
			check(states["1"].enabled, "host cancellation leaves guest AI active")
		phase = 3
		phase_time = 0
	elif phase == 3:
		if phase_time < 3: return false
		if team == 0:
			check(control._gateways.get(1) == healthy_gateway and healthy_gateway.tick > healthy_tick + 4, "stopping one team preserves other team progress")
			report["cancel_guest"] = true
			var output := FileAccess.open(report_path, FileAccess.WRITE)
			output.store_string(JSON.stringify(report))
			phase = 4
		else:
			if not FileAccess.file_exists(report_path): return false
			var barrier = JSON.parse_string(FileAccess.get_file_as_string(report_path))
			if not barrier is Dictionary or not barrier.get("cancel_guest", false): return false
			check(control.request_local_enabled(false), "guest can cancel its own AI")
			phase = 4
	elif phase == 4:
		if team == 1:
			if control.local_state().status != "off": return false
			var runtime: Node = world.get_node("NetworkMatch")
			for entity in world.get_node("Entities").get_children():
				if entity is UnitAgent and entity.team == 1:
					check(runtime.submit_command({"op": "stop", "unit_id": runtime.entity_id(entity)}), "guest resumes manual command routing")
					break
			phase = 5
		else:
			if not guest_resumed or not control._gateways.is_empty(): return false
			check(true, "both cancellations remove all authoritative gateways")
			phase = 5
			_finish()
	return false


func _ended(_info: Dictionary) -> void:
	await process_frame
	check(phase >= 5, "disconnect follows all isolation and permission checks")
	_finish()


func _has_orders(team: int) -> bool:
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == team and entity.order != Enums.OrderType.NONE:
			return true
	return false


func _finish() -> void:
	if session.online_team == 0 and world != null:
		var roster := {}
		for entity in world.get_node("Entities").get_children():
			if entity is UnitAgent or entity is BuildingAgent:
				roster[str(EntityRegistry.id_of(entity))] = entity.team
		report["entity_teams"] = roster
		var output := FileAccess.open(report_path, FileAccess.WRITE)
		output.store_string(JSON.stringify(report))
	print("DUAL AI PEER: team=%d %d checks, %d failures" % [session.online_team, checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
