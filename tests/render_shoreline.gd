extends SceneTree

## Actual GL framebuffer checks for irregular original-art beaches, world UVs,
## adjoining lakes and fog. Run without --headless; --label baseline captures
## the unchanged production implementation before a shoreline revision.
const BLOCKER := preload("res://scripts/entities/path_blocker.gd")
const VISUAL := preload("res://scripts/presentation/terrain_visual.gd")
const ISO := preload("res://scripts/presentation/iso_math.gd")
const LOADER := preload("res://scripts/world/map_loader.gd")
const DATA := preload("res://scripts/world/map_data.gd")
const FOG_HOLDER := preload("res://scripts/systems/fog_of_war_holder.gd")
const SIZE := Vector2i(1280, 800)
var checks := 0
var failures: Array[String] = []
var capture_label := "current"
var viewport: SubViewport
var stage: Node2D
var entities: Node2D

class FogProbe extends Node2D:
	var hp := 100.0
	var team := 0
	var sim_pos := Vector2(5, 0)
	func resolved_vision_radius() -> float: return 4.0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for index in args.size():
		if args[index] == "--label" and index + 1 < args.size():
			capture_label = args[index + 1].validate_filename()
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for index in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func region(size: Vector2, sim_pos := Vector2.ZERO) -> PathBlocker:
	var result := BLOCKER.new() as PathBlocker
	result.kind = &"water"
	result.block_size = size
	result.auto_block_size = false
	result.sim_pos = sim_pos
	entities.add_child(result)
	return result

func clear_regions() -> void:
	for child in entities.get_children():
		child.free()

func capture(label: String, zoom: float, center := Vector2.ZERO) -> Image:
	stage.scale = Vector2.ONE * zoom
	stage.position = Vector2(SIZE) * 0.5 - ISO.world_to_screen(center) * zoom
	await frame()
	var pixels := viewport.get_texture().get_image()
	var output := "res://.godot/shoreline-%s-%s-zoom-%03d.png" % [capture_label, label, roundi(zoom * 100.0)]
	check(pixels.save_png(output) == OK, "%s zoom %.2f framebuffer is saved" % [label, zoom])
	print("SHORELINE_CAPTURE %s" % output)
	return pixels

func world_pixel(point: Vector2) -> Vector2i:
	return Vector2i(stage.position + ISO.world_to_screen(point) * stage.scale)

func blue(color: Color) -> bool:
	return color.b > color.r + 0.045 and color.b > color.g + 0.025

func pale_sand(color: Color) -> bool:
	# Exclude yellow-green grass and the outer blended fringe: fog assertions
	# must sample the original pale sand itself rather than ordinary ground.
	return color.r > 0.70 and color.g > 0.62 and color.b > 0.50 and color.r > color.g + 0.02 and color.r > color.b + 0.08

func turquoise(color: Color) -> bool:
	# Original HD g_sh2 is turquoise, with green slightly above blue. This
	# distinguishes a real shallow band from deep blue water and green grass.
	return color.g > 0.45 and color.g > color.r + 0.08 and color.b > color.r + 0.08 and color.g >= color.b * 0.98

func difference_statistics(before: Image, after: Image) -> Dictionary:
	var visible := 0
	var maximum := 0.0
	for y in before.get_height():
		for x in before.get_width():
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			var difference := maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))
			maximum = maxf(maximum, difference)
			if difference > 2.01 / 255.0: visible += 1
	return {"visible":visible, "maximum_channel_difference":maximum}

