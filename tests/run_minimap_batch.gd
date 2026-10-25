extends SceneTree
const Map := preload("res://scripts/ui/minimap.gd")
var checks := 0
var failures: Array[String] = []

class MarkerLayer extends Control:
	var map: Minimap
	var batched := false
	func _draw() -> void:
		if batched:
			if map._marker_mesh != null: draw_mesh(map._marker_mesh, null)
			if map._tail_marker_mesh != null: draw_mesh(map._tail_marker_mesh, null)
		else:
			for marker in map._markers:
				var polygon := map._marker_polygon(marker)
				if not polygon.is_empty(): draw_colored_polygon(polygon, map.marker_color(marker))

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var map := Map.new()
	map.size = Vector2(392, 196)
	map.map_min = Vector2(-240, -240)
	map.map_max = Vector2(240, 240)
	var state := MatchState.new()
	state.setup_defaults()
	map.setup(state, null, null)
	for index in 1000:
		map._markers.append({"sim_pos": Vector2(-200 + (index % 40) * 10, -160 + (index / 40) * 12),
			"minimap_kind": "resource", "team": null, "resource_type": Enums.ResourceType.WOOD,
			"footprint": Vector2(4, 4), "memory": index % 2 == 0})
	for team in [Enums.Team.PLAYER, Enums.Team.AI]:
		map._markers.append({"sim_pos": Vector2(team * 30, 5), "minimap_kind": "building", "team": team,
			"footprint": Vector2(8, 8), "memory": false})
		map._markers.append({"sim_pos": Vector2(team * 30, 5), "minimap_kind": "unit", "team": team,
			"footprint": Vector2.ONE, "memory": false})
	map._rebuild_marker_mesh()
	check(map._marker_mesh.get_surface_count() == 1 and map._tail_marker_mesh.get_surface_count() == 1, "static prefix and mobile tail each use one mesh surface")
	var arrays := _mesh_arrays(map)
	check(arrays[Mesh.ARRAY_VERTEX].size() == 4016 and arrays[Mesh.ARRAY_INDEX].size() == 6024, "one quad and two triangles per marker")
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	check(_color_distance(colors[0], map.marker_color(map._markers[0])) <= 1.0 / 255.0 and _color_distance(colors[4], map.marker_color(map._markers[1])) <= 1.0 / 255.0, "visible and remembered colors survive 8-bit mesh color storage")
	state.set_team_color_id(0, 4)
	arrays = _mesh_arrays(map)
	check(_color_distance(arrays[Mesh.ARRAY_COLOR][4000], map.marker_color(map._markers[1000])) <= 1.0 / 255.0, "palette changes immediately refresh cached marker colors")
	map._markers.append({"sim_pos": Vector2(240, 240), "minimap_kind": "building", "team": 0,
		"footprint": Vector2(20, 20), "memory": true})
	for point in map._marker_polygon(map._markers.back()):
		check(map.contains_map_point(point), "edge footprints stay inside the diamond")
	map._rebuild_marker_mesh()
	if DisplayServer.get_name() != "headless":
		await _compare_pixels(map)
	map.size = Vector2(588, 294)
	map._rebuild_marker_mesh()
	check(map._marker_mesh_size == map.size, "resizing refreshes the cached projection")
	map._markers.clear()
	map._rebuild_marker_mesh()
	check(map._marker_mesh == null and map._tail_marker_mesh == null, "empty visibility clears both previous marker surfaces")
	map.free()
	print("MINIMAP BATCH: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _mesh_arrays(map: Minimap) -> Array:
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for mesh in [map._marker_mesh, map._tail_marker_mesh]:
		if mesh == null: continue
		var part: Array = mesh.surface_get_arrays(0)
		var base := vertices.size()
		vertices.append_array(part[Mesh.ARRAY_VERTEX])
		colors.append_array(part[Mesh.ARRAY_COLOR])
		for index in part[Mesh.ARRAY_INDEX]: indices.append(base + index)
	var result := []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = vertices
	result[Mesh.ARRAY_COLOR] = colors
	result[Mesh.ARRAY_INDEX] = indices
	return result

func _compare_pixels(map: Minimap) -> void:
	var views: Array[SubViewport] = []
	for batched in [false, true]:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(400, 200)
		viewport.disable_3d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var layer := MarkerLayer.new()
		layer.map = map
		layer.batched = batched
		viewport.add_child(layer)
		views.append(viewport)
	for _frame in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	var original := views[0].get_texture().get_image()
	var batch := views[1].get_texture().get_image()
	var difference := 0
	var maximum_color_error := 0.0
	var coverage_difference := 0
	var painted := 0
	for y in batch.get_height():
		for x in batch.get_width():
			if batch.get_pixel(x, y).a > 0.1: painted += 1
			if not original.get_pixel(x, y).is_equal_approx(batch.get_pixel(x, y)): difference += 1
			maximum_color_error = maxf(maximum_color_error, _color_distance(original.get_pixel(x, y), batch.get_pixel(x, y)))
			if (original.get_pixel(x, y).a > 0.1) != (batch.get_pixel(x, y).a > 0.1): coverage_difference += 1
	check(painted > 1000, "GPU actually draws the colored marker batch")
	check(coverage_difference == 0, "batch preserves every original marker pixel and overlap order")
	check(maximum_color_error <= 1.001 / 255.0, "mesh differs by at most one 8-bit color step (%d pixels, max %.6f)" % [difference, maximum_color_error])
	batch.save_png("res://.godot/minimap-batch.png")
	for view in views: view.free()

func _color_distance(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), maxf(absf(a.b - b.b), absf(a.a - b.a)))
