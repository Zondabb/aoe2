extends SceneTree

const Loader := preload("res://scripts/world/map_loader.gd")
var checks := 0
var failures: Array[String] = []
var slot_name := "__save_ui_test_%d" % Time.get_ticks_usec()
var slot_path := "user://saves/" + slot_name + ".json"
var bad_path := "res://.godot/save-ui-invalid.json"

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _settle() -> void:
	for frame in 4: await process_frame

func _capture(label: String) -> void:
	if "--render" not in OS.get_cmdline_user_args(): return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png("res://.godot/save-ui-%s.png" % label) == OK, "save UI screenshot")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.gui_embed_subwindows = true
	var session := root.get_node("GameSession")
	session.match_map_data = Loader.load_file("res://data/maps/editor_demo.json").data
	session.match_ai_mode = "sandbox"
	session.online_active = false
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await _settle()
	var controls = world.get_node("UILayer/SaveGameControls")
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.resources[0][Enums.ResourceType.WOOD] = 12345
	var unit: UnitAgent
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == 0:
			unit = entity
			break
	unit.hp = 11.0
	var initial_count: int = world.get_node("Entities").get_child_count()
	controls.get_node("Buttons/SaveButton").pressed.emit()
	check(paused and controls._dialog.visible, "save button opens picker and pauses the match")
	check(controls._dialog.saving, "save picker allows a named slot")
	var saved_position := unit.sim_pos
	await _settle()
	check(unit.sim_pos == saved_position, "simulation stays paused while choosing a slot")
	check(Rect2(Vector2.ZERO, Vector2(root.size)).encloses(Rect2(Vector2(controls._dialog.position), Vector2(controls._dialog.size))), "save picker fits viewport: %s at %s" % [controls._dialog.size, controls._dialog.position])
	await _capture("dialog")
	controls._dialog._name.text = "../outside"
	controls._dialog._refresh_action()
	check(controls._dialog.get_ok_button().disabled, "slot names cannot contain paths")
	controls._dialog._name.text = slot_name
	controls._dialog._refresh_action()
	controls._dialog.confirmed.emit()
	check(FileAccess.file_exists(slot_path), "confirming save creates the named file: " + controls._dialog._message.text)
	check(not paused and not controls._dialog.visible, "successful save closes picker and resumes game")
	check(controls._notice.text.contains("游戏已保存"), "saving gives visible feedback")
	await _capture("match")
	controls.open_save()
	var slot_index: int = controls._dialog._paths.find(slot_path)
	check(slot_index >= 0, "saved slot appears in the picker")
	controls._dialog._slot_selected(slot_index)
	check(controls._dialog.get_ok_button().text == "覆盖存档", "existing slot makes overwrite action explicit")
	controls._dialog.hide()
	check(not paused, "cancelling save releases pause")
	controls.get_node("Buttons/LoadButton").pressed.emit()
	check(paused and not controls._dialog.saving, "load button opens the load picker and pauses")
	var invalid := FileAccess.open(bad_path, FileAccess.WRITE)
	invalid.store_string("{broken")
	invalid.close()
	controls._load(bad_path)
	check(current_scene == world and paused and not controls._dialog._message.text.is_empty(), "invalid save keeps current match and displays error")
	state.resources[0][Enums.ResourceType.WOOD] = 2
	controls._load(slot_path)
	await _settle()
	world = current_scene
	state = world.get_node("Bootstrap").match_state
	check(not paused and world.name == "Match", "in-game load enters a resumed match")
	check(state.get_resource(0, Enums.ResourceType.WOOD) == 12345, "in-game load restores saved economy")
	check(world.get_node("Entities").get_child_count() == initial_count, "in-game load preserves entity count")
	var restored_damage := false
	for entity in world.get_node("Entities").get_children():
		if entity is UnitAgent and entity.team == 0 and is_equal_approx(entity.hp, 11.0): restored_damage = true
	check(restored_damage, "in-game load restores damaged unit")
	controls = world.get_node("UILayer/SaveGameControls")
	for viewport_size in [Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		root.size = viewport_size
		await _settle()
		for button in controls.get_node("Buttons").get_children():
			check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(button.get_global_rect()), "save controls fit viewport")
	controls._open_return()
	check(paused, "return confirmation pauses game")
	controls._return_dialog.confirmed.emit()
	await _settle()
	var menu = current_scene
	check(not paused and menu.page == "main", "returning to menu releases pause")
	check(menu.has_node("Design/MainPage/MenuPanel/LoadGame") and menu.has_node("Design/SinglePlayerPage/LoadGame"), "both menu pages expose loading")
	await _capture("menu")
	menu.get_node("Design/MainPage/MenuPanel/LoadGame").pressed.emit()
	check(menu._save_dialog.visible and not menu._save_dialog.saving, "main menu load opens slot picker")
	menu._load_saved_game(bad_path)
	check(current_scene == menu and not menu.starting, "bad menu save leaves menu usable")
	menu._load_saved_game(slot_path)
	await _settle()
	check(current_scene.name == "Match" and current_scene.get_node("Bootstrap").match_state.get_resource(0, Enums.ResourceType.WOOD) == 12345, "main menu resumes the saved game")
	current_scene.free()
	current_scene = null
	await _settle()
	session.online_active = true
	var online_controls: Control = load("res://scripts/ui/save_game_controls.gd").new()
	root.add_child(online_controls)
	check(not online_controls.visible and online_controls.get_node_or_null("Buttons") == null, "online matches hide single-player save controls")
	online_controls.free()
	session.online_active = false
	DirAccess.remove_absolute(ProjectSettings.globalize_path(slot_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path))
	print("SAVE GAME UI: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
