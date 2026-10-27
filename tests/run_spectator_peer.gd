extends SceneTree
## Actual player/spectator process used by tools/test_spectator_e2e.py.

const Commands := preload("res://scripts/input/player_commands.gd")
const VILLAGER := preload("res://data/units/villager.tres")
const HOUSE := preload("res://data/buildings/house.tres")

var network: Node
var session: Node
var match_root: Node
var runtime: Node
var role := "player"
var label := "SpectatorPeer"
var endpoint := ""
var finish_file := ""
var ready_file := ""
var checks := 0
var phase := 0
var done := false
var failed := false
var joined_at := 0
var started_at := 0
var first_sequence := -1
var tracked_id := -1
var first_position := Vector2.ZERO
var saw_movement := false
var last_move_at := 0
var direction := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	started_at = Time.get_ticks_msec()
	network = root.get_node("NetworkSession")
	session = root.get_node("GameSession")
	var arguments := OS.get_cmdline_user_args()
	endpoint = arguments[0]
	role = arguments[1]
	label = arguments[2]
	finish_file = arguments[3]
	ready_file = arguments[4]
	network.matched.connect(_matched)
	network.ended.connect(_ended)
	network.status_changed.connect(func(message: String): print(label, ": ", message))
	if role == "player":
		check(network.join_queue(endpoint, label, "chinese") == OK, "player connects")
	else:
		network.matches_received.connect(_matches)
		check(network.request_matches(endpoint) == OK, "spectator browser connects")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failed = true
		push_error("SPECTATOR E2E PEER FAILED: " + message)
		quit(1)


func _matches(matches: Array) -> void:
	if phase != 0 or done:
		return
	check(not matches.is_empty(), "in-game network browser lists the live match")
	if matches.is_empty(): return
	var info: Dictionary = matches[0]
	check(info.get("players", []).size() == 2, "watch list includes both players")
	phase = 1
	check(network.watch_match(endpoint, String(info.match_id)) == OK, "late spectator joins selected match")


func _matched(info: Dictionary) -> void:
	session.online_active = true
	session.online_spectator = role != "player"
	session.online_team = int(info.get("team", -1))
	session.player_civ_id = StringName(info.players[0].civ)
	session.ai_civ_id = StringName(info.players[1].civ)
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	if role != "player":
		check(info.get("role") == "spectator", "relay assigns explicit spectator role")
	joined_at = Time.get_ticks_msec()
	match_root = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(match_root)
	current_scene = match_root


func _process(_delta: float) -> bool:
	if failed: return false
	if done: return false
	if started_at > 0 and Time.get_ticks_msec() - started_at > 55000:
		push_error("SPECTATOR E2E PEER TIMEOUT: " + label)
		quit(1)
		return false
	if network == null or match_root == null or network.state not in ["playing", "watching"]:
		return false
	runtime = match_root.get_node_or_null("NetworkMatch")
	if runtime == null or not runtime.get("_playing"):
		return false
	if role == "player":
		_player_tick()
	else:
		_spectator_tick()
	return false


func _player_tick() -> void:
	if phase == 0:
		check(not session.online_spectator and network.team in [0, 1], "real player keeps its team")
		phase = 1
	if network.team != 0: return
	if FileAccess.file_exists(finish_file):
		phase = 2
		match_root.get_node("Bootstrap").match_state.set_winner(Enums.Team.AI)
		return
	if Time.get_ticks_msec() - last_move_at < 1400: return
	last_move_at = Time.get_ticks_msec()
	for unit in match_root.get_node("Entities").get_children():
		if unit is UnitAgent and unit.team == 0:
			if tracked_id < 0:
				tracked_id = runtime.entity_id(unit)
				first_position = unit.sim_pos
			if runtime.entity_id(unit) == tracked_id:
				direction = -direction
				Commands.unit_order(match_root, unit, "move", first_position + Vector2(direction * 8.0, 0.0))
				break


