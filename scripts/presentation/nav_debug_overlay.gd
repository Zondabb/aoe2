class_name NavDebugOverlay
extends Node2D

## Press G to toggle solid-cell footprints, unit paths, vision rings, and query timing.

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")
const MovementDebugDrawScript := preload("res://scripts/presentation/movement_debug_draw.gd")

const BLOCK_FILL := Color(0.95, 0.15, 0.12, 0.35)
const BLOCK_EDGE := Color(1.0, 0.35, 0.2, 0.85)
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
var visible_overlay := false
var _hint_label: Label
var _timing_accum := 0.0
var _last_timing_text := ""

func _ready() -> void:
	z_index = 80
	set_process(false)
	_hint_label = Label.new()
	_hint_label.text = (
		"G: blocks/paths/vision | cyan/red rings=vision | yellow links=seen | "
		+ "console prints vision query time"
	)
	_hint_label.position = Vector2(12, 10)
	_hint_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.85, 0.9))
	_hint_label.add_theme_font_size_override("font_size", 14)
	var ui := get_tree().get_first_node_in_group("pathfinding_ui_layer") as CanvasLayer
	if ui != null:
		ui.add_child(_hint_label)
	else:
		var layer := CanvasLayer.new()
		layer.layer = 20
		layer.add_to_group("pathfinding_ui_layer")
		get_parent().call_deferred("add_child", layer)
		layer.call_deferred("add_child", _hint_label)

func _process(delta: float) -> void:
	if not visible_overlay:
		return
	queue_redraw()
	_timing_accum += delta
	if _timing_accum >= TIMING_INTERVAL_SEC:
		_timing_accum = 0.0
		_run_and_print_vision_timing()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_G:
			visible_overlay = not visible_overlay
			set_process(visible_overlay)
			_timing_accum = 0.0
			queue_redraw()
			if visible_overlay:
				_run_and_print_vision_timing()
			get_viewport().set_input_as_handled()

func _draw() -> void:
	if not visible_overlay:
		return
	if nav != null:
		_draw_block_cells()
	_draw_unit_paths()
	_draw_vision_ranges()
	_draw_move_arrows()


func _draw_move_arrows() -> void:
	if not is_inside_tree():
		return
	MovementDebugDrawScript.draw_unit_arrows(self, get_tree().get_nodes_in_group("units"))


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
	var units: Array = get_tree().get_nodes_in_group("units")
	var color_index := 0
	for value in units:
		var unit := value as Node2D
		if unit == null or not is_instance_valid(unit):
			continue
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
	var units: Array = get_tree().get_nodes_in_group("units")
	for value in units:
		var unit := value as Node2D
		if unit == null or not is_instance_valid(unit):
			continue
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
		print("[vision] ", _last_timing_text)
		_refresh_hint()
		return
	var units: Array = get_tree().get_nodes_in_group("units")
	var observers := 0
	var total_seen := 0
	var t0 := Time.get_ticks_usec()
	for value in units:
		var unit := value as Object
		if unit == null or not is_instance_valid(unit):
			continue
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
	# Also print a few per-unit samples for configurable radii.
	var samples := 0
	for value in units:
		if samples >= 5:
			break
		var unit := value as Object
		if unit == null or not is_instance_valid(unit):
			continue
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
	_refresh_hint()


func _refresh_hint() -> void:
	if _hint_label == null:
		return
	var base := (
		"G: blocks/paths/vision | cyan/red rings=vision | yellow links=seen"
	)
	if _last_timing_text.is_empty():
		_hint_label.text = base
	else:
		_hint_label.text = "%s\n%s" % [base, _last_timing_text]
