extends SceneTree
## Real protocol-v2 process: ordered operations, late observer and forced repair.
const Maps := preload("res://scripts/world/map_data.gd")
var session: Node
var game: Node
var arena: Node
var runtime: Node
var role := "player"
var output := ""
var endpoint := ""
var finish_file := ""
var started := 0
var phase := 0
var corrupted := false
var done := false
var frame_bytes := 0
var keyframe_bytes := 0
var frame_packets := 0
var keyframe_packets := 0
var received_commands := 0
var first_keyframe_tick := -1
var commands_sent := 0
var default_map := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	endpoint = args[0]
	role = args[1]
	output = args[2]
	finish_file = args[3]
	default_map = args.size() > 4 and args[4] == "default"
	started = Time.get_ticks_msec()
	session = root.get_node("NetworkSession")
	game = root.get_node("GameSession")
	session.matched.connect(_matched)
	session.ended.connect(_ended)
	session.message_received.connect(_packet)
	session.status_changed.connect(func(value: String): print(role, ": ", value))
	node_added.connect(func(node: Node):
		if node.name == "NetworkMatch":
			node.status_changed.connect(func(value: String): print(role, " runtime: ", value)))
	if role == "spectator":
		session.matches_received.connect(func(matches: Array):
			if not matches.is_empty(): session.watch_match(endpoint, matches[0].match_id))
		session.request_matches(endpoint)
	else:
		session.join_queue(endpoint, role, "chinese")

func _map() -> Dictionary:
	var data := Maps.create(160, 160, "Lockstep regression")
	for side in [0, 1]:
		var sign_value := -1 if side == 0 else 1
		var team_name := "player" if side == 0 else "ai"
		data.entities.append({"id": "tc%d" % side, "type": "building", "building_id": "town_center", "team": team_name, "pos": [sign_value * 48, sign_value * 48]})
		for i in 3:
			data.entities.append({"id": "villager%d-%d" % [side, i], "type": "unit", "unit_id": "villager", "team": team_name, "pos": [sign_value * (37 + i * 3), sign_value * 39]})
		data.entities.append({"id": "archer%d" % side, "type": "unit", "unit_id": "archer", "team": team_name, "pos": [sign_value * 8, 0]})
		data.entities.append({"id": "wood%d" % side, "type": "resource", "resource_type": "wood", "pos": [sign_value * 28, sign_value * 42], "amount": 1000.0, "gather_rate": 4.0})
	return data

func _matched(info: Dictionary) -> void:
	game.online_active = true
	game.online_spectator = role == "spectator"
	game.online_team = int(info.get("team", -1))
	game.player_civ_id = &"chinese"
	game.ai_civ_id = &"chinese"
	game.match_map_data = {} if default_map else _map()
	game.match_ai_mode = "sandbox"
	arena = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena

func _packet(message: Dictionary) -> void:
	var size := JSON.stringify(message, "", true, true).to_utf8_buffer().size()
	if message.type == "keyframe_request" and arena != null:
		var net := arena.get_node("NetworkMatch")
		var debug := FileAccess.open(output + ".host-keyframe-%d" % net.tick, FileAccess.WRITE)
		debug.store_string(JSON.stringify(net.simulation.capture(), "", true, true))
	if message.type == "frame":
		frame_packets += 1
		frame_bytes += size
		received_commands += message.commands.size()
	elif message.type == "keyframe":
		var debug_file := FileAccess.open(output + ".keyframe-%d" % int(message.tick), FileAccess.WRITE)
		debug_file.store_string(JSON.stringify(message, "", true, true))
		call_deferred("_dump_restored", int(message.tick))
		keyframe_packets += 1
		keyframe_bytes += size
		if first_keyframe_tick < 0: first_keyframe_tick = int(message.tick)
	elif message.type == "snapshot":
		_fail("continuous snapshot received")

