extends Node2D

## Draws the translucent green selection rectangle in world space.

var dragging: bool = false
var start: Vector2 = Vector2.ZERO
var current: Vector2 = Vector2.ZERO
var click_threshold: float = 6.0

func _draw() -> void:
	if not dragging:
		return
	if start.distance_to(current) < click_threshold:
		return
	var rect := Rect2(start, current - start).abs()
	draw_rect(rect, Color(0.15, 0.9, 0.25, 0.12), true)
	draw_rect(rect, Color(0.2, 1.0, 0.35, 0.9), false, 1.5)
