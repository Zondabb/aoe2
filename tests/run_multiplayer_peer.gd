extends SceneTree

## Real-process test peer. Launch two against the Python relay using the runner.
const Commands := preload("res://scripts/input/player_commands.gd")
const VILLAGER := preload("res://data/units/villager.tres")
const HOUSE := preload("res://data/buildings/house.tres")
var network: Node
var session: Node
var match_root: Node
var runtime: Node
var elapsed := 0.0
var playing_elapsed := 0.0
var phase := 0
var checks := 0
var own_unit: Node2D
var own_start := Vector2.ZERO
var initial_population := 0
var completed := false
var received_ops: Dictionary = {}
var removed_id := -1
var end_scheduled := false
var combat_target: Node2D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	network = root.get_node("NetworkSession")
	session = root.get_node("GameSession")
	network.matched.connect(_matched)
	network.ended.connect(_ended)
	network.message_received.connect(_message)
	network.status_changed.connect(func(message: String): print("NETWORK: ", message))
	# Exercise the actual training/construction paths without a 25-second wait.
	VILLAGER.set("train_time", 0.5)
	HOUSE.set("build_time", 0.5)
	var args := OS.get_cmdline_user_args()
	var url := args[0] if not args.is_empty() else "ws://127.0.0.1:8001/ws"
	_check(network.join_queue(url, "Integration", "chinese") == OK, "connect request")

func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		push_error("MULTIPLAYER PEER FAILED: " + label)
		quit(1)

func _matched(info: Dictionary) -> void:
	print("MATCHED team=", info.team)
	session.online_active = true
	session.online_team = int(info.team)
	session.player_civ_id = StringName(info.players[0].civ)
	session.ai_civ_id = StringName(info.players[1].civ)
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	match_root = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(match_root)
	current_scene = match_root

func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > 45.0:
		push_error("MULTIPLAYER PEER TIMEOUT phase=%d ops=%s" % [phase, received_ops])
		quit(1)
		return false
	if network == null or network.state != "playing" or match_root == null:
		return false
	runtime = match_root.get_node_or_null("NetworkMatch")
	if runtime == null or match_root.get_node("Entities").get_child_count() < 15:
		return false
	playing_elapsed += delta
	if phase == 0:
		_check(match_root.get_node_or_null("AiController") == null, "online AI disabled")
		_check(match_root.get_node_or_null("AiGateway") == null, "online AI gateway disabled")
		_check(Commands.local_team(match_root) == network.team, "local team routing")
		_check(match_root.get_meta("fog_holder").view_team == network.team, "local fog team")
		for node in match_root.get_node("Entities").get_children():
			if node.get("def") is UnitDef and node.team == network.team:
				own_unit = node
				break
		_check(own_unit != null, "own unit replicated")
		own_start = own_unit.sim_pos
		initial_population = match_root.get_node("Bootstrap").match_state.population[network.team]
		var selection: Node = match_root.get_node("UILayer/SelectionController")
		selection._add_selection(own_unit)
		selection._issue_move(own_start + Vector2(4 if network.team == 0 else -4, 0))
		phase = 1
	if network.team == 0:
		_run_host()
	else:
		_run_guest()
	return false

func _run_host() -> void:
	if phase == 1 and own_unit.sim_pos.distance_to(own_start) > 1:
		_check(true, "host local movement simulated")
		phase = 2
	if phase == 2 and received_ops.has("place_building") and received_ops.has("train") and received_ops.has("gather"):
		var house := _house(1)
		var state: MatchState = match_root.get_node("Bootstrap").match_state
		if house != null and house.is_complete and state.population[1] > initial_population:
			_check(state.get_resource(1, Enums.ResourceType.WOOD) == 170, "remote construction charged once")
			_check(state.get_resource(1, Enums.ResourceType.FOOD) <= 200, "remote training charged")
			combat_target = load("res://scenes/entities/unit_view.tscn").instantiate()
			combat_target.set("def", load("res://data/units/swordsman.tres"))
			combat_target.set("team", 0)
			combat_target.set("sim_pos", Vector2(26, 38))
			combat_target.set("match_state", state)
			match_root.get_node("Entities").add_child(combat_target)
			combat_target.hp = 1
			phase = 3
	if phase == 3 and playing_elapsed > 12 and received_ops.has("attack") and not is_instance_valid(combat_target) and not end_scheduled:
		end_scheduled = true
		# Removing an authoritative object must remove its replica next snapshot.
		var house := _house(1)
		removed_id = runtime.entity_id(house)
		house.queue_free()
		_finish_later()

