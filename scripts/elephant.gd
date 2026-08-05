extends CharacterBody2D
class_name Elephant

## AoE2-style war elephant: 5 authored directions + horizontal flip for the other 3.

signal selection_changed(selected: bool)

const FRAME_W := 129
const FRAME_H := 115
const COLS := 10
const ROWS := 5
const ARRIVE_DIST := 4.0

## Sheet rows (top -> bottom): South, Southwest, West, Northwest, North
enum Dir { S, SW, W, NW, N, NE, E, SE }

@export var move_speed: float = 70.0
@export var anim_fps: float = 10.0

var _selected: bool = false

var selected: bool:
	get:
		return _selected
	set(value):
		if _selected == value:
			return
		_selected = value
		queue_redraw()
		selection_changed.emit(_selected)

var _target: Vector2
var _has_target: bool = false
var _moving: bool = false
var _dir: int = Dir.S
var _flip_h: bool = false
var _frame: float = 0.0
var _sprite: Sprite2D
var _shadow: Polygon2D

func _ready() -> void:
	motion_mode = MOTION_MODE_FLOATING
	collision_layer = 1
	collision_mask = 0
	_target = global_position
	_build_visuals()
	_apply_frame()

func _build_visuals() -> void:
	_shadow = Polygon2D.new()
	_shadow.color = Color(0, 0, 0, 0.35)
	_shadow.polygon = PackedVector2Array([
		Vector2(-28, -8), Vector2(28, -8), Vector2(18, 8), Vector2(-18, 8)
	])
	_shadow.position = Vector2(0, 8)
	_shadow.z_index = -1
	add_child(_shadow)

	_sprite = Sprite2D.new()
	_sprite.texture = load("res://assets/elephant_walk.png")
	_sprite.hframes = COLS
	_sprite.vframes = ROWS
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Anchor near the feet so the unit sits on the ground point.
	_sprite.offset = Vector2(0, -FRAME_H * 0.35)
	add_child(_sprite)

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 28.0
	shape.shape = circle
	shape.position = Vector2(0, 0)
	add_child(shape)

func _draw() -> void:
	if not selected:
		return
	# AoE2-like selection ellipse under the unit.
	draw_arc(Vector2(0, 6), 30.0, 0.0, TAU, 48, Color(0.15, 0.85, 0.2, 0.95), 2.0, true)
	draw_arc(Vector2(0, 6), 30.0, 0.0, TAU, 48, Color(0.05, 0.35, 0.08, 0.35), 5.0, true)

func _physics_process(delta: float) -> void:
	if _has_target:
		var to_target := _target - global_position
		var dist := to_target.length()
		if dist <= ARRIVE_DIST:
			global_position = _target
			velocity = Vector2.ZERO
			_has_target = false
			_moving = false
			_frame = 0.0
		else:
			_moving = true
			var dir_vec := to_target / dist
			velocity = dir_vec * move_speed
			_set_direction_from_vector(dir_vec)
			move_and_slide()
	else:
		velocity = Vector2.ZERO
		_moving = false

	if _moving:
		_frame = fmod(_frame + anim_fps * delta, float(COLS))
	_apply_frame()
	z_index = int(global_position.y)

func command_move_to(world_pos: Vector2) -> void:
	_target = world_pos
	_has_target = true

func stop() -> void:
	_has_target = false
	_moving = false
	velocity = Vector2.ZERO
	_frame = 0.0
	_apply_frame()

func contains_world_point(world_pos: Vector2) -> bool:
	return global_position.distance_to(world_pos) <= 36.0

func get_selection_point() -> Vector2:
	return global_position

func _set_direction_from_vector(v: Vector2) -> void:
	# 8-way sector; Godot 2D angle: 0 = East, positive = clockwise (Y-down).
	var ang := v.angle()
	var sector := int(round(ang / (PI / 4.0)))
	sector = posmod(sector, 8)
	# sector: 0=E, 1=SE, 2=S, 3=SW, 4=W, 5=NW, 6=N, 7=NE
	match sector:
		0:
			_dir = Dir.E
		1:
			_dir = Dir.SE
		2:
			_dir = Dir.S
		3:
			_dir = Dir.SW
		4:
			_dir = Dir.W
		5:
			_dir = Dir.NW
		6:
			_dir = Dir.N
		7:
			_dir = Dir.NE

func _apply_frame() -> void:
	if _sprite == null:
		return
	var row := 0
	var flip := false
	match _dir:
		Dir.S:
			row = 0
		Dir.SW:
			row = 1
		Dir.W:
			row = 2
		Dir.NW:
			row = 3
		Dir.N:
			row = 4
		Dir.NE:
			row = 3
			flip = true
		Dir.E:
			row = 2
			flip = true
		Dir.SE:
			row = 1
			flip = true
	_flip_h = flip
	_sprite.flip_h = flip
	_sprite.frame = row * COLS + int(_frame)