func shoreline_statistics(pixels: Image) -> Dictionary:
	var sand := 0
	var water := 0
	var shallow := 0
	for y in pixels.get_height():
		for x in pixels.get_width():
			var value := pixels.get_pixel(x, y)
			if pale_sand(value): sand += 1
			if blue(value): water += 1
			if turquoise(value): shallow += 1
	# Sample the first blue pixel along the same straight logical edge. A hard
	# rectangle would produce one constant x coordinate across all these rows.
	var minimum := INF
	var maximum := -INF
	var samples := 0
	for index in 65:
		var edge_y := -4.0 + float(index) * 0.125
		for depth in 321:
			var edge_x := 16.0 - float(depth) * 0.05
			var point := world_pixel(Vector2(edge_x, edge_y))
			if not Rect2i(Vector2i.ZERO, SIZE).has_point(point): continue
			if blue(pixels.get_pixelv(point)):
				minimum = minf(minimum, edge_x)
				maximum = maxf(maximum, edge_x)
				samples += 1
				break
	return {"sand_pixels":sand, "water_pixels":water, "shallow_pixels":shallow,
		"edge_samples":samples, "edge_span":maximum - minimum if samples > 0 else 0.0}

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "shoreline detail requires an actual graphics backend")
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.disable_3d = true
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	stage = Node2D.new()
	viewport.add_child(stage)
	var ground := Node2D.new()
	stage.add_child(ground)
	var data := DATA.create()
	data.bounds = {"min": [-256, -256], "max": [256, 256]}
	LOADER.setup_ground(data, ground)
	entities = Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	stage.add_child(entities)
	var lake := region(Vector2(32, 22))
	var native := await capture("lake", 1.0)
	if capture_label != "baseline":
		check(lake.block_half == Vector2(16, 11), "irregular shoreline keeps the complete logical blocker")
		check(lake.get_node("SelectionFootprint").points == VISUAL.footprint(lake.block_size), "editor retains the exact terrain rectangle selection")
		var surface := lake.get_node("Billboard") as Polygon2D
		check(surface.polygon == VISUAL.footprint(lake.block_size), "shader clips the coast inside the unchanged logical render bounds")
		check(surface.material is ShaderMaterial, "water has a material for beach and shallow-water transitions")
		check(surface.texture != null and surface.texture.get_image().has_mipmaps(), "deep water uses original art with distant-camera mipmaps")
		if surface.material is ShaderMaterial:
			var material := surface.material as ShaderMaterial
			check(material.shader.resource_path == "res://shaders/terrain_water.gdshader", "coast uses the dedicated water shader")
			check(material.get_shader_parameter("coast_count") > 4, "water receives an irregular multi-segment coastline")
			for pair: Array in [["sand_texture", "res://assets/terrain/beach.png"], ["shallow_texture", "res://assets/terrain/shallow.png"], ["grass_texture", "res://assets/terrain/grass.png"]]:
				var texture := material.get_shader_parameter(pair[0]) as Texture2D
				check(texture != null and texture.resource_path == pair[1], "transition uses original %s terrain pixels" % pair[0])
				check(texture != null and texture.get_image().has_mipmaps(), "%s retains filtered details when the camera shrinks" % pair[0])
		var metrics := shoreline_statistics(native)
		print("SHORELINE_METRICS %s" % JSON.stringify(metrics))
		check(metrics.sand_pixels > 500, "native lake displays a pale original-art sand beach")
		check(metrics.shallow_pixels > 100, "native lake has a visible shallow-water transition")
		check(metrics.edge_samples >= 45 and metrics.edge_span > 0.25, "shoreline departs from a straight rectangular edge")
		check(blue(native.get_pixelv(world_pixel(Vector2.ZERO))), "lake center remains deep blue water")
	var distant := await capture("lake", 0.45)
	if capture_label != "baseline":
		var metrics := shoreline_statistics(distant)
		print("SHORELINE_DISTANT_METRICS %s" % JSON.stringify(metrics))
		check(metrics.sand_pixels > 100 and metrics.water_pixels > 1000, "shrinking camera preserves a visible beach and water")
		region(Vector2(32, 22))
		var duplicate_native := await capture("duplicate", 1.0)
		var duplicate_distant := await capture("duplicate", 0.45)
		for images: Array in [[native, duplicate_native], [distant, duplicate_distant]]:
			var difference := difference_statistics(images[0], images[1])
			print("SHORELINE_DUPLICATE %s" % JSON.stringify(difference))
			check(difference.visible == 0, "duplicate water rectangles leave the complete water and blended beach image unchanged")
	clear_regions()
	region(Vector2(16, 22), Vector2(-8, 0))
	region(Vector2(16, 22), Vector2(8, 0))
	var joined_native := await capture("joined", 1.0)
	var joined_distant := await capture("joined", 0.45)
	if capture_label != "baseline":
		for images: Array in [[native, joined_native], [distant, joined_distant]]:
			var difference := difference_statistics(images[0], images[1])
			print("SHORELINE_JOIN %s" % JSON.stringify(difference))
			check(difference.visible == 0, "adjoining water rectangles preserve one continuous world image and have no internal beach")
		clear_regions()
		region(Vector2(24, 22), Vector2(-4, 0))
		region(Vector2(24, 22), Vector2(4, 0))
		var overlap_native := await capture("overlap", 1.0)
		var overlap_distant := await capture("overlap", 0.45)
		for images: Array in [[native, overlap_native], [distant, overlap_distant]]:
			var difference := difference_statistics(images[0], images[1])
			print("SHORELINE_OVERLAP %s" % JSON.stringify(difference))
			check(difference.visible == 0, "overlapping water rectangles preserve the complete merged beach and water image")
	clear_regions()
	region(Vector2(30, 18), Vector2(-8, 0))
	region(Vector2(18, 30), Vector2(8, 6))
	await capture("elbow", 1.0)
	await capture("elbow", 0.45)
	clear_regions()
	region(Vector2(64, 44), Vector2(-80, 90))
	await capture("world-lake", 1.0, Vector2(-55, 100))
	await capture("world-lake", 0.45, Vector2(-80, 90))
	if capture_label != "baseline":
		await _fog_clipping()
	viewport.free()
	print("SHORELINE GPU: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _fog_clipping() -> void:
	clear_regions()
	stage.scale = Vector2.ONE
	stage.position = Vector2(SIZE) * 0.5
	var lake := region(Vector2(16, 12))
	await frame()
	# Capture an original beach pixel at the right edge without depending on a
	# particular noise phase; require it to fall within the probe's vision.
	var original := viewport.get_texture().get_image()
	var sand_point := Vector2i(-1, -1)
	for y_index in 21:
		for x_index in 101:
			var logical := Vector2(2.5 + x_index * 0.06, -1.0 + y_index * 0.1)
			if logical.distance_to(Vector2(5, 0)) > 3.8: continue
			var point := world_pixel(logical)
			if pale_sand(original.get_pixelv(point)):
				sand_point = point
				break
		if sand_point.x >= 0: break
	check(sand_point.x >= 0, "fog fixture locates a real sand pixel at the water edge")
	if sand_point.x < 0: return
	var water_point := Vector2i(-1, -1)
	for y_index in 21:
		for x_index in 31:
			var logical := Vector2(1.8 + x_index * 0.06, -1.0 + y_index * 0.1)
			if logical.distance_to(Vector2(5, 0)) > 3.8: continue
			var point := world_pixel(logical)
			if blue(original.get_pixelv(point)):
				water_point = point
				break
		if water_point.x >= 0: break
	check(water_point.x >= 0, "fog fixture locates actual blue water within the beach probe's vision")
	if water_point.x < 0: return
	var probe := FogProbe.new()
	entities.add_child(probe)
	var state := MatchState.new()
	state.setup_defaults()
	FOG_HOLDER.install_rect(stage, state, Vector2(-32, -24), Vector2(32, 24), -1)
	var holder: Node = stage.get_meta("fog_holder")
	await frame()
	var all_view := viewport.get_texture().get_image()
	var near := water_point
	var far := world_pixel(Vector2(-2, 0))
	holder.set_view(0)
	await frame()
	var partial := viewport.get_texture().get_image()
	check(lake.visible, "visible coast keeps the large lake simulation visual active")
	check(partial.get_pixelv(sand_point).is_equal_approx(all_view.get_pixelv(sand_point)), "visible beach retains its original color")
	check(partial.get_pixelv(far).r < 0.001 and partial.get_pixelv(far).g < 0.001 and partial.get_pixelv(far).b < 0.001, "visible coast cannot reveal the lake's unexplored far end")
	partial.save_png("res://.godot/shoreline-current-fog-visible.png")
	probe.sim_pos = Vector2(26, 18)
	holder.rebuild_now()
	await frame()
	check(not lake.visible, "moving vision away switches the lake to memory")
	var memory := viewport.get_texture().get_image()
	for point: Vector2i in [sand_point, near]:
		var remembered := memory.get_pixelv(point)
		var expected := all_view.get_pixelv(point)
		print("SHORELINE_MEMORY point=%s original=%s remembered=%s" % [point, expected, remembered])
		check(absf(remembered.r - expected.r * 0.4) <= 2.0 / 255.0 and absf(remembered.g - expected.g * 0.4) <= 2.0 / 255.0 and absf(remembered.b - expected.b * 0.4) <= 2.0 / 255.0, "remembered beach/water receives exactly one 0.4 fog tint")
	check(memory.get_pixelv(far).r < 0.001 and memory.get_pixelv(far).g < 0.001 and memory.get_pixelv(far).b < 0.001, "lake memory keeps its unexplored far end black")
	memory.save_png("res://.godot/shoreline-current-fog-memory.png")
	holder.set_view(-1)
	await frame()
	check(difference_statistics(all_view, viewport.get_texture().get_image()).visible == 0, "all-view restores the original beach and water framebuffer")
	holder.set_view(1)
	await frame()
	var opponent := viewport.get_texture().get_image()
	check(opponent.get_pixelv(sand_point).r < 0.001 and opponent.get_pixelv(near).r < 0.001, "other team's unexplored view reveals no sand or water")
