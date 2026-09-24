class_name Minimap
extends Control

const Iso := preload("res://scripts/presentation/iso_math.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Colors := preload("res://scripts/presentation/team_color_catalog.gd")
const Ui := preload("res://scripts/presentation/ui_catalog.gd")
const GRASS := Color(0.34, 0.43, 0.20)
const UPDATE_INTERVAL := 0.1

var match_state: MatchState
var selection: Node
var build_system: Node
var read_only := false
var map_min := Vector2(-60, -60)
var map_max := Vector2(60, 60)
var _world: Node
var _entities: Node
var _camera: Camera2D
var _holder: Node
var _fog: RefCounted
var _team := Enums.Team.PLAYER
var _terrain: ImageTexture
var _terrain_key: Array = []
var _markers: Array[Dictionary] = []
var _elapsed := UPDATE_INTERVAL
var _dragging := false
var _order_pos := Vector2.ZERO
var _order_ttl := 0.0
var _markers_team := -2

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	call_deferred("_bind_default")

## Some standalone arenas share the HUD without calling its economy setup.
func _bind_default() -> void:
	if match_state != null:
		return
	var world := get_parent()
	while world != null and not world.has_node("Entities"):
		world = world.get_parent()
	if world == null:
		visible = false
		return
	var bootstrap := world.get_node_or_null("Bootstrap")
	if bootstrap == null or bootstrap.get("match_state") == null:
		visible = false
		return
	var controller := world.get_node_or_null("UILayer/SelectionController")
	setup(bootstrap.get("match_state"), controller, world.get_node_or_null("BuildSystem"),
		controller != null and controller.get("read_only") == true)

func setup(state: MatchState, controller: Node, system: Node, spectator := false) -> void:
	match_state = state
	selection = controller
	build_system = system
	read_only = spectator
	_terrain_key.clear()
	_elapsed = UPDATE_INTERVAL
	_world = get_parent()
	while _world != null and not _world.has_node("Entities"):
		_world = _world.get_parent()
	if _world != null:
		_entities = _world.get_node("Entities")
		_camera = _world.get_node_or_null("Camera2D") as Camera2D
	visible = _camera != null

func _process(delta: float) -> void:
	if not is_instance_valid(_camera) or not is_instance_valid(_world):
		return
	_holder = _world.get_meta("fog_holder", null)
	_fog = match_state.fog if match_state != null and match_state.fog_enabled else null
	_team = int(_holder.get("view_team")) if is_instance_valid(_holder) else Enums.Team.PLAYER
	map_min = _camera.get("map_world_min")
	map_max = _camera.get("map_world_max")
	if _fog != null:
		map_min = Vector2.ONE * _fog.map_min
		map_max = Vector2.ONE * _fog.map_max
	_sync_terrain()
	_elapsed += delta
	if _elapsed >= UPDATE_INTERVAL:
		_elapsed = 0.0
		refresh_markers()
	# View changes must not leave enemy dots from the previous perspective.
	if _markers_team != _team:
		refresh_markers()
	_order_ttl = maxf(0.0, _order_ttl - delta)
	if _dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_dragging = false
	queue_redraw()

## The same affine transform is used for rendering, picking and camera outlines.
func world_to_map(point: Vector2) -> Vector2:
	var uv := (point - map_min) / (map_max - map_min)
	return Vector2((uv.x - uv.y + 1.0) * size.x * 0.5, (uv.x + uv.y) * size.y * 0.5)

func map_to_world(point: Vector2) -> Vector2:
	var dx := point.x / maxf(size.x * 0.5, 0.001) - 1.0
	var dy := point.y / maxf(size.y * 0.5, 0.001)
	return map_min + Vector2((dx + dy) * 0.5, (dy - dx) * 0.5) * (map_max - map_min)

func contains_map_point(point: Vector2) -> bool:
	var world := map_to_world(point)
	return world.x >= map_min.x and world.y >= map_min.y and world.x <= map_max.x and world.y <= map_max.y

func _diamond() -> PackedVector2Array:
	return PackedVector2Array([Vector2(size.x * 0.5, 0), Vector2(size.x, size.y * 0.5),
		Vector2(size.x * 0.5, size.y), Vector2(0, size.y * 0.5)])

func _sync_terrain() -> void:
	var revision: int = _fog.revision if _fog != null else -1
	var key := [_fog, revision, _team, match_state != null and match_state.fog_enabled]
	if key == _terrain_key:
		return
	_terrain_key = key
	var side: int = _fog.side if _fog != null else 1
	var pixels := Image.create(side, side, false, Image.FORMAT_RGB8)
	var hidden := match_state != null and match_state.fog_enabled and _team != -1
	pixels.fill(Color.BLACK if hidden else GRASS)
	if hidden and _fog != null:
		var explored: PackedByteArray = _fog.explored.get(_team, PackedByteArray())
		var current: PackedByteArray = _fog.visible_now.get(_team, PackedByteArray())
		for y in side:
			for x in side:
				var index := y * side + x
				if index < explored.size() and explored[index] != 0:
					pixels.set_pixel(x, y, GRASS if current[index] != 0 else GRASS.darkened(0.58))
	if _terrain != null and _terrain.get_width() == side:
		_terrain.update(pixels)
	else:
		_terrain = ImageTexture.create_from_image(pixels)

func refresh_markers() -> void:
	_markers.clear()
	_markers_team = _team
	if not is_instance_valid(_entities):
		return
	var shown: Dictionary = {}
	var restricted := match_state != null and match_state.fog_enabled and _team != -1
	for entity in _entities.get_children():
		if entity.has_meta("fog_memory") or entity.get("sim_pos") == null or entity.get("is_placement_ghost") == true:
			continue
		if restricted and (_fog == null or not _fog.can_see(_team, entity)):
			continue
		if entity.get("hp") != null and float(entity.get("hp")) <= 0.0:
			continue
		if entity.has_method("extract") and float(entity.get("amount")) <= 0.0:
			continue
		var marker_kind := ""
		if entity.get("def") is BuildingDef:
			marker_kind = "building"
		elif entity.get("def") is UnitDef:
			marker_kind = "unit"
		elif entity.has_method("extract"):
			marker_kind = "resource"
		elif entity.is_in_group("path_blockers"):
			marker_kind = "blocker"
		else:
			continue
		shown[entity.get_instance_id()] = true
		_markers.append({"sim_pos": entity.get("sim_pos"), "minimap_kind": marker_kind,
			"team": entity.get("team"), "resource_type": entity.get("resource_type"),
			"kind": entity.get("kind"), "footprint": Fog.footprint_of(entity), "memory": false})
	if restricted and _fog != null:
		var known: Dictionary = _fog.memories.get(_team, {})
		for id in known:
			if shown.has(id) or not known[id].has("minimap_kind"):
				continue
			var marker: Dictionary = known[id].duplicate()
			marker["memory"] = true
			_markers.append(marker)
	# Terrain/resources first, then buildings and mobile units.
	_markers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _marker_layer(a) < _marker_layer(b))