func _process(_delta: float) -> bool:
	if done: return false
	if Time.get_ticks_msec() - started > 65000:
		_fail("timed out")
		return false
	if arena == null: return false
	runtime = arena.get_node_or_null("NetworkMatch")
	if runtime == null or not runtime.synchronized or not runtime._playing: return false
	var current_tick := int(runtime.tick)
	if runtime.desync_count > (1 if corrupted else 0):
		_fail("unplanned deterministic mismatch at tick %d" % current_tick)
		return false
	if phase == 0:
		phase = 1
		if role == "spectator":
			if runtime.submit_command({"op":"stop", "unit_id":1}): _fail("spectator controlled a unit")
		else:
			_orders()
	if phase == 1 and current_tick >= 90:
		phase = 2
		if role != "spectator": _build()
	# Deliberately corrupt only the guest, then demand a full repair followed
	# by many successfully acknowledged incremental frames.
	if role != "spectator" and not runtime.is_host and current_tick >= 210 and not corrupted:
		corrupted = true
		runtime.match_state.resources[0][0] += 7
	if phase == 2 and current_tick >= 300 and role != "spectator":
		phase = 3
		for unit in runtime.entities.get_children():
			if unit is UnitAgent and unit.team == runtime.local_team and unit.def.id == &"villager":
				_send({"op":"move", "unit_id":runtime.entity_id(unit), "pos":[0,25]})
				break
	if current_tick >= 450:
		_write_report()
	# Frames span physics ticks; end between frames like a real result would.
	if runtime.is_host and runtime._frame_step == 0 and FileAccess.file_exists(finish_file):
		runtime.match_state.set_winner(Enums.Team.AI)
	return false

func _orders() -> void:
	var side := int(runtime.local_team)
	var sign_value := -1 if side == 0 else 1
	var villagers: Array = []
	var town: Node
	var resource: Node
	for entity in runtime.entities.get_children():
		if entity is UnitAgent and entity.team == side and entity.def.id == &"villager": villagers.append(entity)
		if entity is BuildingAgent and entity.team == side and entity.def.id == &"town_center": town = entity
		if entity is ResourceNode and entity.resource_type == 1 and signf(entity.sim_pos.x) == sign_value:
			if resource == null or entity.sim_pos.distance_squared_to(Vector2(sign_value * 120, sign_value * 120)) < resource.sim_pos.distance_squared_to(Vector2(sign_value * 120, sign_value * 120)): resource = entity
	if villagers.size() < 3 or town == null or resource == null:
		_fail("keyframe omitted playable objects")
		return
	_send({"op":"move", "unit_id":runtime.entity_id(villagers[0]), "pos":[villagers[0].sim_pos.x + 8, villagers[0].sim_pos.y + 8]})
	_send({"op":"gather", "unit_id":runtime.entity_id(villagers[1]), "target_id":runtime.entity_id(resource)})
	_send({"op":"train", "building_id":runtime.entity_id(town), "unit_def_id":"villager"})

func _build() -> void:
	var side := int(runtime.local_team)
	var sign_value := -1 if side == 0 else 1
	var villagers: Array = []
	for entity in runtime.entities.get_children():
		if entity is UnitAgent and entity.team == side and entity.def.id == &"villager": villagers.append(entity)
	if villagers.size() >= 3:
		_send({"op":"place_building", "builder_id":runtime.entity_id(villagers[2]), "building_def_id":"house", "pos":[sign_value * 100, sign_value * 145] if default_map else [sign_value*30,sign_value*60]})

func _send(command: Dictionary) -> void:
	if not runtime.submit_command(command): _fail("command was not queued")
	commands_sent += 1

func _write_report() -> void:
	var report := {"role":role, "team":runtime.local_team, "host_team":session.host_team, "tick":runtime.tick,
		"checksum":runtime.last_checksum, "desyncs":runtime.desync_count, "corrupted":corrupted,
		"keyframes":runtime.keyframes_received, "keyframes_sent":runtime.keyframes_sent,
		"frames":frame_packets, "frame_bytes":frame_bytes, "keyframe_bytes":keyframe_bytes,
		"commands":received_commands, "commands_sent":commands_sent, "first_keyframe_tick":first_keyframe_tick}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report))

func _ended(info: Dictionary) -> void:
	if done: return
	if runtime == null or int(runtime.tick) < 450 or info.get("reason") != "completed":
		_fail("unexpected end: " + str(info))
		return
	_write_report()
	done = true
	print("INCREMENTAL E2E PASSED: ", role, " tick=", runtime.tick)
	quit(0)

func _fail(message: String) -> void:
	if done: return
	done = true
	push_error("INCREMENTAL E2E FAILED: " + message)
	quit(1)

func _dump_restored(at_tick: int) -> void:
	var net := arena.get_node("NetworkMatch")
	var file := FileAccess.open(output + ".restored-%d" % at_tick, FileAccess.WRITE)
	file.store_string(JSON.stringify(net.simulation.capture(), "", true, true))
