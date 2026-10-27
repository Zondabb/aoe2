extends SceneTree

var _checks := 0
var _failures := 0

class FakeNetwork extends Node:
	var state := "idle"
	var requests := 0
	var watched := ""
	func request_matches(_url: String) -> Error:
		requests += 1
		state = "browsing"
		return OK
	func watch_match(_url: String, match_id: String) -> Error:
		watched = match_id
		state = "connecting"
		return OK
	func leave() -> void:
		state = "idle"

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	await process_frame
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	var game := root.get_node("GameSession")
	game.online_active = false
	game.online_spectator = false
	var menu: Control = load("res://scenes/civ_select.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	await process_frame
	menu._multiplayer_pressed()
	var lobby: Control = menu._online
	var fake := FakeNetwork.new()
	root.add_child(fake)
	lobby._network = fake
	lobby._toggle_browse()
	check(lobby._browse_open and lobby.get_node("LiveMatches").visible, "browse opens the live-match panel")
	check(fake.requests == 1 and fake.state == "browsing", "browse requests matches from the configured service")
	check(not lobby.get_node("Start").visible and not lobby.get_node("Nickname").visible, "watching does not ask the observer to queue or choose a civilization")
	var match_id := "a".repeat(32)
	var entries: Array = JSON.parse_string(JSON.stringify([{
		"match_id": match_id,
		"players": [{"team": 0, "name": "春雨", "civ": "chinese"}, {"team": 1, "name": "远山", "civ": "teutons"}],
		"elapsed_seconds": 125, "spectator_count": 3,
	}]))
	lobby._on_matches_received(entries)
	check(lobby._matches_list.get_child_count() == 1, "one live match produces one row")
	var row: Node = lobby._matches_list.get_child(0)
	check(row.get_child(0).text.contains("春雨") and row.get_child(0).text.contains("远山"), "real JSON numeric teams preserve both player names")
	check(row.get_child(1).text.contains("02:05") and row.get_child(1).text.contains("3"), "row displays duration and spectator count")
	row.get_node("Watch").pressed.emit()
	check(fake.watched == match_id, "watch sends the selected room identifier")
	check(row.get_node("Watch").disabled, "in-flight join cannot be clicked repeatedly")
	fake.state = "browsing"
	lobby._on_matches_received([])
	check(lobby._matches_list.get_child_count() == 0 and lobby._matches_notice.text.contains("暂无"), "stale rooms disappear and the empty state is clear")
	var info: Dictionary = JSON.parse_string(JSON.stringify({"role": "spectator", "players": entries[0].players}))
	check(lobby._configure_match(info), "spectator roster is accepted without a playing team")
	check(game.online_active and game.online_spectator and game.local_team() == -1, "observer has no controlling team")
	game.online_spectator = false
	var invalid := info.duplicate(true)
	invalid.players[1].team = 0
	check(not lobby._configure_match(invalid), "duplicate team roster cannot enter a scene")
	lobby._toggle_browse()
	check(not lobby._browse_open and lobby.get_node("Start").visible, "return to matchmaking restores the player form")
	check(fake.state == "idle", "leaving the browser releases its connection")
	menu.show_single_player()
	check(not game.online_active and not game.online_spectator and game.local_team() == 0, "single player clears spectator identity")
	menu._multiplayer_pressed()
	lobby._toggle_browse()
	lobby._on_matches_received(entries)
	for viewport_size in [Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		root.size = viewport_size
		await process_frame
		await process_frame
		for path in ["ServerUrl", "LiveMatches", "BrowseMatches", "Back"]:
			var control: Control = lobby.get_node(path)
			var bounds := control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)
			check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(bounds), "spectator browser fits %s: %s" % [viewport_size, path])
	if "--render" in OS.get_cmdline_user_args():
		root.size = Vector2i(1280, 720)
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://.godot/spectator-browser.png") == OK, "browser preview saved")
	menu.free()
	current_scene = null
	fake.free()
	game.online_active = false
	game.online_spectator = false
	print("SPECTATOR UI: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
