extends SceneTree
## Long-running real network peer; see tools/test_network_stability.py.
const SessionProbe := preload("res://tests/network_stability_session.gd")
const RuntimeProbe := preload("res://tests/network_stability_runtime.gd")
const Commands := preload("res://scripts/input/player_commands.gd")
var network: Node
var session: Node
var world: Node
var runtime: Node
var role := "player"
var label := ""
var endpoint := ""
var finish_file := ""
var report_file := ""
var requested_speed := 2.0
var started_at := 0
var first_playing_at := 0
var last_frame_usec := 0
var frame_count := 0
var frame_total_usec := 0
var frame_max_usec := 0
var last_print_at := 0
var last_order_at := 0
var direction := 1.0
var base_position := Vector2.ZERO
var tracked: Node
var finished := false
var outcome: Dictionary = {}
var extra_units := 0
var extras_spawned := false
var last_runtime_status := ""
var runtime_probe: Script = RuntimeProbe

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	started_at = Time.get_ticks_msec()
	var args := OS.get_cmdline_user_args()
	endpoint = args[0]
	role = args[1]
	label = args[2]
	finish_file = args[3]
	report_file = args[4]
	requested_speed = float(args[5])
	if args.size() > 6: extra_units = int(args[6])
	network = root.get_node("NetworkSession")
	if args.size() > 7 and not String(args[7]).is_empty():
		network.set_script(load(String(args[7]).path_join("session_probe.gd")))
		runtime_probe = load(String(args[7]).path_join("runtime_probe.gd"))
	else:
		network.set_script(SessionProbe)
	session = root.get_node("GameSession")
	Engine.time_scale = requested_speed
	network.matched.connect(_matched)
	network.ended.connect(_ended)
	network.status_changed.connect(func(message: String): print(label, ": ", message))
	if role == "player":
		network.join_queue(endpoint, label, "chinese")
	else:
		network.matches_received.connect(_matches)
		network.request_matches(endpoint)

func _matches(matches: Array) -> void:
	if world == null and not matches.is_empty(): network.watch_match(endpoint, String(matches[0].match_id))

func _matched(info: Dictionary) -> void:
	session.online_active = true
	session.online_spectator = role != "player"
	session.online_team = int(info.get("team", -1))
	session.player_civ_id = StringName(info.players[0].civ)
	session.ai_civ_id = StringName(info.players[1].civ)
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	Engine.time_scale = requested_speed

func _process(_delta: float) -> bool:
	if finished: return false
	var now := Time.get_ticks_msec()
	if started_at > 0 and now - started_at > 180000:
		outcome = {"reason": "probe_timeout"}
		_write_report()
		quit(1)
		return false
	if world == null: return false
	if runtime == null:
		runtime = world.get_node_or_null("NetworkMatch")
		if runtime == null: return false
		var old := {}
		for property in runtime.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE and property.name != "script":
				old[property.name] = runtime.get(property.name)
		runtime.set_script(runtime_probe)
		for name in old: runtime.set(name, old[name])
		runtime.status_changed.connect(func(message: String): last_runtime_status = message)
	if runtime.get("_terminal"):
		outcome = {"reason": "runtime_terminal", "message": last_runtime_status}
		finished = true
		_write_report()
		quit(1)
		return false
	if not runtime.get("_playing"): return false
	if first_playing_at == 0: first_playing_at = now
	var usec := Time.get_ticks_usec()
	if last_frame_usec:
		var elapsed := usec - last_frame_usec
		frame_count += 1
		frame_total_usec += elapsed
		frame_max_usec = maxi(frame_max_usec, elapsed)
	last_frame_usec = usec
	if now - last_print_at >= 5000:
		last_print_at = now
		print("NETWORK STABILITY METRIC ", JSON.stringify(_report()))
	if runtime.is_host:
		if not extras_spawned:
			extras_spawned = true
			for index in extra_units:
				var extra: UnitAgent = load("res://scenes/entities/unit_view.tscn").instantiate()
				extra.def = load("res://scripts/data/game_catalog.gd").get_unit(&"militia")
				extra.team = Enums.Team.PLAYER
				extra.civ = load("res://data/civs/chinese.tres")
				extra.match_state = world.get_node("Bootstrap").match_state
				extra.sim_pos = Vector2(-110 + (index % 20) * 3, -105 + int(index / 20) * 3)
				world.get_node("Entities").add_child(extra)
		if FileAccess.file_exists(finish_file):
			world.get_node("Bootstrap").match_state.set_winner(Enums.Team.AI)
			return false
		if now - last_order_at >= 1400:
			last_order_at = now
			if not is_instance_valid(tracked):
				for child in world.get_node("Entities").get_children():
					if child is UnitAgent and child.team == 0:
						tracked = child
						base_position = child.sim_pos
						break
			if is_instance_valid(tracked):
				direction = -direction
				Commands.unit_order(world, tracked, "move", base_position + Vector2(direction * 8.0, 0.0))
	return false

func _ended(info: Dictionary) -> void:
	if finished: return
	outcome = info.duplicate(true)
	finished = true
	_write_report()
	print("NETWORK STABILITY PEER FINISHED ", JSON.stringify(_report()))
	quit(0 if info.get("reason") == "completed" else 1)

func _report() -> Dictionary:
	var result := {"label": label, "role": role, "speed": requested_speed,
		"extra_units": extra_units,
		"elapsed_seconds": (Time.get_ticks_msec() - first_playing_at) / 1000.0 if first_playing_at else 0.0,
		"frame_average_ms": float(frame_total_usec) / maxf(1, frame_count) / 1000.0,
		"frame_max_ms": frame_max_usec / 1000.0, "outcome": outcome,
		"state": network.state if network != null else "unknown", "last_runtime_status": last_runtime_status,
		"entity_count": world.get_node("Entities").get_child_count() if world != null else 0}
	if network != null: result.merge(network.probe_report())
	if runtime != null: result.merge(runtime.probe_report())
	return result

func _write_report() -> void:
	var file := FileAccess.open(report_file, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(_report(), "\t"))