func _marker_layer(marker: Dictionary) -> int:
	return 2 if marker.minimap_kind == "unit" else (1 if marker.minimap_kind == "building" else 0)

func marker_color(marker: Dictionary) -> Color:
	var color := Color(0.55, 0.53, 0.45)
	if marker.minimap_kind in ["unit", "building"]:
		color = Colors.fallback_color(Colors.resolve_color_id(int(marker.team), match_state))
	elif marker.minimap_kind == "resource":
		match int(marker.resource_type):
			Enums.ResourceType.WOOD: color = Color(0.08, 0.25, 0.06)
			Enums.ResourceType.GOLD: color = Color(1.0, 0.79, 0.13)
			Enums.ResourceType.FOOD: color = Color(0.72, 0.26, 0.13)
	elif marker.get("kind") == &"water":
		color = Color(0.18, 0.40, 0.60)
	return color.darkened(0.45) if marker.get("memory", false) else color

func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var diamond := _diamond()
	draw_colored_polygon(diamond, Color.BLACK)
	if _terrain != null:
		var side := float(_terrain.get_width())
		draw_set_transform_matrix(Transform2D(Vector2(size.x, size.y) / (2.0 * side),
			Vector2(-size.x, size.y) / (2.0 * side), Vector2(size.x * 0.5, 0)))
		draw_texture(_terrain, Vector2.ZERO)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	for marker in _markers:
		_draw_marker(marker)
	for polygon in camera_polygons():
		var outline := PackedVector2Array(polygon)
		outline.append(outline[0])
		draw_polyline(outline, Color(0, 0, 0, 0.8), 3.0, true)
		draw_polyline(outline, Color.WHITE, 1.0, true)
	if _order_ttl > 0.0:
		var point := world_to_map(_order_pos)
		draw_arc(point, 4.0 + (1.0 - _order_ttl) * 8.0, 0, TAU, 24, Color(1, 0.95, 0.3, _order_ttl), 1.5, true)
	diamond.append(diamond[0])
	draw_polyline(diamond, Color(0.67, 0.62, 0.43), 1.0, true)

