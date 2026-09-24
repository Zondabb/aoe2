extends SceneTree

const Loader := preload("res://scripts/world/map_loader.gd")
const Data := preload("res://scripts/world/map_data.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
var checks := 0
var failures: Array[String] = []
var render := false

class VisionSource extends Node2D:
	var team := 0
	var hp := 100.0
	var sim_pos := Vector2.ZERO
	func resolved_vision_radius() -> float: return 6.0

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

func _new_menu() -> Control:
	var menu := load("res://scenes/civ_select.tscn").instantiate() as Control
	root.add_child(menu)
	current_scene = menu
	await _settle()
	return menu

func _click(node: Control) -> void:
	var rect := node.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, node.size)
	var event := InputEventMouseButton.new()
	event.position = rect.get_center()
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)

func _capture(label: String) -> void:
	if not render: return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/menu-%s.png" % label)) == OK, "save " + label)

func _run() -> void:
	_test_rect_fog()
	render = "--render" in OS.get_cmdline_user_args()
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.selected_map_path = ""
	var menu: Control = await _new_menu()
	check(menu.page == "main" and not menu._setup.visible, "launch shows level one only")
	await _capture("main")
	_click(menu.get_node("Design/MainPage/MenuPanel/Multiplayer"))
	await _settle()
	check(menu.page == "main" and not menu._setup.visible and current_scene == menu, "unimplemented multiplayer cannot enter another page")
	check("尚未实现" in menu._main_status.text, "multiplayer explains unavailable state")
	_click(menu.get_node("Design/MainPage/MenuPanel/SinglePlayer"))
	await _settle()
	check(menu.page == "single" and not menu._main.visible, "single player opens level two")
	menu._set_starting(true)
	check(menu._player_choice.disabled and menu._map_choice.disabled and menu._ai_choice.disabled, "launch locks keyboard and mouse changes")
	menu._set_starting(false)
	check(not menu._player_choice.disabled and not menu._start.disabled, "launch failure can restore controls")
	check(menu._ai_choice.selected == 0, "offline local AI is the default")
	check(menu.map_paths.has("res://data/maps/editor_demo.json"), "built-in map is selectable")
	for viewport_size in [Vector2i(1280,720), Vector2i(1024,768), Vector2i(1920,1080)]:
		root.size = viewport_size
		await _settle()
		for path in ["MapChoice", "ImportMap", "MapPreview", "PlayerCiv", "EnemyCiv", "AiMode", "Back", "Start"]:
			var control: Control = menu.get_node("Design/SinglePlayerPage/" + path)
			var rect := control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)
			check(Rect2(Vector2.ZERO, Vector2(viewport_size)).encloses(rect), "menu widget within viewport: " + path)
	root.size = Vector2i(1280,720)
	await _settle()
	menu.select_map_file("res://data/maps/editor_demo.json")
	await _settle()
	await _capture("single-player")
	_click(menu.get_node("Design/SinglePlayerPage/Back"))
	await _settle()
	check(menu.page == "main", "back returns to main menu")
	menu.show_single_player()
	check(menu.map_paths[menu._map_choice.selected] == "res://data/maps/editor_demo.json", "back and reopen retains map selection")
	# Invalid, removed, and empty maps must never transition into the game.
	var bad_path := "user://menu-invalid.json"
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string("{ invalid")
	file.close()
	menu.select_map_file(bad_path)
	check(menu._start.disabled and not menu.map_error.is_empty(), "malformed map disables start with error")
	menu._start_game()
	check(current_scene == menu, "invalid map cannot launch even by direct action")
	var empty_path := "user://menu-empty.json"
	check(Loader.save_file(Data.create(), empty_path).is_empty(), "create no-player fixture")
	menu.select_map_file(empty_path)
	check(menu._start.disabled, "map without any player object cannot launch")
	# Rectangular and translated map verifies every system uses actual file bounds.
	var data: Dictionary = Loader.load_file("res://data/maps/editor_demo.json").data
	for key in ["min", "max"]:
		data.bounds[key][0] += 500
		data.bounds[key][1] -= 800
	for record in data.entities:
		record.pos[0] += 500
		record.pos[1] -= 800
	data.display_name = "地图".repeat(60)
	var path := "user://menu-custom.json"
	check(Loader.save_file(data, path).is_empty(), "create translated map fixture")
	menu.select_map_file(path)
	check(not menu._start.disabled, "valid translated map can launch")
	check(menu._map_info.size.y <= 87 and menu._map_info.tooltip_text.length() == 120, "long map title stays inside layout with full tooltip")
	DirAccess.remove_absolute(path)
	menu._start_game()
	check(current_scene == menu and menu._start.disabled, "start revalidates a file removed after selection")
	check(Loader.save_file(data, path).is_empty(), "restore map fixture")
	menu.select_map_file(path)
	menu._player_choice.select(1)
	menu._enemy_choice.select(0)
	menu._ai_choice.select(1)
	_click(menu._start)
	await _settle()
	await _settle()
	check(current_scene != menu and current_scene.name == "Match", "Start enters actual match scene")
	var world := current_scene
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.frozen = true
	check(session.player_civ_id == &"teutons" and session.ai_civ_id == &"chinese", "chosen civilizations reach match session")
	check(world.get_node_or_null("AiGateway") == null and not world.get_node("AiController").enabled, "sandbox has no AI service or AI actions")
	var count := 0
	for entity in world.get_node("Entities").get_children():
		if not entity.has_meta("map_id"): continue
		count += 1
		var record: Dictionary = entity.get_meta("map_record")
		check(entity.sim_pos.is_equal_approx(Data.position_of(record)), "custom initial position is preserved")
		if record.type != "resource":
			check(entity.civ.id == (&"teutons" if record.team == "player" else &"chinese"), "civilization applied before entity ready")
	check(count == data.entities.size(), "custom map creates exactly its authored entities")
	var bounds := Data.bounds(data)
	var camera: Camera2D = world.get_node("Camera2D")
	check(camera.map_world_min == bounds.position and camera.map_world_max == bounds.end, "camera uses rectangular map bounds")
	check(state.fog.map_origin == bounds.position and state.fog.map_end == bounds.end, "fog preserves distinct x/y origin and extent")
	check(state.fog.mask_image(0).get_size() == Vector2i(bounds.size), "fog mask dimensions follow rectangle")
	var minimap: Control = world.get_node("UILayer/HUD/Minimap")
	minimap._process(0.2)
	check(minimap.map_min == bounds.position and minimap.map_max == bounds.end, "minimap uses same bounds")
	check(minimap._terrain.get_image().get_size() == Vector2i(bounds.size), "minimap texture has rectangular dimensions")
	for point in [bounds.position, bounds.end, bounds.get_center()]:
		check(minimap.map_to_world(minimap.world_to_map(point)).is_equal_approx(point), "custom minimap click projection round trip")
	var nav: Node = world.get_node("NavService")
	var route: PackedVector2Array = nav.nav.find_path(bounds.position + Vector2(2,2), bounds.position + Vector2(8,2))
	check(route.size() > 0 and route[-1].is_equal_approx(bounds.position + Vector2(8,2)), "navigation routes within translated bounds")
	check(nav.nav != null and world.get_node("Map/Ground").get_child_count() == 1, "custom ground and navigation initialized")
	check(state.fog.state_at(0, Vector2(486,-808)) == Fog.State.VISIBLE, "own base reveals fog at translated coordinate")
	check(state.fog.cell_at(bounds.end + Vector2.RIGHT).x == -1, "fog rejects outside map bounds")
	await _capture("custom-match")
	world.get_node("UILayer/HUD")._return_to_civ_select()
	await _settle()
	menu = current_scene
	check(menu.page == "main", "return from match goes to main menu")
	menu.show_single_player()
	# Selecting default after custom must clear snapshot, and selected civs can match.
	menu._map_choice.select(0)
	menu._map_selected(0)
	menu._player_choice.select(1)
	menu._enemy_choice.select(1)
	menu._ai_choice.select(0)
	_click(menu._start)
	await _settle()
	await _settle()
	world = current_scene
	check(session.match_map_data.is_empty(), "default map clears previous custom snapshot")
	check(world.has_node("Entities/PlayerTownCenter"), "default map creates legacy starting base")
	check(world.get_node("Entities/AiTownCenter").civ.id == &"teutons", "opponent civilization is independently selected")
	check(world.get_node_or_null("AiGateway") == null and world.get_node("AiController").enabled, "local AI starts without HTTP gateway")
	var local_ai: Node = world.get_node("AiController")
	local_ai._process(0.6)
	check(local_ai.match_time > 0 and local_ai.match_state != null, "local AI ticks in actual match")
	local_ai.stop()
	world.free()
	current_scene = null
	await _settle()
	for temporary in [bad_path, empty_path, path]: DirAccess.remove_absolute(temporary)
	session.match_map_data = {}
	session.selected_map_path = ""
	session.match_ai_mode = "gateway"
	check(checks >= 80, "all test sections ran to completion")
	print("MENU FLOW: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_rect_fog() -> void:
	for extent in [Vector2(63,31), Vector2(16,80)]:
		var fog := Fog.new()
		var origin := Vector2(-913,742)
		fog.setup_rect(origin, origin + extent)
		var a := VisionSource.new()
		var b := VisionSource.new()
		a.sim_pos = origin + Vector2(2.5,3.5)
		b.sim_pos = origin + extent - Vector2(2.5,3.5)
		fog.rebuild([a,b])
		var correct := true
		for y in int(extent.y):
			for x in int(extent.x):
				var point := origin + Vector2(x+0.5,y+0.5)
				var expected := point.distance_squared_to(a.sim_pos) <= 36 or point.distance_squared_to(b.sim_pos) <= 36
				correct = correct and ((fog.state_at(0,point) == Fog.State.VISIBLE) == expected)
		check(correct, "rectangular fog matches independent circle oracle in every cell")
		fog.rebuild([])
		check(fog.state_at(0,a.sim_pos) == Fog.State.EXPLORED, "rectangular fog retains exploration")
		check(fog.mask_image(0).get_size() == Vector2i(extent), "tall and wide fog textures retain actual dimensions")
		a.free()
		b.free()
