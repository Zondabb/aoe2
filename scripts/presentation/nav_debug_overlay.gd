class_name NavDebugOverlay
extends Node2D

## Layered debug draw for pathfinding arenas. Toggle via PathfindingDebugPanel or hotkeys.

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")
const MovementDebugDrawScript := preload("res://scripts/presentation/movement_debug_draw.gd")

const BLOCK_FILL := Color(0.95, 0.15, 0.12, 0.35)
const BLOCK_EDGE := Color(1.0, 0.35, 0.2, 0.85)
const GRID_LINE := Color(0.55, 0.62, 0.55, 0.35)
const VISION_FILL_PLAYER := Color(0.25, 0.75, 1.0, 0.10)
const VISION_EDGE_PLAYER := Color(0.35, 0.85, 1.0, 0.75)
const VISION_FILL_AI := Color(1.0, 0.35, 0.25, 0.10)
const VISION_EDGE_AI := Color(1.0, 0.45, 0.3, 0.75)
const VISION_LINK := Color(1.0, 0.9, 0.2, 0.55)
const PATH_COLORS := [
	Color(0.25, 0.95, 0.55, 0.95),
	Color(0.35, 0.75, 1.0, 0.95),
	Color(1.0, 0.85, 0.25, 0.95),
	Color(0.95, 0.45, 0.95, 0.95),
	Color(1.0, 0.55, 0.25, 0.95),
]
const VISION_SEGMENTS := 48
const TIMING_INTERVAL_SEC := 1.0

var nav: NavGridServiceScript
var vision: VisionServiceScript

var show_nav_grid := false
var show_solid_cells := false
var show_paths := false
var show_vision := false
var show_move_arrows := false
var print_vision_timing := false

var _timing_accum := 0.0
var _last_timing_text := ""
var _focus_units: Array[Node2D] = []


func set_focus_units(units: Array) -> void:
	_focus_units.clear()
	for value in units:
		var unit := value as Node2D
		if unit != null and is_instance_valid(unit):
			_focus_units.append(unit)
	queue_redraw()


func _unit_in_focus(unit: Node2D) -> bool:
	if _focus_units.is_empty():
		return true
	return unit in _focus_units


func _ready() -> void:
	z_index = 80
	add_to_group("nav_debug_overlay")
	set_process(false)


func refresh_debug_state() -> void:
	var active := _any_draw() or print_vision_timing
	set_process(active)
	if not active:
		_timing_accum = 0.0
	queue_redraw()
	if print_vision_timing:
		_run_and_print_vision_timing()


func _process(delta: float) -> void:
	if _any_draw():
		queue_redraw()
	if not print_vision_timing:
		return
	_timing_accum += delta
	if _timing_accum >= TIMING_INTERVAL_SEC:
		_timing_accum = 0.0
		_run_and_print_vision_timing()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.keycode:
			KEY_G:
				_toggle_all_layers()
				get_viewport().set_input_as_handled()
			KEY_B:
				show_solid_cells = not show_solid_cells
				refresh_debug_state()
				get_viewport().set_input_as_handled()
			KEY_V:
				show_vision = not show_vision
				refresh_debug_state()
				get_viewport().set_input_as_handled()
			KEY_P:
				show_paths = not show_paths
				refresh_debug_state()
				get_viewport().set_input_as_handled()
			KEY_A:
				show_move_arrows = not show_move_arrows
				refresh_debug_state()
				get_viewport().set_input_as_handled()
			KEY_T:
				print_vision_timing = not print_vision_timing
				refresh_debug_state()
				get_viewport().set_input_as_handled()
			KEY_N:
				show_nav_grid = not show_nav_grid
				refresh_debug_state()
				get_viewport().set_input_as_handled()


func _toggle_all_layers() -> void:
	var enable := not _all_layers_on()
	show_nav_grid = enable
	show_solid_cells = enable
	show_paths = enable
	show_vision = enable
	show_move_arrows = enable
	print_vision_timing = enable
	refresh_debug_state()
	_sync_panel_checks()


func _all_layers_on() -> bool:
	return (
		show_nav_grid
		and show_solid_cells
		and show_paths
		and show_vision
		and show_move_arrows
		and print_vision_timing
	)


func _sync_panel_checks() -> void:
	var panel := get_tree().get_first_node_in_group("pathfinding_debug_panel")
	if panel != null and panel.has_method("_sync_from_overlay"):
		panel.call("_sync_from_overlay")


func _any_draw() -> bool:
	return show_nav_grid or show_solid_cells or show_paths or show_vision or show_move_arrows


func _draw() -> void:
	if not _any_draw():
		return
	if show_nav_grid and nav != null:
		_draw_nav_grid_lines()
	if show_solid_cells and nav != null:
		_draw_block_cells()
	if show_paths:
		_draw_unit_paths()
	if show_vision:
		_draw_vision_ranges()
	if show_move_arrows:
		_draw_move_arrows()


func _draw_move_arrows() -> void:
	if not is_inside_tree():
		return
	var units := _focused_units_list()
	MovementDebugDrawScript.draw_unit_arrows(self, units)


