extends Control

const SHORE := preload("res://scripts/world/shore_geometry.gd")

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
	var water_rects: Array[Rect2] = []
	for record in data.entities:
		if record.type == "terrain" and record.terrain_id == "water":
			var half := MapCatalog.half_size(record)
			water_rects.append(Rect2(MapData.position_of(record) - half, half * 2.0))
	var coasts := SHORE.build_contours(water_rects)
	var layers: Array[Dictionary] = []
	for contour in coasts:
		var depth := 0
		for other in coasts:
			if other != contour and Geometry2D.is_point_in_polygon(contour[0], other): depth += 1
		layers.append({"contour":contour, "depth":depth})
	layers.sort_custom(func(a: Dictionary, b: Dictionary): return a.depth < b.depth)
	for layer in layers:
		var polygon := PackedVector2Array()
		for point in layer.contour: polygon.append(_preview_point(point, bounds))
		draw_colored_polygon(polygon, Color("2e6699") if layer.depth % 2 == 0 else Color("586240"))
		polygon.append(polygon[0])
		draw_polyline(polygon, Color("ddd0b4"), 1.0, true)
	for record in data.entities:
		if record.type != "terrain" or record.terrain_id == "water": continue
		var half := MapCatalog.half_size(record)
		var center := MapData.position_of(record)
		var polygon := PackedVector2Array()
		for offset in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
			polygon.append(_preview_point(center + offset, bounds))
		draw_colored_polygon(polygon, Color("2e6699") if record.terrain_id == "water" else Color("8c8773"))
	for record in data.entities:
		if record.type == "terrain": continue
		var point := _preview_point(MapData.position_of(record), bounds)
		var color := Color("538feb") if record.get("team") == "player" else Color("d45142")
		if record.type == "resource":
			color = Color("d9bd5f") if record.resource_type == "gold" else Color("adc578")
		if record.type == "building":
			draw_rect(Rect2(point - Vector2.ONE * 4, Vector2.ONE * 8), color)
		else:
			draw_circle(point, 2.5, color)

func _preview_point(position: Vector2, bounds: Rect2) -> Vector2:
	var uv := (position - bounds.position) / bounds.size
	return Vector2(size.x / 2 + (uv.x - uv.y) * (size.x / 2 - 18), 12 + (uv.x + uv.y) * (size.y / 2 - 12))
