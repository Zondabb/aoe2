extends SceneTree

## Native framebuffer checks: rectangular map transform and partial lake fog.
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func close_color(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) < 0.02 and absf(actual.g - expected.g) < 0.02 and absf(actual.b - expected.b) < 0.02

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "terrain minimap render checks require a graphical backend")
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	var viewport := SubViewport.new()
	viewport.size = Vector2i(760,240)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node2D.new()
	viewport.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	entities.visible = false
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(Vector2(-20,-10), Vector2(20,10))
	state.fog.ready = true
	MapLoader.spawn_entity({"id":"lake", "type":"terrain", "terrain_id":"water", "pos":[0,0], "block_size":[20,8]}, entities, state)
	var explored: PackedByteArray = state.fog.explored[0]
	var current: PackedByteArray = state.fog.visible_now[0]
	for y in range(6,14):
		for x in range(10,24):
			explored[y*40+x] = 1
			if x < 20: current[y*40+x] = 1
	state.fog.explored[0] = explored
	state.fog.visible_now[0] = current
	var map := Minimap.new()
	map.position = Vector2(10,35)
	map.size = Vector2(360,180)
	map.match_state = state
	map._fog = state.fog
	map._entities = entities
	map.map_min = Vector2(-20,-10)
	map.map_max = Vector2(20,10)
	world.add_child(map)
	map.set_process(false)
	map.refresh_markers()
	map._sync_terrain()
	map.queue_redraw()
	var preview := load("res://scripts/ui/map_preview.gd").new() as Control
	preview.position = Vector2(390,20)
	preview.size = Vector2(350,200)
	world.add_child(preview)
	var data := MapData.create(40,20)
	data.entities = [
		{"id":"lake", "type":"terrain", "terrain_id":"water", "pos":[-8,0], "block_size":[12,8]},
		{"id":"cliff", "type":"terrain", "terrain_id":"cliff", "pos":[8,3], "block_size":[6,4]},
	]
	preview.show_map(data)
	await frame()
	var pixels := viewport.get_texture().get_image()
	var seen: Vector2i = Vector2i(map.position + map.world_to_map(Vector2(-5,0)))
	var known: Vector2i = Vector2i(map.position + map.world_to_map(Vector2(2,0)))
	var unknown: Vector2i = Vector2i(map.position + map.world_to_map(Vector2(7,0)))
	check(close_color(pixels.get_pixelv(seen), Color(0.18,0.4,0.6)), "framebuffer displays the visible edge of the lake in blue")
	check(close_color(pixels.get_pixelv(known), Color(0.18,0.4,0.6).darkened(0.58)), "framebuffer dims the explored part of the same lake")
	check(pixels.get_pixelv(unknown) == Color.BLACK, "large lake footprint never overdraws unknown black terrain")
	check(map._markers.is_empty(), "terrain creates no unmasked marker mesh")
	var lake_center: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2(-8,0), MapData.bounds(data)))
	var cliff_center: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2(8,3), MapData.bounds(data)))
	check(close_color(pixels.get_pixelv(lake_center), Color("2e6699")), "menu preview paints a blue lake rather than a red enemy dot")
	check(close_color(pixels.get_pixelv(cliff_center), Color("8c8773")), "menu preview paints a grey cliff footprint")
	var lake_edge: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2(-10,0), MapData.bounds(data)))
	check(close_color(pixels.get_pixelv(lake_edge), Color("2e6699")), "menu preview paints the actual terrain area beyond its center")
	var dry_corner: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2(-13,3), MapData.bounds(data)))
	check(close_color(pixels.get_pixelv(dry_corner), Color("586240")), "menu preview shows grass in the authored corner outside the actual water")
	pixels.save_png("res://.godot/terrain-minimap-preview.png")
	state.fog_enabled = false
	map._fog = null
	map.refresh_markers()
	map._terrain_key.clear()
	map._sync_terrain()
	map.queue_redraw()
	await frame()
	pixels = viewport.get_texture().get_image()
	check(close_color(pixels.get_pixelv(unknown), Color(0.18,0.4,0.6)), "non-fog view draws the full irregular lake using both image dimensions")
	var outside: Vector2i = Vector2i(map.position + map.world_to_map(Vector2(0,7)))
	check(close_color(pixels.get_pixelv(outside), Minimap.GRASS), "rectangular minimap terrain does not stretch water beyond its shore")
	var ring := MapData.create(40,40)
	ring.entities = []
	for rect: Rect2 in [Rect2(-16,-16,32,8), Rect2(-16,8,32,8), Rect2(-16,-8,8,16), Rect2(8,-8,8,16)]:
		ring.entities.append({"type":"terrain", "terrain_id":"water", "pos":[rect.get_center().x,rect.get_center().y], "block_size":[rect.size.x,rect.size.y]})
	preview.show_map(ring)
	await frame()
	pixels = viewport.get_texture().get_image()
	var island: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2.ZERO, MapData.bounds(ring)))
	var ring_water: Vector2i = Vector2i(preview.position + preview._preview_point(Vector2(12,0), MapData.bounds(ring)))
	check(close_color(pixels.get_pixelv(island), Color("586240")), "menu preview preserves the dry island inside a water ring")
	check(close_color(pixels.get_pixelv(ring_water), Color("2e6699")), "menu preview still draws the surrounding water barrier")
	viewport.free()
	print("Terrain minimap rendering: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
