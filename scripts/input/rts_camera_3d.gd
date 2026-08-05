# scripts/input/rts_camera_3d.gd
class_name RtsCamera3D
extends Camera3D

@export_range(0.0, 90.0, 0.1) var pitch_degrees := 50.0
@export_range(-180.0, 180.0, 0.1) var yaw_degrees := 45.0
@export var pan_speed := 24.0
@export var edge_margin := 18.0
@export var zoom_step := 5.0
@export var min_distance := 18.0
@export var max_distance := 80.0
@export var distance := 42.0

func _ready() -> void:
	_apply_view()

func _process(delta: float) -> void:
	var pan_input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan_input.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan_input.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan_input.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan_input.y -= 1.0

	var viewport_size := get_viewport().get_visible_rect().size
	var mouse_position := get_viewport().get_mouse_position()
	if mouse_position.x <= edge_margin:
		pan_input.x -= 1.0
	elif mouse_position.x >= viewport_size.x - edge_margin:
		pan_input.x += 1.0
	if mouse_position.y <= edge_margin:
		pan_input.y += 1.0
	elif mouse_position.y >= viewport_size.y - edge_margin:
		pan_input.y -= 1.0

	if pan_input != Vector2.ZERO:
		_pan(pan_input.normalized(), delta)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = clampf(distance - zoom_step, min_distance, max_distance)
			_apply_view()
		elif mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = clampf(distance + zoom_step, min_distance, max_distance)
			_apply_view()

func _pan(input_direction: Vector2, delta: float) -> void:
	var rig := get_parent_node_3d()
	if rig == null:
		return
	var right := rig.basis.x.normalized()
	var forward := -rig.basis.z.normalized()
	rig.position += (
		right * input_direction.x + forward * input_direction.y
	) * pan_speed * delta

func _apply_view() -> void:
	distance = clampf(distance, min_distance, max_distance)
	var rig := get_parent_node_3d()
	if rig != null:
		rig.rotation.y = deg_to_rad(yaw_degrees)
	var pitch := deg_to_rad(pitch_degrees)
	position = Vector3(0.0, sin(pitch) * distance, cos(pitch) * distance)
	rotation = Vector3(-pitch, 0.0, 0.0)