func _draw_marker(marker: Dictionary) -> void:
	var center: Vector2 = marker.sim_pos
	if center.x < map_min.x or center.y < map_min.y or center.x > map_max.x or center.y > map_max.y:
		return
	var color := marker_color(marker)
	if marker.minimap_kind == "unit":
		var radius := maxf(1.0, size.x / 196.0)
		draw_rect(Rect2(world_to_map(center) - Vector2.ONE * radius * 0.5, Vector2.ONE * radius), color)
		return
	var half: Vector2 = marker.footprint * 0.5
	# Keep sparse resources readable even on the largest arena maps.
	var minimum := (map_max - map_min) * (1.5 / maxf(size.x, 1.0))
	half = half.max(minimum)
	var polygon := PackedVector2Array()
	for offset in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		polygon.append(world_to_map((center + offset).clamp(map_min, map_max)))
	draw_colored_polygon(polygon, color)

func camera_polygons() -> Array[PackedVector2Array]:
	if not is_instance_valid(_camera):
		return []
	var viewport_size := get_viewport_rect().size
	var top := Ui.panel_scaled_top_band(viewport_size.x)
	var bottom := viewport_size.y - Ui.panel_scaled_bottom_band(viewport_size.x)
	var inverse := _camera.get_canvas_transform().affine_inverse()
	var polygon := PackedVector2Array()
	for point in [Vector2(0, top), Vector2(viewport_size.x, top), Vector2(viewport_size.x, bottom), Vector2(0, bottom)]:
		polygon.append(world_to_map(Iso.screen_to_world(inverse * point)))
	return Geometry2D.intersect_polygons(polygon, _diamond())

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if is_instance_valid(selection) and selection.has_method("cancel_selection_drag"):
				selection.cancel_selection_drag()
			_dragging = event.pressed and contains_map_point(event.position)
			if _dragging:
				_focus_at(event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and contains_map_point(event.position):
			command_at(event.position)
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_focus_at(event.position)
		accept_event()

func _focus_at(point: Vector2) -> void:
	if is_instance_valid(_camera) and _camera.has_method("focus_on"):
		_camera.focus_on(map_to_world(point).clamp(map_min, map_max))

func command_at(point: Vector2) -> void:
	if not contains_map_point(point) or read_only or not is_instance_valid(selection):
		return
	if match_state != null and match_state.frozen:
		return
	if is_instance_valid(_holder) and _holder.get("debug_mode") == true:
		return
	if selection.get("read_only") == true or not selection.has_method("issue_minimap_move"):
		return
	if is_instance_valid(build_system) and build_system.has_method("is_placing") and build_system.is_placing():
		build_system.cancel_placement()
		return
	if selection.get_selected_units().is_empty():
		return
	_order_pos = map_to_world(point).clamp(map_min, map_max)
	selection.issue_minimap_move(_order_pos)
	_order_ttl = 1.0
