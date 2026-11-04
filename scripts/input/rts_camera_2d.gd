# scripts/input/rts_camera_2d.gd
class_name RtsCamera2D
extends Camera2D

signal manual_navigation

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
var broadcast_following := false

@export var pan_speed := 900.0
@export var edge_margin := 18.0
@export var zoom_step := 0.1
@export var min_zoom := 0.45
@export var max_zoom := 1.8
@export var limit_to_map_bounds := true
@export var map_world_min := Vector2(-60.0, -60.0)
@export var map_world_max := Vector2(60.0, 60.0)

func _init() -> void:
	# Camera panning and minimap focus run on rendered frames, not physics ticks.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	zoom = Vector2.ONE
	_clamp_position()

func configure_for_map(ground_min: float, ground_max: float, focus: Vector2) -> void:
	set_map_bounds(Vector2(ground_min, ground_min), Vector2(ground_max, ground_max))
	focus_on(focus)

func set_map_bounds(world_min: Vector2, world_max: Vector2) -> void:
	map_world_min = world_min
	map_world_max = world_max
	_clamp_position()

func focus_on(world_position: Vector2) -> void:
	manual_navigation.emit()
	position = IsoMathScript.world_to_screen(world_position)
	_clamp_position()

func _process(delta: float) -> void:
	var pan_input := Vector2.ZERO
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	# Letter keys belong to the selected unit's commands (AoE II classic layout).
	if Input.is_key_pressed(KEY_LEFT):
		pan_input.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		pan_input.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		pan_input.y -= 1.0
	if Input.is_key_pressed(KEY_DOWN):
		pan_input.y += 1.0

	var viewport_size := get_viewport().get_visible_rect().size
	var mouse_position := get_viewport().get_mouse_position()
	# GUI navigation (especially dragging the minimap) must not also edge-pan.
	# A parked cursor at the edge mustn't pan a live broadcast indefinitely.
	var edge_pan := not broadcast_following and get_viewport().gui_get_hovered_control() == null
	if edge_pan and mouse_position.x <= edge_margin:
		pan_input.x -= 1.0
	elif edge_pan and mouse_position.x >= viewport_size.x - edge_margin:
		pan_input.x += 1.0
	if edge_pan and mouse_position.y <= edge_margin:
		pan_input.y -= 1.0
	elif edge_pan and mouse_position.y >= viewport_size.y - edge_margin:
		pan_input.y += 1.0

	if pan_input != Vector2.ZERO:
		_pan(pan_input.normalized(), delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(zoom.x + zoom_step)
		elif mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(zoom.x - zoom_step)

func _pan(input_direction: Vector2, delta: float) -> void:
	manual_navigation.emit()
	var speed := pan_speed * delta / maxf(zoom.x, 0.001)
	position += input_direction * speed
	_clamp_position()

func _set_zoom(value: float) -> void:
	manual_navigation.emit()
	var clamped := clampf(value, min_zoom, max_zoom)
	zoom = Vector2(clamped, clamped)
	_clamp_position()

func _clamp_position() -> void:
	position = clamped_position(position)

func clamped_position(point: Vector2) -> Vector2:
	if not limit_to_map_bounds or not is_inside_tree():
		return point
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return point
	var half_view := viewport_size * 0.5 / maxf(zoom.x, 0.001)
	var corners := [
		Vector2(map_world_min.x, map_world_min.y),
		Vector2(map_world_max.x, map_world_min.y),
		Vector2(map_world_min.x, map_world_max.y),
		Vector2(map_world_max.x, map_world_max.y),
	]
	var min_screen := Vector2(INF, INF)
	var max_screen := Vector2(-INF, -INF)
	for corner in corners:
		var screen := IsoMathScript.world_to_screen(corner)
		min_screen = min_screen.min(screen)
		max_screen = max_screen.max(screen)
	var min_pos := min_screen + half_view
	var max_pos := max_screen - half_view
	var center := (min_screen + max_screen) * 0.5
	return point.clamp(min_pos.min(center), max_pos.max(center))
