extends SceneTree

## Two real online peers; each player connects its own AI service.
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
	session.ai_service_url = urls[2]
	session.ai_team_service_urls = {0: "", 1: ""}
	session.ai_service_token = ""
	session.ai_team_service_tokens = {0: "", 1: ""}
	session.ai_multi_agent_enabled = true
	session.ai_fast_tick_interval_sec = 0.25
	session.ai_fast_timeout_sec = 1.0
	network.matched.connect(_matched)
	network.ended.connect(_ended)
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
	var state: Dictionary = control.local_state()
	if phase == 0:
		check(control.team_service_url(1-team).is_empty(), "other endpoint stays private")
		check(not control.request_team_service_url(1-team, urls[2]), "cannot change another player endpoint")
		check(control.request_team_service_url(team, urls[team]), "either player configures own service")
		check(control.request_local_enabled(true), "enable local gateway")
		phase = 1
		phase_time = 0
	elif phase == 1:
		if state.status != "active" or not _has_orders(team) or phase_time < 8: return false
		check(control._gateways.size() == 1 and control._gateways.has(team), "one local gateway per player")
		healthy_gateway = control._gateways[team]
		healthy_tick = healthy_gateway.tick
		if team == 0:
			report["reroute_time"] = Time.get_unix_time_from_system()
			check(control.request_team_service_url(team, urls[2]), "switch own gateway to unreachable service")
		phase = 2
		phase_time = 0
	elif phase == 2:
		if phase_time < 6: return false
		if team == 0:
			check(control.request_local_enabled(false), "cancel after endpoint failure")
			var output := FileAccess.open(report_path, FileAccess.WRITE)
			output.store_string(JSON.stringify(report))
			phase = 3
		elif FileAccess.file_exists(report_path):
			check(state.status == "active" and control._gateways[team] == healthy_gateway and healthy_gateway.tick > healthy_tick + 4, "other player continues independently")
			check(control.request_local_enabled(false), "guest can disable its gateway")
			phase = 3
	elif phase == 3:
		if team == 1:
			var roster := {}
			for entity in world.get_node("Entities").get_children():
				if entity is UnitAgent or entity is BuildingAgent: roster[str(EntityRegistry.id_of(entity))] = entity.team
			var file := FileAccess.open(report_path + ".guest", FileAccess.WRITE)
			file.store_string(JSON.stringify(roster))
			phase = 5
		elif FileAccess.file_exists(report_path + ".guest"):
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
