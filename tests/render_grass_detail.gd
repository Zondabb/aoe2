extends SceneTree

## Actual framebuffer regression: run with gl_compatibility, without --headless.
## -- --label baseline --baseline reproduces the previous grass UV/filter setup
## locally, so before/after captures keep the same camera and reference actors.
const LOADER := preload("res://scripts/world/map_loader.gd")
const DATA := preload("res://scripts/world/map_data.gd")
const ISO := preload("res://scripts/presentation/iso_math.gd")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const ZOOMS := [1.0, 0.45, 0.2]
const SIZE := Vector2i(1024, 720)
const BG := Color("26301f")
var checks := 0
var failures: Array[String] = []
var capture_label := "current"
var baseline := false
var viewport: SubViewport
var stage: Node2D
var ground: Node2D
var entities: Node2D

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for index in args.size():
		if args[index] == "--label" and index + 1 < args.size():
			capture_label = args[index + 1].validate_filename()
		if args[index] == "--baseline": baseline = true
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

func data_rect(minimum: Vector2i, maximum: Vector2i) -> Dictionary:
	var data := DATA.create()
	data.bounds = {"min": [minimum.x, minimum.y], "max": [maximum.x, maximum.y]}
	return data

func surface(data: Dictionary, parent: Node2D) -> Polygon2D:
	LOADER.setup_ground(data, parent)
	check(parent.get_child_count() == 1, "grass remains one surface per map rectangle")
	var polygon := parent.get_child(0) as Polygon2D
	if baseline:
		# Previous MapLoader used projected screen coordinates as its implicit
		# UVs, 0.35 texture scale and the project's nearest texture filtering.
		polygon.uv = PackedVector2Array()
		polygon.texture_scale = Vector2.ONE * 0.35
		polygon.texture_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
	return polygon

func difference_statistics(before: Image, after: Image, box: Rect2i) -> Dictionary:
	var exact := 0
	var visible := 0
	var maximum := 0.0
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			var difference := maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))
			maximum = maxf(maximum, difference)
			if difference > 0.0001: exact += 1
			# Large world polygons may triangulate into different floating point
			# interpolation paths. Ignore at most two 8-bit rounding steps.
			if difference > 2.01 / 255.0: visible += 1
	return {"exact":exact, "visible":visible, "maximum_channel_difference":maximum}

func luma(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722

func statistics(image: Image, box: Rect2i) -> Dictionary:
	var difference := 0.0
	var equal_neighbors := 0
	var samples := 0
	var sums := 0.0
	var squares := 0.0
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x - 1):
			var value := image.get_pixel(x, y)
			var next := image.get_pixel(x + 1, y)
			var value_luma := luma(value)
			difference += absf(value_luma - luma(next))
			sums += value_luma
			squares += value_luma * value_luma
			if value.is_equal_approx(next): equal_neighbors += 1
			samples += 1
	var mean := sums / float(samples)
	return {"luma_mean":mean, "luma_deviation":sqrt(maxf(0.0, squares / float(samples) - mean * mean)), "neighbor_difference":difference / float(samples), "flat_neighbor_ratio":float(equal_neighbors) / float(samples)}

