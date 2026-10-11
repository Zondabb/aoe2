extends SceneTree

const Loader := preload("res://scripts/world/map_loader.gd")
var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _settle() -> void:
	for frame in 4:
		await process_frame


func _key(pressed := true, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_F3
	event.physical_keycode = KEY_F3
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)


func _run() -> void:
	var previous_cap := Engine.max_fps
	var previous_speed := Engine.time_scale
	Engine.max_fps = 60
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	var session := root.get_node("GameSession")
	session.match_map_data = Loader.load_file("res://data/maps/editor_demo.json").data
	session.match_ai_mode = "sandbox"
	session.online_active = false
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	await _settle()
	var overlay = world.get_node("UILayer/PerformanceOverlay")
	var summary: Label = overlay.get_node("Column/Summary")
	var details: Label = overlay.get_node("Column/Details")
	var save_controls := world.get_node("UILayer/SaveGameControls")
	check(overlay.visible and not details.visible, "FPS is visible by default with detail view collapsed")
	for child in [overlay, overlay.get_node("Column"), summary, details]:
		check(child.mouse_filter == Control.MOUSE_FILTER_IGNORE, "performance overlay lets world clicks through: " + child.name)
	var compact_height: float = overlay.size.y
	_key()
	await _settle()
	check(overlay.detailed and details.visible, "F3 reaches overlay through actual game input")
	_key(true, true)
	_key(false)
	await _settle()
	check(overlay.detailed, "keyboard repeat and key release do not toggle details")
	await create_timer(0.7, true, false, true).timeout
	check(summary.text.contains("FPS ") and not summary.text.contains("--"), "wall-clock sample displays real FPS and frame interval")
	check(details.text.contains("引擎帧") and details.text.contains("绘制调用") and details.text.contains("单位"), "detail view reports timing, draw calls, and world counts")
	check(overlay._counts.x == get_nodes_in_group("units").size() and overlay._counts.z == get_nodes_in_group("resource_nodes").size(), "detail counts match live entity groups")
	for viewport_size in [Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		root.size = viewport_size
		await _settle()
		var bounds := Rect2(Vector2.ZERO, Vector2(viewport_size))
		check(bounds.encloses(overlay.get_global_rect()), "expanded performance display fits viewport %s" % viewport_size)
		check(is_equal_approx(overlay.get_global_rect().end.x, viewport_size.x - 10.0), "performance panel maintains its right margin at %s" % viewport_size)
		for button in save_controls.get_node("Buttons").get_children():
			check(not overlay.get_global_rect().intersects(button.get_global_rect()), "performance display avoids save/menu button at %s" % viewport_size)
		check(not overlay.get_global_rect().intersects(save_controls.get_node("SaveNotice").get_global_rect()), "performance display avoids save notices at %s" % viewport_size)
		check(not overlay.get_global_rect().intersects(world.get_node("UILayer/HUD/ResourceTopBar").get_global_rect()), "performance display avoids resource bar at %s" % viewport_size)
	root.size = Vector2i(1280, 720)
	# A 16-fold simulation speed change must not rescale the real-time FPS counter.
	Engine.time_scale = 0.25
	overlay.set_detailed(true)
	await create_timer(0.75, true, false, true).timeout
	var slow_fps: float = summary.text.get_slice(" ", 1).to_float()
	check(slow_fps > 0.0 and details.text.contains("×0.25"), "slow simulation keeps a real-time FPS sample and distinct speed")
	Engine.time_scale = 4.0
	overlay.set_detailed(true)
	await create_timer(0.75, true, false, true).timeout
	var fast_fps: float = summary.text.get_slice(" ", 1).to_float()
	check(fast_fps > slow_fps * 0.35 and fast_fps < slow_fps * 3.0 and details.text.contains("×4.00"), "FPS is independent of simulation time scaling")
	paused = true
	await create_timer(0.7, true, false, true).timeout
	check(details.text.contains("暂停"), "performance display continues sampling while game is paused")
	var existing_count: int = overlay._counts.x
	var temporary_unit := Node.new()
	world.add_child(temporary_unit)
	temporary_unit.add_to_group("units")
	await create_timer(1.1, true, false, true).timeout
	check(overlay._counts.x == existing_count + 1, "low-frequency counts notice newly spawned entities")
	temporary_unit.free()
	await create_timer(1.1, true, false, true).timeout
	check(overlay._counts.x == existing_count, "low-frequency counts drop freed entities")
	_key()
	await _settle()
	check(not overlay.detailed and not details.visible and overlay.size.y <= compact_height + 1.0, "F3 works when paused and collapses the panel")
	var count_sample: int = overlay._last_count_usec
	await create_timer(1.1, true, false, true).timeout
	check(overlay._last_count_usec == count_sample, "collapsed overlay does not scan entity groups")
	paused = false
	Engine.time_scale = previous_speed
	Engine.max_fps = previous_cap
	check(checks >= 35, "all performance overlay checks completed")
	if "--render" in OS.get_cmdline_user_args():
		overlay.set_detailed(true)
		await create_timer(0.7, true, false, true).timeout
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://.godot/performance-overlay.png") == OK, "save screenshot for visual verification")
	world.free()
	await process_frame
	print("PERFORMANCE OVERLAY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