func _spectator_tick() -> void:
	if int(runtime.get("_last_snapshot_sequence")) < 1: return
	if phase == 1:
		check(network.state == "watching" and network.spectator, "transport stays in spectator state")
		check(session.local_team() == -1 and runtime.local_team == -1 and not runtime.is_host, "spectator is neither playing team nor host")
		check(not network.latest_snapshot.is_empty(), "snapshot cached across scene construction")
		check(match_root.get_node_or_null("PlayerAiControl") == null and match_root.get_node_or_null("AiGateway") == null, "spectator has no AI command controller")
		var selection := match_root.get_node("UILayer/SelectionController")
		var hud := match_root.get_node("UILayer/HUD")
		check(selection.read_only and hud.read_only, "selection and HUD are read-only")
		check(not hud._commands_enabled(), "HUD cannot issue training or research")
		check(match_root.get_node("UILayer/HUD/Minimap").read_only, "minimap cannot order either side")
		var units := {}
		for unit in match_root.get_node("Entities").get_children():
			if unit is UnitAgent and not units.has(int(unit.team)):
				units[int(unit.team)] = unit
				check(unit.get_meta("network_replica", false) and not unit.is_physics_processing(), "observed units do not locally simulate")
		check(units.has(0) and units.has(1), "late join reconstructs both armies")
		if not units.has(0) or not units.has(1): return
		var holder: Node = match_root.get_meta("fog_holder")
		var controls: Node = match_root.get_node("UILayer/SpectatorControls")
		for view in [0, 1, -1]:
			var index: int = {0: 1, 1: 2, -1: 0}[view]
			controls._on_view_selected(index)
			check(controls._choice.selected == index, "in-game spectator dropdown reflects view %d" % view)
			check(holder.view_team == view, "spectator can select view %d" % view)
			for side in [0, 1]:
				check(holder.view_can_see(units[side]) == (view == -1 or view == side), "view %d enforces team %d visibility" % [view, side])
			var before_seq: int = network._command_seq
			for side in [0, 1]:
				var unit: Node2D = units[side]
				selection._clear_selection()
				selection._add_selection(unit)
				selection._issue_move(unit.sim_pos + Vector2(30.0, 30.0))
				Commands.unit_order(selection, unit, "stop")
				check(not runtime.submit_command({"op": "stop", "unit_id": runtime.entity_id(unit)}), "runtime refuses a team %d order" % side)
				check(not runtime.execute_team_command({"op": "stop", "unit_id": runtime.entity_id(unit)}, side), "spectator cannot execute host commands")
			check(not network.send_command({"op": "stop", "unit_id": runtime.entity_id(units[0])}), "transport refuses direct command")
			check(network._command_seq == before_seq, "view switch does not enable command transmission")
			check(not match_root.get_node("BuildSystem").begin_placement(HOUSE), "spectator cannot place a building")
			check(not hud._can_enqueue(VILLAGER), "spectator cannot queue units")
		tracked_id = runtime.entity_id(units[0])
		first_position = units[0].sim_pos
		first_sequence = int(runtime.get("_last_snapshot_sequence"))
		phase = 2
		return
	if phase == 2:
		var unit: Node2D = runtime._resolve(tracked_id)
		if is_instance_valid(unit) and unit.sim_pos.distance_to(first_position) > 0.2:
			saw_movement = true
		if int(runtime.get("_last_snapshot_sequence")) < first_sequence + 5 or not saw_movement:
			return
		check(true, "live snapshots continue and replicate player movement")
		phase = 3
		if role == "watch-leave":
			network.leave()
			check(network.state == "idle", "observer can leave its membership")
			_pass()
		else:
			var ready := FileAccess.open(ready_file, FileAccess.WRITE)
			check(ready != null, "completion barrier can be written")
			if ready != null: ready.store_string("spectator ready\n")


func _ended(info: Dictionary) -> void:
	if done: return
	check(role != "watch-leave", "active observer was not prematurely ended")
	check(int(info.get("winner", -1)) == 1 and info.get("reason") == "completed", "normal player result reaches observer and players")
	check(phase >= (1 if role == "player" else 3), "all spectator checks completed before result")
	await process_frame
	var state: MatchState = match_root.get_node("Bootstrap").match_state
	check(state.frozen and state.winner == 1, "match result freezes the observer replica")
	_pass()


func _pass() -> void:
	if failed:
		quit(1)
		return
	done = true
	print("SPECTATOR E2E PEER PASSED %s checks=%d" % [label, checks])
	quit(0)
