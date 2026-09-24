extends SceneTree

## Run with --headless for interaction/layout checks, or -- --render for PNGs.
var failures: Array[String] = []
var checks := 0
var render := false
var world: Node
var hud: Control
var selection: SelectionController2D
var build: BuildSystem
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	render = "--render" in OS.get_cmdline_user_args()
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	root.get_node("GameSession").player_civ_id = &"teutons"
	world = load("res://scenes/match_2d.tscn").instantiate()
	# Disable AI before its deferred startup, so UI tests never open HTTP requests.
	world.child_entered_tree.connect(func(child: Node):
		if child.name == "AiGateway":
			child.set("enabled", false))
	root.add_child(world)
	await _settle()
	hud = world.get_node("UILayer/HUD")
	selection = world.get_node("UILayer/SelectionController")
	build = world.get_node("BuildSystem")
	state = world.get_node("Bootstrap").match_state
	# Keep real event routing, but no AI, camera scrolling, or simulation drift.
	var gateway := world.get_node_or_null("AiGateway")
	if gateway != null:
		gateway.process_mode = Node.PROCESS_MODE_DISABLED
	world.get_node("Camera2D").set_process(false)
	selection.set_process(false)
	for entity in world.get_node("Entities").get_children():
		entity.set_physics_process(false)
	var villager: Node2D = world.get_node("Entities/PlayerVillager1")
	var town: Node2D = world.get_node("Entities/PlayerTownCenter")
	var enemy: Node2D = world.get_node("Entities/AiTownCenter")
	_select([villager])
	await _settle()
	for viewport_size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(1024, 768)]:
		root.size = viewport_size
		await _settle()
		_test_layout(viewport_size)
		await _capture("layout-%dx%d" % [viewport_size.x, viewport_size.y])
	root.size = Vector2i(1280, 720)
	await _settle()
	check(_button("economy") != null and _button("military") != null and _button("stop") != null, "villager root exposes two build categories and stop")
	_expect_commands({"economy": [0, KEY_B], "military": [1, KEY_V], "stop": [9, KEY_S]})
	check(_button("build_house") == null, "root page does not mix every building into commands")
	_key(KEY_B)
	await _settle()
	check(_button("build_house") != null and _button("build_mill") != null and _button("back") != null, "B opens economy page")
	check(_button("build_barracks") == null, "economy page excludes military buildings")
	_expect_commands({"build_house": [0, KEY_E], "build_mill": [1, KEY_I], "build_mining_camp": [2, KEY_G], "build_lumber_camp": [3, KEY_Z], "back": [14, KEY_ESCAPE]})
	_test_page_shortcuts()
	await _capture("economy")
	_key(KEY_G)
	check(build.is_placing() and build._ghost.def.id == &"mining_camp", "G selects mining camp in economy page")
	check(not world.get_meta("fog_holder").debug_mode, "economy G command does not toggle fog debug mode")
	_key(KEY_ESCAPE)
	var house := _button("build_house")
	if house != null:
		_key(int(house.get_meta("hotkey", 0)))
		check(build.is_placing() and build._ghost.def.id == &"house", "displayed house hotkey starts house placement")
		_key(KEY_ESCAPE)
		await _settle()
		check(not build.is_placing(), "Escape cancels placement")
	_key(KEY_ESCAPE)
	await _settle()
	check(_button("economy") != null, "Escape returns from construction page")
	_click_command("military")
	await _settle()
	check(_button("build_barracks") != null and _button("build_archery_range") != null, "military button switches pages through real GUI input")
	check(_button("build_house") == null, "military page excludes economy buildings")
	_expect_commands({"build_barracks": [0, KEY_B], "build_archery_range": [1, KEY_A], "build_stable": [2, KEY_L], "back": [14, KEY_ESCAPE]})
	_test_page_shortcuts()
	await _capture("military")
	_click_command("back")
	await _settle()
	check(_button("economy") != null, "back button survives deferred command rebuild")
	_key(KEY_V)
	await _settle()
	check(_button("build_barracks") != null, "V opens military page")
	_key(KEY_ESCAPE)
	await _settle()
	villager.command_move(Vector2(-20, -20))
	_key(KEY_S)
	check(villager.order == Enums.OrderType.NONE, "S stops selected player unit")
	villager.command_move(Vector2(-20, -20))
	_click_command("stop")
	check(villager.order == Enums.OrderType.NONE, "stop button reaches command without starting world selection")
	check(selection.get_selected_units().has(villager) and not selection._dragging, "HUD clicks preserve selected units")
	await _test_text_focus(villager)
	await _test_affordability(villager, town)
	_key(KEY_H)
	await _settle()
	check(selection.get_selected_building() == town and not build.is_placing(), "H selects own town center without placing a house")
	_select([enemy])
	await _settle()
	check(_active_commands().is_empty(), "enemy building exposes no training commands")
	var enemy_queue_size: int = enemy.train_queue.size()
	_key(KEY_C)
	check(enemy.train_queue.size() == enemy_queue_size, "enemy training cannot be triggered by keyboard")
	_select([villager])
	hud.read_only = true
	hud._rebuild_command_grid()
	await _settle()
	check(_active_commands().is_empty(), "spectator exposes no commands")
	villager.command_move(Vector2(-20, -20))
	_key(KEY_S)
	_key(KEY_B)
	check(villager.order == Enums.OrderType.MOVE and not build.is_placing(), "spectator keyboard cannot stop or construct")
	hud.read_only = false
	villager.command_stop()
	_select([])
	await _settle()
	check(_active_commands().is_empty(), "empty selection exposes no commands")
	check((hud.get_node("%NameLabel") as Label).text.is_empty(), "empty selection clears prior name")
	# Guard against early exits from a runtime script error being mistaken for success.
	check(checks >= 95, "all layout and interaction sections completed")
	world.free()
	await process_frame
	print("HUD LAYOUT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_layout(viewport_size: Vector2i) -> void:
	var panel := hud.get_node("%CommandPanel") as Control
	var content := panel.get_node("Content") as Control
	var grid := hud.get_node("%CommandGrid") as GridContainer
	var info := hud.get_node("%InfoColumn") as Control
	var map := hud.get_node("%Minimap") as Control
	var bounds := Rect2(Vector2.ZERO, Vector2(viewport_size))
	check(hud.size.is_equal_approx(Vector2(viewport_size)), "HUD follows viewport %s" % viewport_size)
	check(grid.columns == 5 and grid.get_child_count() == 15, "command page keeps fifteen fixed slots at %s" % viewport_size)
	check(content.size.is_equal_approx(Vector2(844, 205)), "command content retains design coordinates at %s" % viewport_size)
	check(is_equal_approx(content.scale.x, content.scale.y), "command content has uniform scale at %s" % viewport_size)
	var command_rect := _rect(grid)
	var info_rect := _rect(info)
	var minimap_rect := _rect(map)
	check(command_rect.end.x <= info_rect.position.x, "commands stay left of selection information at %s" % viewport_size)
	check(info_rect.end.x <= minimap_rect.position.x, "selection information stays left of minimap at %s" % viewport_size)
	check(bounds.encloses(command_rect) and bounds.encloses(info_rect) and bounds.encloses(minimap_rect), "all HUD regions stay inside viewport at %s" % viewport_size)
	for child in grid.get_children():
		check(command_rect.grow(1).encloses(_rect(child)), "command slot stays in fixed grid at %s" % viewport_size)
		if child is BaseButton:
			check(_rect(child).encloses(_rect(child.get_node("Hotkey"))), "hotkey stays inside its button at %s" % viewport_size)
	for unique_name in ["Portrait", "NameLabel", "HpBar", "HpLabel", "CountLabel", "StatsLabel", "QueueLabel", "CommandHint"]:
		var widget := hud.get_node_or_null("%" + unique_name) as Control
		check(widget != null and info_rect.grow(1).encloses(_rect(widget)), "%s stays inside selection information at %s" % [unique_name, viewport_size])
	check(hud.get_node_or_null("%CommandHint") != null, "command hint exists at %s" % viewport_size)

func _test_page_shortcuts() -> void:
	var seen: Array[int] = []
	for button in _active_commands():
		var hotkey := int(button.get_meta("hotkey", 0))
		check(hotkey > 0 and not seen.has(hotkey), "visible command shortcuts are present and unique: %s" % button.get_meta("command_id"))
		seen.append(hotkey)
		check(not button.tooltip_text.is_empty(), "command explains action and shortcut: %s" % button.get_meta("command_id"))
		check(_rect(button).encloses(_rect(button.get_node("Hotkey"))), "page hotkey stays inside its button: %s" % button.get_meta("command_id"))

func _expect_commands(expected: Dictionary) -> void:
	for command_id in expected:
		var button := _button(command_id)
		check(button != null, "classic command exists: " + command_id)
		if button == null:
			continue
		check(button.get_index() == expected[command_id][0], "classic command uses stable slot: " + command_id)
		check(int(button.get_meta("hotkey", 0)) == expected[command_id][1], "classic command uses expected key: " + command_id)

func _test_text_focus(villager: Node2D) -> void:
	var edit := LineEdit.new()
	edit.position = Vector2(500, 80)
	edit.size = Vector2(250, 40)
	hud.add_child(edit)
	edit.grab_focus()
	villager.command_move(Vector2(-20, -20))
	_key(KEY_B)
	_key(KEY_V)
	_key(KEY_S)
	await _settle()
	check(_button("economy") != null and _button("build_house") == null, "typing does not switch command pages")
	check(villager.order == Enums.OrderType.MOVE, "typing S does not stop selected unit")
	check(not build.is_placing(), "typing does not start construction")
	edit.release_focus()
	edit.queue_free()
	villager.command_stop()
	await _settle()

func _test_affordability(villager: Node2D, town: Node2D) -> void:
	var stock: Dictionary = state.resources[Enums.Team.PLAYER].duplicate()
	for resource in state.resources[Enums.Team.PLAYER]:
		state.resources[Enums.Team.PLAYER][resource] = 0
	_key(KEY_B)
	await _settle()
	var house := _button("build_house")
	check(house != null and house.disabled, "unaffordable building is disabled")
	if house != null:
		_key(int(house.get_meta("hotkey", 0)))
		check(not build.is_placing(), "disabled building hotkey cannot create ghost")
	_select([town])
	await _settle()
	var train := _button("train_villager")
	check(train != null and train.disabled, "unaffordable training is disabled")
	if train != null:
		_key(int(train.get_meta("hotkey", 0)))
		check(town.train_queue.is_empty(), "disabled training hotkey cannot enqueue")
	state.resources[Enums.Team.PLAYER] = stock
	state.population_cap[Enums.Team.PLAYER] = state.population[Enums.Team.PLAYER]
	await _settle()
	train = _button("train_villager")
	check(train != null and train.disabled, "full population keeps training disabled despite restored resources")
	state.population_cap[Enums.Team.PLAYER] = 50
	await _settle()
	train = _button("train_villager")
	check(train != null and not train.disabled, "resources restored enable training without reselection")
	_expect_commands({"train_villager": [0, KEY_C]})
	if train != null:
		_key(int(train.get_meta("hotkey", 0)))
		await _settle()
		check(town.train_queue.size() == 1, "training shortcut enqueues selected building unit")
		town.set_physics_process(false)
		check(not (hud.get_node("%QueueLabel") as Label).text.is_empty(), "selection information shows production queue")
		train = _button("train_villager")
		check(train != null and train.disabled, "busy building blocks another queued unit")
		await _capture("training")
	_select([villager])
	await _settle()

func _select(entities: Array) -> void:
	selection._clear_selection(false)
	selection._selected.assign(entities)
	for entity in entities:
		entity.set_selected(true)
	selection._emit_selection_changed()

func _button(command_id: String) -> BaseButton:
	for button in _active_commands():
		if String(button.get_meta("command_id")) == command_id:
			return button
	return null

func _active_commands() -> Array[BaseButton]:
	var result: Array[BaseButton] = []
	for child in hud.get_node("%CommandGrid").get_children():
		if child is BaseButton and child.has_meta("command_id"):
			result.append(child)
	return result

func _key(code: int) -> void:
	check(code > 0, "keyboard dispatch has a valid key")
	if code <= 0:
		return
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.unicode = code + 32 if code >= KEY_A and code <= KEY_Z else 0
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)

func _click_command(command_id: String) -> void:
	var button := _button(command_id)
	check(button != null, "GUI command exists: " + command_id)
	if button == null:
		return
	var event := InputEventMouseButton.new()
	event.position = _rect(button).get_center()
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)

func _rect(control: Control) -> Rect2:
	if control == null:
		return Rect2()
	return control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)

func _settle() -> void:
	await process_frame
	await process_frame

func _capture(label: String) -> void:
	if not render:
		return
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "res://.godot/hud-%s.png" % label
	var error := root.get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	check(error == OK, "rendered screenshot: " + path)
