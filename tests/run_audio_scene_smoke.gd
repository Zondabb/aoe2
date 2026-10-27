extends SceneTree
## Exercises real scene wiring, fog filtering, playback, and shared controls.

var _events: Array[StringName] = []
var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)

func _run() -> void:
	await process_frame
	root.size = Vector2i(1280, 720)
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "sandbox"
	var audio := root.get_node("GameAudio")
	audio.set_muted(false)
	audio.set_master_volume(0.8)
	audio.event_played.connect(func(event: StringName, _category: StringName): _events.append(event))
	var menu: Node = load("res://scenes/civ_select.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	await process_frame
	check(menu.has_node("Design/MainPage/AudioControls"), "menu sound controls installed")
	menu.free()
	var scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	var observer := scene.get_node_or_null("MatchAudio")
	check(observer != null, "normal match installs world audio")
	var controls := scene.get_node("UILayer/HUD/AudioControls") as Control
	check(controls.is_visible_in_tree(), "HUD sound controls visible")
	check(controls.get_global_rect().end.x <= root.get_visible_rect().end.x, "sound controls fit screen")
	var performance := scene.get_node("UILayer/PerformanceOverlay") as Control
	check(not controls.get_global_rect().intersects(performance.get_global_rect()), "audio controls do not overlap performance overlay")
	var unit: Node2D
	for child in scene.get_node("Entities").get_children():
		if child is UnitAgent and child.team == 0:
			unit = child
			break
	check(unit != null, "player unit spawned")
	if unit != null:
		var camera: Camera2D = scene.get_node("Camera2D")
		camera.set_process(false)
		camera.focus_on(unit.sim_pos)
		camera.force_update_scroll()
		check(audio.source_audible(unit), "player base is visible and in camera")
		audio.stop_all()
		unit.audio_cue.emit(&"melee")
		check(_events.has(&"melee"), "real match entity sound reaches audio output")
		_events.clear()
		var state: MatchState = scene.get_node("Bootstrap").match_state
		state.winner_decided.emit(0)
		check(_events.has(&"victory"), "real match victory reaches audio output")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot=") and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(argument.trim_prefix("--screenshot="))
	scene.free()
	await process_frame
	audio.stop_all()
	print("AUDIO SCENE SMOKE: %d failures" % _failures)
	quit(1 if _failures else 0)