func reference_objects() -> void:
	var state := MatchState.new()
	state.setup_defaults()
	var town := BUILDING.instantiate() as BuildingAgent
	town.def = GameCatalog.get_building(&"town_center")
	town.civ = load("res://data/civs/chinese.tres")
	town.match_state = state
	town.sim_pos = Vector2.ZERO
	entities.add_child(town)
	town.set_physics_process(false)
	var house := BUILDING.instantiate() as BuildingAgent
	house.def = GameCatalog.get_building(&"house")
	house.civ = town.civ
	house.match_state = state
	house.sim_pos = Vector2(-12, 4)
	entities.add_child(house)
	house.set_physics_process(false)
	var villager := UNIT.instantiate() as UnitAgent
	villager.def = GameCatalog.get_unit(&"villager")
	villager.civ = town.civ
	villager.match_state = state
	villager.sim_pos = Vector2(10, 4)
	entities.add_child(villager)
	villager.set_physics_process(false)

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "grass detail requires an actual graphics backend")
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = SIZE
	viewport.disable_3d = true
	# SubViewport defaults to linear even when the game's root viewport uses
	# the project's nearest setting. Match actual gameplay in this fixture.
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	print("GRASS_FILTER project=%s fixture=%s root=%s" % [ProjectSettings.get_setting("rendering/textures/canvas_textures/default_texture_filter"), viewport.canvas_item_default_texture_filter, root.canvas_item_default_texture_filter])
	var backdrop := ColorRect.new()
	backdrop.color = BG
	backdrop.size = SIZE
	backdrop.z_index = -101
	viewport.add_child(backdrop)
	stage = Node2D.new()
	stage.position = Vector2(SIZE) * 0.5
	viewport.add_child(stage)
	ground = Node2D.new()
	stage.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	stage.add_child(entities)
	var title := Label.new()
	title.position = Vector2(16, 12)
	viewport.add_child(title)
	var data := data_rect(Vector2i(-256, -256), Vector2i(256, 256))
	var polygon := surface(data, ground)
	check(polygon != null and polygon.texture != null, "map loader supplies textured grass")
	check(polygon.polygon[0] == ISO.world_to_screen(Vector2(-256, -256)), "grass keeps the original simulation bounds")
	check(polygon.texture_repeat == CanvasItem.TEXTURE_REPEAT_ENABLED, "grass repeats across the world without stretching")
	check(polygon.z_index == -100, "grass stays below gameplay actors")
	if not baseline:
		check(polygon.texture.get_image().has_mipmaps(), "grass has mipmaps for shrinking the camera")
		check(polygon.texture_filter in [CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS, CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC], "grass filters distant texture samples without nearest blocks")
		check(polygon.texture_scale.is_equal_approx(Vector2.ONE), "grass UVs retain their original source pixel density")
		check(polygon.uv.size() == 4, "grass explicitly anchors all four UVs in the simulation world")
	reference_objects()
	var sample_box := Rect2i(80, 520, 864, 160)
	var native_difference := 0.0
	for zoom: float in ZOOMS:
		stage.scale = Vector2.ONE * zoom
		title.text = "Grass / %s / camera zoom %.2f / native town center + house + villager" % [capture_label, zoom]
		entities.visible = false
		await frame()
		var single := viewport.get_texture().get_image()
		var metrics := statistics(single, sample_box)
		check(metrics.luma_deviation > 0.002, "zoom %.2f keeps visible grass texture detail" % zoom)
		check(single.get_pixel(512, 360).g > single.get_pixel(512, 360).r, "zoom %.2f renders actual green grass" % zoom)
		if zoom == 1.0:
			native_difference = metrics.neighbor_difference
		elif not baseline:
			check(metrics.neighbor_difference < native_difference, "zoom %.2f reduces high frequency aliasing as the camera shrinks" % zoom)
		print("GRASS_METRICS %s zoom=%.2f %s" % [capture_label, zoom, JSON.stringify(metrics)])
		# Split the same world rectangle at x=0. The projected join is diagonal.
		ground.visible = false
		var split := Node2D.new()
		stage.add_child(split)
		for limits: Array in [[Vector2i(-256, -256), Vector2i(0, 256)], [Vector2i(0, -256), Vector2i(256, 256)]]:
			var part := Node2D.new()
			split.add_child(part)
			surface(data_rect(limits[0], limits[1]), part)
		await frame()
		var adjoining := viewport.get_texture().get_image()
		var difference := difference_statistics(single, adjoining, Rect2i(0, 50, SIZE.x, SIZE.y - 50))
		print("GRASS_JOIN %s zoom=%.2f %s" % [capture_label, zoom, JSON.stringify(difference)])
		check(difference.visible == 0 and difference.maximum_channel_difference <= 2.01 / 255.0, "zoom %.2f adjoining grass rectangles preserve one seamless world image (%d visibly changed pixels)" % [zoom, difference.visible])
		split.free()
		ground.visible = true
		entities.visible = true
		await frame()
		var image := viewport.get_texture().get_image()
		var output := "res://.godot/grass-detail-%s-zoom-%03d.png" % [capture_label, roundi(zoom * 100.0)]
		check(image.save_png(output) == OK, "zoom %.2f framebuffer is saved" % zoom)
		print("GRASS_CAPTURE %s" % output)
	viewport.free()
	print("GRASS DETAIL GPU: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
