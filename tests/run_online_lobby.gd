extends SceneTree

var checks := 0
var failures: Array[String] = []

class FakeNetwork extends Node:
	var state := "idle"
	var joins := 0
	var leaves := 0
	var queue_arguments: Array = []
	var join_error: Error = OK
	func join_queue(url: String, player_name: String, civ: String) -> Error:
		joins += 1
		queue_arguments = [url, player_name, civ]
		if join_error == OK:
			state = "queued"
		return join_error
	func cancel_queue() -> void:
		state = "idle"
	func leave() -> void:
		leaves += 1
		state = "idle"

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _settle() -> void:
	await process_frame
	await process_frame

func _run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	var session := root.get_node("GameSession")
	session.online_active = false
	session.online_return_to_lobby = false
	var menu := load("res://scenes/civ_select.tscn").instantiate() as Control
	root.add_child(menu)
	current_scene = menu
	await _settle()
	check(menu.page == "main", "normal startup remains on main menu")
	menu._multiplayer_pressed()
	var lobby: Control = menu._online
	check(menu.page == "online" and lobby.visible and not menu._setup.visible, "online has a separate page")
	check(lobby._server_url.text == "ws://127.0.0.1:8001/ws", "default Python service endpoint")
	var network := FakeNetwork.new()
	lobby._network = network
	lobby._refresh_controls()
	lobby._server_url.text = "http://localhost:8001"
	lobby.start_matchmaking()
	check(network.joins == 0 and "ws://" in lobby._status.text, "HTTP URL rejected before connection")
	lobby._server_url.text = "ws://127.0.0.1:8001/ws"
	lobby._nickname.text = "   "
	lobby.start_matchmaking()
	check(network.joins == 0 and "昵称" in lobby._status.text, "empty nickname rejected")
	lobby._nickname.text = "  双人测试  "
	lobby._civ.select(1)
	lobby.start_matchmaking()
	check(network.joins == 1 and network.queue_arguments == ["ws://127.0.0.1:8001/ws", "双人测试", "teutons"], "queue receives endpoint trimmed nickname and civilization")
	check(not lobby._server_url.editable and not lobby._nickname.editable and lobby._civ.disabled and lobby._start.disabled, "waiting locks all matchmaking inputs")
	check(not lobby._cancel.disabled and not lobby._back.disabled, "waiting allows cancel and return")
	lobby.start_matchmaking()
	check(network.joins == 1, "duplicate queue request prevented")
	lobby._on_status_changed("等待其他玩家…")
	check(lobby._status.text == "等待其他玩家…", "network status is displayed")
	lobby.cancel_matchmaking()
	check(network.state == "idle" and not lobby._start.disabled and lobby._server_url.editable, "cancel enables retry")
	check(lobby._cancel.disabled, "cancel disabled when idle")
	network.join_error = ERR_CANT_CONNECT
	lobby.start_matchmaking()
	check("无法连接" in lobby._status.text and not lobby._start.disabled, "failed connection reports error and permits retry")
	network.join_error = OK
	lobby.start_matchmaking()
	lobby.go_back()
	check(network.leaves == 1 and network.state == "idle" and menu.page == "main", "back leaves active queue before returning")
	menu._multiplayer_pressed()
	lobby._on_matched({"team": 1, "players": [{"team": 0, "civ": "chinese"}]})
	check(current_scene == menu and not session.online_active and "不完整" in lobby._status.text, "malformed match cannot enter a scene")
	check(not lobby._configure_match({"team": 0, "players": {}}), "non-array player list rejected")
	session.match_map_data = {"old": "custom map"}
	var match_info := {"team": 1, "players": [{"team": 1, "civ": "chinese"}, {"team": 0, "civ": "teutons"}]}
	check(lobby._configure_match(match_info), "valid matching information accepted")
	check(session.player_civ_id == &"teutons" and session.ai_civ_id == &"chinese", "world civilizations mapped by team even when reversed")
	check(session.match_map_data.is_empty() and session.match_ai_mode == "sandbox", "online match clears custom map and AI mode")
	check(session.online_active and session.online_team == 1, "online guest assigned its local team")
	check(session.local_team() == 1, "guest controls the second world team")
	menu.show_single_player()
	check(not session.online_active and session.local_team() == 0, "singleplayer resets online perspective")
	menu._multiplayer_pressed()
	for viewport_size in [Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		root.size = viewport_size
		await _settle()
		for path in ["ServerUrl", "Nickname", "Civilization", "Status", "Start", "Cancel", "Back"]:
			var control: Control = lobby.get_node(path)
			var rect := control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)
			check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(rect), "online control fits viewport: " + path)
	if "--render" in OS.get_cmdline_user_args():
		root.size = Vector2i(1280, 720)
		await _settle()
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://.godot/online-lobby.png") == OK, "save lobby screenshot")
	menu.free()
	current_scene = null
	network.free()
	session.online_return_to_lobby = true
	session.menu_notice = "对手已离开对局。"
	menu = load("res://scenes/civ_select.tscn").instantiate() as Control
	root.add_child(menu)
	current_scene = menu
	await _settle()
	check(menu.page == "online" and menu._online._status.text == "对手已离开对局。", "return from online match restores lobby with notice")
	check(not session.online_return_to_lobby and session.menu_notice.is_empty(), "return flags consumed once")
	menu.free()
	current_scene = null
	print("ONLINE LOBBY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
