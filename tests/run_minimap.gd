extends SceneTree

const Iso := preload("res://scripts/presentation/iso_math.gd")
var failures: Array[String] = []
var checks := 0
var render := false

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	render = "--render" in OS.get_cmdline_user_args()
	root.size = Vector2i(1280, 720)
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	await process_frame
	await process_frame
	var hud := world.get_node("UILayer/HUD") as Control
	var map := hud.get_node("Minimap") as Minimap
	var camera := world.get_node("Camera2D") as RtsCamera2D
	camera.set_process(false)
	var selection := world.get_node("UILayer/SelectionController") as SelectionController2D
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	var state: MatchState = world.get_node("Bootstrap").match_state
	for entity in world.get_node("Entities").get_children():
		entity.set_physics_process(false)
	var scout := world.get_node("Entities/PlayerVillager1") as Node2D
	var enemy := world.get_node("Entities/AiTownCenter") as Node2D
	var home: Vector2 = scout.sim_pos
	check(map.visible and map.size.is_equal_approx(Vector2(392,196)), "minimap fits the skin diamond")
	for point in [Vector2(-60,-60), Vector2(60,-60), Vector2(60,60), Vector2(-60,60), Vector2(-23,17)]:
		check(map.map_to_world(map.world_to_map(point)).is_equal_approx(point), "projection round trip %s" % point)
	check(map.world_to_map(map.map_min).is_equal_approx(Vector2(196,0)), "north corner matches isometric world")
	check(not map.contains_map_point(Vector2.ZERO), "rectangle corners outside diamond cannot navigate")
	check(map.contains_map_point(map.size * 0.5), "diamond center accepts navigation")
	map.refresh_markers()
	check(not _has_marker(map, enemy.sim_pos, "building"), "unexplored enemy base is absent")
	check(_has_marker(map, world.get_node("Entities/PlayerTownCenter").sim_pos, "building"), "own base is shown")
	var color_marker := {"minimap_kind": "unit", "team": 0, "memory": false}
	state.set_team_color_id(0, 4)
	check(map.marker_color(color_marker) == TeamColorCatalog.fallback_color(4), "markers follow configured player palette")
	state.set_team_color_id(0, 1)
	var image := map._terrain.get_image()
	var fog: RefCounted = state.fog
	check(image.get_pixelv(fog.cell_at(enemy.sim_pos)) == Color.BLACK, "unexplored ground is black")
	check(image.get_pixelv(fog.cell_at(home)).g > 0.35, "visible ground is illuminated")
	selection._add_selection(scout)
	var target := Vector2(-12,-8)
	_mouse(map, map.world_to_map(target), MOUSE_BUTTON_LEFT, true)
	check(Iso.screen_to_world(camera.position).is_equal_approx(target), "left click focuses correct world position")
	var motion := InputEventMouseMotion.new()
	motion.position = map.world_to_map(Vector2(8,12))
	map._gui_input(motion)
	check(Iso.screen_to_world(camera.position).is_equal_approx(Vector2(8,12)), "left drag follows pointer")
	_mouse(map, motion.position, MOUSE_BUTTON_LEFT, false)
	check(not map._dragging and selection.get_selected_units().has(scout), "release retains unit selection")
	var old_position := camera.position
	_mouse(map, Vector2.ZERO, MOUSE_BUTTON_LEFT, true)
	check(camera.position == old_position, "outside diamond click cannot jump camera")
	# Actual viewport input must be consumed by the HUD, not world selection/building.
	var click := InputEventMouseButton.new()
	click.position = map.global_position + map.world_to_map(target)
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	root.push_input(click, true)
	click = click.duplicate()
	click.pressed = false
	root.push_input(click, true)
	check(selection.get_selected_units().has(scout) and not selection._dragging, "GUI routing does not start world selection")
	state.frozen = false
	_mouse(map, map.world_to_map(target), MOUSE_BUTTON_RIGHT, true)
	check(scout.order == Enums.OrderType.MOVE and scout._move_target.is_equal_approx(target), "right click issues world move")
	scout.command_stop()
	click = click.duplicate()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	root.push_input(click, true)
	check(scout.order == Enums.OrderType.MOVE and scout._move_target.is_equal_approx(target), "viewport right click reaches minimap command")
	scout.command_stop()
	map.read_only = true
	map.command_at(map.world_to_map(Vector2.ZERO))
	check(scout.order == Enums.OrderType.NONE, "spectator cannot command")
	map.read_only = false
	state.frozen = true
	map.command_at(map.world_to_map(Vector2.ZERO))
	check(scout.order == Enums.OrderType.NONE, "ended match cannot command")
	state.frozen = false
	var build: Node = world.get_node("BuildSystem")
	build.begin_placement(load("res://data/buildings/house.tres"))
	click = click.duplicate()
	click.button_index = MOUSE_BUTTON_LEFT
	root.push_input(click, true)
	check(build.is_placing(), "minimap navigation does not place a building")
	click = click.duplicate()
	click.pressed = false
	root.push_input(click, true)
	map.command_at(map.world_to_map(Vector2.ZERO))
	check(not build.is_placing() and scout.order == Enums.OrderType.NONE, "right click cancels active placement without moving units")
	# Known static entities survive loss of vision using value snapshots.
	scout.sim_pos = enemy.sim_pos - Vector2(3,3)
	holder.rebuild_now()
	map.refresh_markers()
	check(_has_marker(map, enemy.sim_pos, "building"), "visible enemy building appears")
	var enemy_unit := world.get_node("Entities/AiVillager1") as Node2D
	check(_has_marker(map, enemy_unit.sim_pos, "unit"), "visible enemy unit appears")
	var known_pos: Vector2 = enemy.sim_pos
	scout.sim_pos = home
	holder.rebuild_now()
	map._process(0.1)
	check(_has_marker(map, known_pos, "building", true), "explored enemy building uses remembered marker")
	check(not _has_marker(map, enemy_unit.sim_pos, "unit"), "enemy units disappear immediately on marker refresh after losing sight")
	check(not _has_marker(map, enemy_unit.sim_pos, "unit", true), "mobile enemies leave no static memory dots")
	image = map._terrain.get_image()
	# The headless dummy renderer does not implement ImageTexture.update.
	if render:
		check(image.get_pixelv(fog.cell_at(known_pos)).g > 0.05 and image.get_pixelv(fog.cell_at(known_pos)).g < 0.3, "explored ground is dimmed")
	enemy.queue_free()
	await process_frame
	holder.rebuild_now()
	map.refresh_markers()
	check(_has_marker(map, known_pos, "building", true), "unseen destruction cannot erase remembered marker")
	camera.focus_on(Vector2(-25,-25))
	camera.force_update_scroll()
	await process_frame
	var before := map.camera_polygons()
	check(not before.is_empty(), "camera outline intersects minimap")
	camera._set_zoom(1.8)
	camera.force_update_scroll()
	var after := map.camera_polygons()
	check(not after.is_empty() and _area(after[0]) < _area(before[0]), "camera outline shrinks when zooming in")
	camera._set_zoom(0.75)
	camera.force_update_scroll()
	await _capture("player")
	holder.set_debug_mode(true)
	holder.set_view(-1)
	map._process(0.0)
	check(map._markers_team == -1, "omniscient view updates markers immediately")
	if render:
		check(map._terrain.get_image().get_pixel(0,0).g > 0.35, "omniscient view updates terrain immediately")
	map.command_at(map.world_to_map(Vector2.ZERO))
	check(scout.order == Enums.OrderType.NONE, "debug perspective cannot issue commands")
	await _capture("all")
	holder.set_view(1)
	map._process(0.0)
	check(not _has_marker(map, home, "unit"), "AI perspective hides unseen player units immediately")
	await _capture("ai")
	holder.set_debug_mode(false)
	scout.sim_pos = known_pos
	holder.rebuild_now()
	map._process(0.1)
	check(not _has_marker(map, known_pos, "building"), "re-observing empty footprint removes memory")
	for width in [960, 1600]:
		hud.size = Vector2(width, 900)
		hud._sync_hud_layout()
		check(is_equal_approx(map.position.x / width, 868.0 / 1280.0), "minimap tracks panel width %d" % width)
		var content := hud.get_node("CommandPanel/Content") as Control
		check(content.get_global_rect().end.x < map.global_position.x, "command buttons reserve minimap space %d" % width)
	world.queue_free()
	await process_frame
	for scene in ["ai_vs_ai", "combat_arena", "combat_duel_arena", "pathfinding_arena", "pathfinding_test"]:
		var other := load("res://scenes/%s.tscn" % scene).instantiate() as Node
		root.add_child(other)
		await process_frame
		await process_frame
		var other_map := other.get_node_or_null("UILayer/HUD/Minimap") as Minimap
		if other_map != null:
			check(other_map.visible and other_map._terrain != null, "%s initializes minimap" % scene)
			check(other_map.map_min == Vector2.ONE * other.get_meta("fog").map_min, "%s uses match bounds" % scene)
		other.queue_free()
		await process_frame
	print("MINIMAP TESTS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _mouse(map: Minimap, point: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = point
	event.pressed = pressed
	map._gui_input(event)

func _has_marker(map: Minimap, point: Vector2, kind: String, memory := false) -> bool:
	for marker in map._markers:
		if marker.minimap_kind == kind and marker.sim_pos.is_equal_approx(point) and marker.memory == memory:
			return true
	return false

func _area(polygon: PackedVector2Array) -> float:
	var area := 0.0
	for index in polygon.size():
		area += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return absf(area) * 0.5

func _capture(view: String) -> void:
	if not render:
		return
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.superpowers/sdd/minimap-%s.png" % view))