func _draw_nav_grid_lines() -> void:
	var min_i := nav.map_min
	var max_i := nav.map_max
	for x in range(min_i, max_i + 1):
		var a := IsoMathScript.world_to_screen(Vector2(float(x), float(min_i)))
		var b := IsoMathScript.world_to_screen(Vector2(float(x), float(max_i)))
		draw_line(a, b, GRID_LINE, 1.0)
	for y in range(min_i, max_i + 1):
		var a := IsoMathScript.world_to_screen(Vector2(float(min_i), float(y)))
		var b := IsoMathScript.world_to_screen(Vector2(float(max_i), float(y)))
		draw_line(a, b, GRID_LINE, 1.0)


func _draw_block_cells() -> void:
	var cells: Array[Vector2i] = nav.get_solid_cells()
	var half := nav.cell_size * 0.5
	for cell in cells:
		var center := nav.cell_to_world_center(cell)
		var corners := PackedVector2Array([
			IsoMathScript.world_to_screen(center + Vector2(-half, -half)),
			IsoMathScript.world_to_screen(center + Vector2(half, -half)),
			IsoMathScript.world_to_screen(center + Vector2(half, half)),
			IsoMathScript.world_to_screen(center + Vector2(-half, half)),
		])
		draw_colored_polygon(corners, BLOCK_FILL)
		draw_polyline(
			PackedVector2Array([corners[0], corners[1], corners[2], corners[3], corners[0]]),
			BLOCK_EDGE,
			1.5
		)


func _draw_unit_paths() -> void:
	if not is_inside_tree():
		return
	var units := _focused_units_list()
	var color_index := 0
	for unit in units:
		if not unit.has_method("get_nav_path_debug"):
			continue
		var world_path: PackedVector2Array = unit.call("get_nav_path_debug")
		if world_path.size() < 2:
			continue
		var screen_path := PackedVector2Array()
		for point in world_path:
			screen_path.append(IsoMathScript.world_to_screen(point))
		var color: Color = PATH_COLORS[color_index % PATH_COLORS.size()]
		color_index += 1
		draw_polyline(screen_path, color, 2.5, true)
		for i in screen_path.size():
			var radius := 3.5 if i == screen_path.size() - 1 else 2.5
			draw_circle(screen_path[i], radius, color)
		draw_arc(screen_path[screen_path.size() - 1], 7.0, 0.0, TAU, 16, color, 1.5)


func _draw_vision_ranges() -> void:
	if not is_inside_tree() or vision == null:
		return
	for unit in _focused_units_list():
		if float(unit.get("hp")) <= 0.0:
			continue
		var center: Vector2 = unit.get("sim_pos")
		var radius := float(vision.vision_radius_of(unit))
		var is_ai: bool = unit.get("team") == Enums.Team.AI
		var fill := VISION_FILL_AI if is_ai else VISION_FILL_PLAYER
		var edge := VISION_EDGE_AI if is_ai else VISION_EDGE_PLAYER
		var ring := _iso_circle_screen_points(center, radius)
		if ring.size() >= 3:
			draw_colored_polygon(ring, fill)
			draw_polyline(ring, edge, 1.75, true)
		var others: Array = vision.others_in_radius(unit)
		var from_screen := IsoMathScript.world_to_screen(center)
		for other_value in others:
			var other := other_value as Node2D
			if other == null or not is_instance_valid(other):
				continue
			var to_screen := IsoMathScript.world_to_screen(other.get("sim_pos"))
			draw_line(from_screen, to_screen, VISION_LINK, 1.25)


func _iso_circle_screen_points(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	if radius <= 0.0:
		return points
	for i in VISION_SEGMENTS:
		var angle := TAU * float(i) / float(VISION_SEGMENTS)
		var world := center + Vector2(cos(angle), sin(angle)) * radius
		points.append(IsoMathScript.world_to_screen(world))
	if not points.is_empty():
		points.append(points[0])
	return points


func _run_and_print_vision_timing() -> void:
	if vision == null or not is_inside_tree():
		_last_timing_text = "VisionService missing"
		return
	var units := _focused_units_list()
	var observers := 0
	var total_seen := 0
	var t0 := Time.get_ticks_usec()
	for unit in units:
		if float(unit.get("hp")) <= 0.0:
			continue
		observers += 1
		var seen: Array = vision.others_in_radius(unit)
		total_seen += seen.size()
	var elapsed_usec := Time.get_ticks_usec() - t0
	var elapsed_ms := float(elapsed_usec) / 1000.0
	var avg_usec := 0.0 if observers == 0 else float(elapsed_usec) / float(observers)
	_last_timing_text = (
		"vision query: %d units → %d sightings in %d µs (%.3f ms), avg %.1f µs/unit"
		% [observers, total_seen, elapsed_usec, elapsed_ms, avg_usec]
	)
	print("[vision] ", _last_timing_text)
	var samples := 0
	for unit in units:
		if samples >= 5:
			break
		if float(unit.get("hp")) <= 0.0:
			continue
		var radius := float(vision.vision_radius_of(unit))
		var t_unit := Time.get_ticks_usec()
		var seen: Array = vision.others_in_radius(unit)
		var dt := Time.get_ticks_usec() - t_unit
		print(
			"[vision]   %s team=%s R=%.1f seen=%d %d µs"
			% [str(unit.get("name")), str(unit.get("team")), radius, seen.size(), dt]
		)
		samples += 1


func _focused_units_list() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if not is_inside_tree():
		return result
	for value in get_tree().get_nodes_in_group("units"):
		var unit := value as Node2D
		if unit == null or not is_instance_valid(unit):
			continue
		if float(unit.get("hp")) <= 0.0:
			continue
		if _unit_in_focus(unit):
			result.append(unit)
	return result
