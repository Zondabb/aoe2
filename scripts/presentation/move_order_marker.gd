extends Node2D

## Classic ground-order feedback: four red chevrons converge on the click.
const Iso := preload("res://scripts/presentation/iso_math.gd")
const DURATION := 0.7
var elapsed := DURATION

func _ready() -> void:
	z_index = 50
	visible = false
	set_process(false)

func play_at(logical_target: Vector2) -> void:
	position = Iso.world_to_screen(logical_target)
	elapsed = 0.0
	modulate = Color.WHITE
	visible = true
	set_process(true)
	queue_redraw()

func _process(delta: float) -> void:
	elapsed = minf(DURATION, elapsed + delta)
	if elapsed >= DURATION:
		visible = false
		set_process(false)
	queue_redraw()

func _draw() -> void:
	if elapsed >= DURATION:
		return
	var phase := elapsed / DURATION
	var distance := lerpf(19.0, 2.0, 1.0 - pow(1.0 - phase, 3.0))
	var alpha := 1.0 - smoothstep(0.65, 1.0, phase)
	for direction in [Vector2(-1, -0.5), Vector2(1, -0.5), Vector2(1, 0.5), Vector2(-1, 0.5)]:
		var tip: Vector2 = direction * distance
		var points := PackedVector2Array([tip + Vector2(direction.x * 7.0, 0), tip, tip + Vector2(0, direction.y * 7.0)])
		draw_polyline(points, Color(0.16, 0.035, 0.015, alpha), 5.0, true)
		draw_polyline(points, Color(1.0, 0.18, 0.06, alpha), 2.5, true)
