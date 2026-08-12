extends Node2D

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const MovementDebugDrawScript := preload("res://scripts/presentation/movement_debug_draw.gd")

var _selected_units: Array[Node2D] = []
var _show_footprints := true
var nav: NavGridServiceScript

func _ready() -> void:
	z_index = 40
	set_process(true)

func set_nav(service: NavGridServiceScript) -> void:
	nav = service
	queue_redraw()

func _process(_delta: float) -> void:
	queue_redraw()

func set_selected_units(units: Array) -> void:
	_selected_units.clear()
	for unit in units:
		var node := unit as Node2D
		if node != null and is_instance_valid(node):
			_selected_units.append(node)

func toggle_footprints() -> void:
	_show_footprints = not _show_footprints
	queue_redraw()

func _draw() -> void:
	if _show_footprints:
		if nav != null:
			_draw_nav_solid_cells()
		else:
			_draw_resource_footprints()
			_draw_building_footprints()
	_draw_unit_paths()
	_draw_move_arrows()


func _draw_move_arrows() -> void:
	var units: Array = []
	units.append_array(_selected_units)
	if units.is_empty():
		units.assign(get_tree().get_nodes_in_group("units"))
	MovementDebugDrawScript.draw_unit_arrows(self, units, true, self)

func _draw_nav_solid_cells() -> void:
	var cells: Array[Vector2i] = nav.get_solid_cells()
	var half := nav.cell_size * 0.5
	for cell in cells:
		var center := nav.cell_to_world_center(cell)
		var corners := PackedVector2Array([
			to_local(IsoMathScript.world_to_screen(center + Vector2(-half, -half))),
			to_local(IsoMathScript.world_to_screen(center + Vector2(half, -half))),
			to_local(IsoMathScript.world_to_screen(center + Vector2(half, half))),
			to_local(IsoMathScript.world_to_screen(center + Vector2(-half, half))),
		])
		draw_colored_polygon(corners, Color(0.95, 0.25, 0.15, 0.22))
		var outline := corners.duplicate()
		outline.append(corners[0])
		draw_polyline(outline, Color(1.0, 0.35, 0.2, 0.85), 1.5)

func _draw_resource_footprints() -> void:
	for resource in get_tree().get_nodes_in_group("resource_nodes"):
		var node := resource as Node2D
		if node == null or float(node.get("amount")) <= 0.0:
			continue
		var resource_type: int = int(node.get("resource_type"))
		var color := Color(0.2, 0.85, 0.35, 0.18)
		if ResourceNodeScript.resource_blocks_pathfinding(resource_type):
			color = Color(0.95, 0.25, 0.15, 0.22)
		var half_variant = node.get("block_half")
		var footprint := (half_variant as Vector2) * 2.0 if half_variant is Vector2 else (
			ResourceNodeScript.pathfinding_footprint(resource_type)
		)
		_draw_footprint(node.get("sim_pos"), footprint, color)

func _draw_building_footprints() -> void:
	for building in get_tree().get_nodes_in_group("buildings"):
		var node := building as Node2D
		if node == null:
			continue
		var half_variant = node.get("block_half")
		var footprint: Vector2
		if half_variant is Vector2:
			footprint = (half_variant as Vector2) * 2.0
		else:
			var building_def := node.get("def") as BuildingDef
			if building_def == null:
				continue
			footprint = building_def.footprint
		_draw_footprint(node.get("sim_pos"), footprint, Color(0.25, 0.45, 0.95, 0.20))

func _draw_footprint(center: Vector2, footprint: Vector2, color: Color) -> void:
	if footprint.length_squared() <= 0.0:
		return
	var half := footprint * 0.5
	var corners := [
		center + Vector2(-half.x, -half.y),
		center + Vector2(half.x, -half.y),
		center + Vector2(half.x, half.y),
		center + Vector2(-half.x, half.y),
	]
	var screen_corners: PackedVector2Array = PackedVector2Array()
	for corner in corners:
		screen_corners.append(to_local(IsoMathScript.world_to_screen(corner)))
	draw_colored_polygon(screen_corners, color)
	var outline: PackedVector2Array = screen_corners.duplicate()
	outline.append(screen_corners[0])
	draw_polyline(outline, Color(color.r, color.g, color.b, 0.85), 2.0)

func _draw_unit_paths() -> void:
	for unit in _selected_units:
		if not is_instance_valid(unit) or not unit.has_method("get_nav_path_debug"):
			continue
		var points: PackedVector2Array = unit.call("get_nav_path_debug")
		if points.size() < 2:
			continue
		var screen_points: PackedVector2Array = PackedVector2Array()
		for point in points:
			screen_points.append(to_local(IsoMathScript.world_to_screen(point)))
		draw_polyline(screen_points, Color(0.95, 0.85, 0.15, 0.95), 3.0)
		for index in range(1, screen_points.size()):
			draw_circle(screen_points[index], 4.0, Color(1.0, 0.55, 0.1, 0.9))