func _finish_later() -> void:
	await create_timer(2.0).timeout
	for node in match_root.get_node("Entities").get_children():
		if node.get("def") is BuildingDef and node.def.id == &"town_center" and node.team == 0:
			node.take_damage(100000)
			break

func _run_guest() -> void:
	var selection: Node = match_root.get_node("UILayer/SelectionController")
	var hud: Node = match_root.get_node("UILayer/HUD")
	if phase == 1 and own_unit.sim_pos.distance_to(own_start) > 1:
		_check(own_unit.get_meta("network_replica", false), "guest is a replica")
		_check(not own_unit.is_physics_processing(), "guest does not simulate")
		hud._stop_selected_units()
		var build: Node = match_root.get_node("BuildSystem")
		_check(build.begin_placement(HOUSE), "guest begins construction preview")
		build._ghost.sim_pos = Vector2(31, 39)
		_check(build.confirm_placement(), "guest submits foundation")
		selection._clear_selection()
		for node in match_root.get_node("Entities").get_children():
			if node.get("def") is BuildingDef and node.team == 1 and node.def.id == &"town_center":
				selection._add_selection(node)
				break
		_check(hud._can_enqueue(VILLAGER), "guest may train own civilization")
		hud._enqueue_train(VILLAGER)
		phase = 2
	if phase == 2:
		var house := _house(1)
		var state: MatchState = match_root.get_node("Bootstrap").match_state
		if house != null and house.is_complete and state.population[1] > initial_population:
			_check(state.get_resource(1, Enums.ResourceType.WOOD) == 170, "guest receives resources")
			_check(state.population_cap[1] == 10, "guest receives construction population cap")
			removed_id = runtime.entity_id(house)
			selection._clear_selection()
			selection._add_selection(own_unit)
			for node in match_root.get_node("Entities").get_children():
				if node.has_method("extract") and node.resource_type == Enums.ResourceType.FOOD and node.sim_pos.x > 0:
					selection._issue_gather(node)
					break
			phase = 3
	if phase == 3:
		for node in match_root.get_node("Entities").get_children():
			if node.get("def") is UnitDef and node.def.id == &"swordsman" and node.team == 0:
				combat_target = node
				selection._issue_attack(node)
				phase = 4
				break
	if phase == 4 and not is_instance_valid(combat_target):
		_check(true, "remote attack and death replicated")
		phase = 5
	if phase == 5 and _house(1) == null:
		_check(true, "authoritative removal replicated")
		phase = 6

func _house(team: int) -> Node2D:
	for node in match_root.get_node("Entities").get_children():
		if not node.is_queued_for_deletion() and node.get("def") is BuildingDef and node.def.id == &"house" and node.team == team and not node.is_placement_ghost:
			return node
	return null

func _message(message: Dictionary) -> void:
	if message.type == "command":
		received_ops[message.command.op] = true
	elif message.type == "snapshot" and message.seq == 1:
		print("FIRST SNAPSHOT entities=", message.state.entities.size())
		var active_runtime := match_root.get_node("NetworkMatch")
		for record in message.state.entities:
			if not active_runtime._valid_record(record):
				print("INVALID RECORD: ", record)

func _ended(info: Dictionary) -> void:
	if completed:
		return
	completed = true
	_check(int(info.winner) == 1, "winner delivered")
	_check(info.reason == "completed", "normal match completion")
	_check(phase >= (3 if session.online_team == 0 else 6), "all gameplay phases completed")
	await process_frame
	var state: MatchState = match_root.get_node("Bootstrap").match_state
	_check(state.frozen and state.winner == 1, "both peers freeze on result")
	print("MULTIPLAYER PEER PASSED team=%d checks=%d" % [session.online_team, checks])
	quit(0)
