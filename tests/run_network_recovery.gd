extends SceneTree

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func settle() -> void:
	await process_frame
	await process_frame

func _run() -> void:
	var game := root.get_node("GameSession")
	var network := root.get_node("NetworkSession")
	# Reproduce a disconnect after match_found but before the new scene is ready.
	game.online_active = true
	game.online_team = 1
	game.match_map_data = {}
	network.state = "matched"
	network.team = 1
	network._fail("测试连接已断开")
	var scene := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(scene)
	current_scene = scene
	await settle()
	var state: MatchState = scene.get_node("Bootstrap").match_state
	var hud := scene.get_node("UILayer/HUD")
	check(state.frozen and state.winner == -1, "connection loss freezes without inventing a winner")
	check(hud._result_panel.visible and hud._result_label.text == "测试连接已断开", "scene transition preserves and displays disconnect reason")
	check(hud._return_button.text == "返回联机大厅", "result return destination is clear")
	check(scene.get_node("NetworkMatch").find_child("LeaveMatch", true, false) != null, "always provides a leave control")
	var fog: Node = scene.get_meta("fog_holder")
	fog.set_debug_mode(true)
	fog.set_view(-1)
	check(not fog.debug_mode and fog.view_team == 1, "online fog debug cannot reveal opponent")
	hud._return_button.pressed.emit()
	await settle()
	check(current_scene.page == "online", "return button returns to online lobby")
	check(not game.online_active and network.state == "idle", "return clears connection and match state")
	check(not current_scene._online._start.disabled, "user can match again after disconnect")
	print("NETWORK RECOVERY %d checks / %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
