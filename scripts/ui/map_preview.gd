extends Control

var data: Dictionary = {}

func show_map(value: Dictionary) -> void:
	data = value
	queue_redraw()

func _draw() -> void:
	var diamond := PackedVector2Array([Vector2(size.x / 2, 12), Vector2(size.x - 18, size.y / 2), Vector2(size.x / 2, size.y - 12), Vector2(18, size.y / 2)])
	draw_colored_polygon(diamond, Color("586240"))
	var border := diamond.duplicate()
	border.append(diamond[0])
	draw_polyline(border, Color("b1a275"), 2)
	if data.is_empty():
		return
	var bounds := MapData.bounds(data)
	for record in data.entities:
		var uv := (MapData.position_of(record) - bounds.position) / bounds.size
		var point := Vector2(size.x / 2 + (uv.x - uv.y) * (size.x / 2 - 18), 12 + (uv.x + uv.y) * (size.y / 2 - 12))
		var color := Color("538feb") if record.get("team") == "player" else Color("d45142")
		if record.type == "resource":
			color = Color("d9bd5f") if record.resource_type == "gold" else Color("adc578")
		if record.type == "building":
			draw_rect(Rect2(point - Vector2.ONE * 4, Vector2.ONE * 8), color)
		else:
			draw_circle(point, 2.5, color)
