class_name MovementDebugDraw
extends RefCounted

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

const STEER_COLOR := Color(0.15, 0.95, 1.0, 0.95)
const ACTUAL_COLOR := Color(1.0, 0.22, 0.18, 0.95)
const STUCK_RING := Color(1.0, 0.82, 0.1, 0.9)
const PENDING_COLOR := Color(0.75, 0.75, 0.75, 0.85)

const MIN_ARROW_PX := 14.0
const MAX_ARROW_PX := 52.0
const ARROW_SCALE_PX := 16.0


static func draw_unit_arrows(
	canvas: CanvasItem,
	units: Array,
	use_local_coords: bool = false,
	local_anchor: Node2D = null
) -> void:
	for value in units:
		var unit := value as Node2D
		if unit == null or not is_instance_valid(unit):
			continue
		if not unit.has_method("get_move_debug"):
			continue
		var debug: Dictionary = unit.call("get_move_debug")
		var sim_pos: Vector2 = debug.get("sim_pos", unit.get("sim_pos"))
		var origin := _to_draw_pos(sim_pos, use_local_coords, local_anchor)
		if bool(debug.get("stuck", false)):
			canvas.draw_arc(origin, 10.0, 0.0, TAU, 18, STUCK_RING, 2.0)
		if bool(debug.get("pending", false)):
			canvas.draw_circle(origin, 4.0, PENDING_COLOR)
		var steer: Vector2 = debug.get("steer", Vector2.ZERO)
		var actual: Vector2 = debug.get("actual", Vector2.ZERO)
		var steer_color: Color = STEER_COLOR
		if bool(debug.get("pending", false)):
			steer_color = STEER_COLOR.lerp(PENDING_COLOR, 0.35)
		_draw_arrow(canvas, origin, sim_pos, steer, steer_color)
		_draw_arrow(canvas, origin, sim_pos, actual, ACTUAL_COLOR)


static func _to_draw_pos(
	world_pos: Vector2, use_local_coords: bool, local_anchor: Node2D
) -> Vector2:
	var screen_pos := IsoMathScript.world_to_screen(world_pos)
	if use_local_coords and local_anchor != null:
		return local_anchor.to_local(screen_pos)
	return screen_pos


static func _draw_arrow(
	canvas: CanvasItem,
	origin: Vector2,
	world_pos: Vector2,
	logic_vec: Vector2,
	color: Color
) -> void:
	if logic_vec.length_squared() < 0.000001:
		return
	var dir_screen := _logic_dir_to_screen(world_pos, logic_vec)
	var length := clampf(dir_screen.length() * ARROW_SCALE_PX, MIN_ARROW_PX, MAX_ARROW_PX)
	if length < 2.0:
		return
	var dir := dir_screen.normalized()
	var tip := origin + dir * length
	canvas.draw_line(origin, tip, color, 2.5)
	var back := -dir * 8.0
	canvas.draw_line(tip, tip + back.rotated(deg_to_rad(24.0)), color, 2.5)
	canvas.draw_line(tip, tip + back.rotated(deg_to_rad(-24.0)), color, 2.5)


static func _logic_dir_to_screen(world_pos: Vector2, logic_vec: Vector2) -> Vector2:
	var from := IsoMathScript.world_to_screen(world_pos)
	var to := IsoMathScript.world_to_screen(world_pos + logic_vec)
	return to - from
