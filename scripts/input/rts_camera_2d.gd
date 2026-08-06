# scripts/input/rts_camera_2d.gd
class_name RtsCamera2D
extends Camera2D

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

@export var pan_speed := 900.0
@export var edge_margin := 18.0
@export var zoom_step := 0.1
@export var min_zoom := 0.45
@export var max_zoom := 1.8

func _ready() -> void:
	zoom = Vector2.ONE

func focus_on(world_position: Vector2) -> void:
	position = IsoMathScript.world_to_screen(world_position)

func _process(delta: float) -> void:
	var pan_input := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		pan_input.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		pan_input.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		pan_input.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		pan_input.y += 1.0

	var viewport_size := get_viewport().get_visible_rect().size
	var mouse_position := get_viewport().get_mouse_position()
	if mouse_position.x <= edge_margin:
		pan_input.x -= 1.0
	elif mouse_position.x >= viewport_size.x - edge_margin:
		pan_input.x += 1.0
	if mouse_position.y <= edge_margin:
		pan_input.y -= 1.0
	elif mouse_position.y >= viewport_size.y - edge_margin:
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

func _set_zoom(value: float) -> void:
	var clamped := clampf(value, min_zoom, max_zoom)
	zoom = Vector2(clamped, clamped)
