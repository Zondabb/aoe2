class_name NavDebugOverlay
extends Node2D

## Press G to toggle solid-cell footprints and unit path polylines.

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const MovementDebugDrawScript := preload("res://scripts/presentation/movement_debug_draw.gd")

const BLOCK_FILL := Color(0.95, 0.15, 0.12, 0.35)
const BLOCK_EDGE := Color(1.0, 0.35, 0.2, 0.85)
const PATH_COLORS := [
	Color(0.25, 0.95, 0.55, 0.95),
	Color(0.35, 0.75, 1.0, 0.95),
	Color(1.0, 0.85, 0.25, 0.95),
	Color(0.95, 0.45, 0.95, 0.95),
	Color(1.0, 0.55, 0.25, 0.95),
]

var nav: NavGridServiceScript
var visible_overlay := false
var _hint_label: Label

func _ready() -> void:
	z_index = 80
	set_process(false)
	_hint_label = Label.new()
	_hint_label.text = "G: blocks/paths/arrows | cyan=intended red=actual | yellow ring=stuck"
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

func _process(_delta: float) -> void:
	if visible_overlay:
		queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_G:
			visible_overlay = not visible_overlay
			set_process(visible_overlay)
			queue_redraw()
			get_viewport().set_input_as_handled()

func _draw() -> void:
	if not visible_overlay:
		return
	if nav != null:
		_draw_block_cells()
	_draw_unit_paths()
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
		# Waypoint dots + goal ring.
		for i in screen_path.size():
			var radius := 3.5 if i == screen_path.size() - 1 else 2.5
			draw_circle(screen_path[i], radius, color)
		draw_arc(screen_path[screen_path.size() - 1], 7.0, 0.0, TAU, 16, color, 1.5)
