# scripts/input/rts_camera_2d.gd
class_name RtsCamera2D
extends Camera2D

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

@export var pan_speed := 900.0
@export var edge_margin := 18.0
@export var zoom_step := 0.1
@export var min_zoom := 0.45
@export var max_zoom := 1.8
@export var limit_to_map_bounds := true
@export var map_world_min := Vector2(-60.0, -60.0)
@export var map_world_max := Vector2(60.0, 60.0)

func _ready() -> void:
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
	var over_ui := get_viewport().gui_get_hovered_control() != null
	if not over_ui and mouse_position.x <= edge_margin:
		pan_input.x -= 1.0
	elif not over_ui and mouse_position.x >= viewport_size.x - edge_margin:
		pan_input.x += 1.0
	if not over_ui and mouse_position.y <= edge_margin:
		pan_input.y -= 1.0
	elif not over_ui and mouse_position.y >= viewport_size.y - edge_margin:
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
	var speed := pan_speed * delta / maxf(zoom.x, 0.001)
	position += input_direction * speed
	_clamp_position()

func _set_zoom(value: float) -> void:
	var clamped := clampf(value, min_zoom, max_zoom)
	zoom = Vector2(clamped, clamped)
	_clamp_position()

func _clamp_position() -> void:
	if not limit_to_map_bounds or not is_inside_tree():
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
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
	if min_pos.x > max_pos.x:
		position.x = (min_screen.x + max_screen.x) * 0.5
	else:
		position.x = clampf(position.x, min_pos.x, max_pos.x)
	if min_pos.y > max_pos.y:
		position.y = (min_screen.y + max_screen.y) * 0.5
	else:
		position.y = clampf(position.y, min_pos.y, max_pos.y)
