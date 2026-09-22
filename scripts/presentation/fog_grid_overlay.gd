extends Node2D

const Iso := preload("res://scripts/presentation/iso_math.gd")
var holder: Node

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()

func _draw() -> void:
	if holder == null or holder.view_team < 0:
		return
	var fog: RefCounted = holder.fog
	var viewport_rect := get_viewport_rect().grow(60)
	for y in fog.side:
		for x in fog.side:
			var pos: Vector2 = Vector2.ONE * fog.map_min + Vector2(x, y) * fog.cell_size
			var pixel := Iso.world_to_screen(pos)
			if not viewport_rect.has_point(get_viewport_transform() * pixel):
				continue
			var state: int = fog.state_at(holder.view_team, pos + Vector2.ONE*fog.cell_size*0.5)
			var colors := [Color(0.3,0.3,0.3,0.5), Color(0.9,0.7,0.2,0.6), Color(0.2,0.9,0.5,0.6)]
			var corners := PackedVector2Array()
			for corner in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN, Vector2.ZERO]:
				corners.append(Iso.world_to_screen(pos + corner*fog.cell_size))
			draw_polyline(corners, colors[state], 1.0)
