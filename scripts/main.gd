extends Node2D

## Demo map: tiled grass, a few elephants, RTS selection/move.

const MAP_SIZE := Vector2(2400, 1600)

@onready var camera: Camera2D = $Camera2D
@onready var units: Node2D = $Units
@onready var selection: SelectionController = $SelectionController

var _pan_speed: float = 520.0
var _edge_pan_margin: float = 18.0

func _ready() -> void:
	_build_grass()
	_spawn_elephants()
	camera.position = MAP_SIZE * 0.5
	selection.unit_parent_path = selection.get_path_to(units)

func _build_grass() -> void:
	var grass_tex: Texture2D = load("res://assets/grass.png")
	var ground := Node2D.new()
	ground.name = "Ground"
	ground.z_index = -100
	add_child(ground)
	move_child(ground, 0)

	var tile := 256
	var cols := int(ceil(MAP_SIZE.x / tile)) + 1
	var rows := int(ceil(MAP_SIZE.y / tile)) + 1
	for y in range(rows):
		for x in range(cols):
			var spr := Sprite2D.new()
			spr.texture = grass_tex
			spr.centered = false
			spr.position = Vector2(x * tile, y * tile)
			spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			ground.add_child(spr)

	# Soft vignette / map edge marker.
	var border := Line2D.new()
	border.width = 3.0
	border.default_color = Color(0.25, 0.45, 0.18, 0.8)
	border.points = PackedVector2Array([
		Vector2(0, 0),
		Vector2(MAP_SIZE.x, 0),
		Vector2(MAP_SIZE.x, MAP_SIZE.y),
		Vector2(0, MAP_SIZE.y),
		Vector2(0, 0),
	])
	ground.add_child(border)

func _spawn_elephants() -> void:
	var packed: PackedScene = load("res://scenes/elephant.tscn")
	var positions := [
		MAP_SIZE * 0.5,
		MAP_SIZE * 0.5 + Vector2(-120, 40),
		MAP_SIZE * 0.5 + Vector2(140, -30),
	]
	for pos in positions:
		var elephant: Elephant = packed.instantiate()
		elephant.position = pos
		units.add_child(elephant)
		selection.register_unit(elephant)

func _process(delta: float) -> void:
	_update_camera(delta)

func _update_camera(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move.y += 1.0

	# Screen-edge pan (AoE-style).
	var vp := get_viewport().get_visible_rect().size
	var mouse := get_viewport().get_mouse_position()
	if mouse.x <= _edge_pan_margin:
		move.x -= 1.0
	elif mouse.x >= vp.x - _edge_pan_margin:
		move.x += 1.0
	if mouse.y <= _edge_pan_margin:
		move.y -= 1.0
	elif mouse.y >= vp.y - _edge_pan_margin:
		move.y += 1.0

	if move != Vector2.ZERO:
		camera.position += move.normalized() * _pan_speed * delta
		camera.position = camera.position.clamp(Vector2(200, 150), MAP_SIZE - Vector2(200, 150))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			camera.zoom = (camera.zoom * 1.1).clamp(Vector2(0.5, 0.5), Vector2(2.5, 2.5))
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			camera.zoom = (camera.zoom / 1.1).clamp(Vector2(0.5, 0.5), Vector2(2.5, 2.5))
