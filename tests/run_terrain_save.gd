extends SceneTree

## Integration of remote saved games with local static terrain and polygon fog.
var Saves: GDScript
const CLIFF_SHADER := preload("res://shaders/terrain_cliff_fog.gdshader")
const SAVE_PATH := "user://saves/__terrain_merge_test.json"
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var render := "--render" in OS.get_cmdline_user_args()
	root.size = Vector2i(1280,720)
	Saves = load("res://scripts/core/save_game_service.gd")
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "sandbox"
	session.pending_save_data = {}
	var data := MapData.create(80,80,"Terrain save merge")
	for item in [["building","town_center",Vector2(-30,-30),"player","home"],
		["building","town_center",Vector2(30,30),"ai","enemy"],
		["unit","villager",Vector2(-32,-22),"player","worker"],
		["terrain","water",Vector2(-5,0),"player","lake"],
		["terrain","cliff",Vector2(12,0),"player","cliff"]]:
		var record := MapCatalog.make_record(item[0],item[1],item[2],item[3])
		record.id = item[4]
		if record.type == "terrain": record.block_size = [10.0,8.0] if record.terrain_id == "water" else [8.0,4.0]
		data.entities.append(record)
	check(MapData.validate(data).is_empty(), "terrain save fixture is a valid authored map")
	session.match_map_data = data
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	await process_frame
	await process_frame
	paused = true
	var bootstrap: Node = world.get_node("Bootstrap")
	var state: MatchState = bootstrap.match_state
	var entities := world.get_node("Entities") as Node2D
	var holder: Node = world.get_node("FogOfWar")
	var nodes := {}
	for entity in entities.get_children(): nodes[String(entity.get_meta("map_id",""))] = entity
	var worker := nodes.worker as UnitAgent
	worker.vision_radius_override = 12
	worker.sim_pos = Vector2(-5,-8)
	worker._sync_visual()
	holder.rebuild_now()
	worker.sim_pos = Vector2(12,-8)
	worker._sync_visual()
	holder.rebuild_now()
	check(state.fog.memories[0].has(nodes.lake.get_instance_id()) and state.fog.memories[0].has(nodes.cliff.get_instance_id()), "water and textured cliff create observed fog memories")
	worker.sim_pos = Vector2(-32,-22)
	worker.vision_radius_override = 4
	worker._sync_visual()
	holder.rebuild_now()
	check(not state.fog.can_see(0,nodes.lake) and not state.fog.can_see(0,nodes.cliff), "terrain memories are outside current vision")
	var before_image: Image
	if render:
		world.get_node("UILayer").set("visible",false)
		world.get_node("Camera2D").set_process(false)
		world.get_node("Camera2D").focus_on(Vector2.ZERO)
		before_image = await _frame_image()
	var first: Dictionary = JSON.parse_string(JSON.stringify(Saves.capture(bootstrap)))
	check(Saves.validate(first).is_empty(), "terrain and textured polygon memories survive JSON validation")
	check(first.entities.filter(func(record): return record.type == "terrain").size() == 2, "saved match includes both neutral terrain entities")
	check(Saves.restore(bootstrap,first).is_empty(), "terrain snapshot restores into an existing match")
	if render:
		var after_image: Image = await _frame_image()
		check(before_image.get_data() == after_image.get_data(), "native terrain memory framebuffer is identical after save/restore")
		after_image.save_png("res://.godot/pull-terrain-save-memory.png")
	nodes.clear()
	for entity in entities.get_children(): nodes[String(entity.get_meta("map_id",""))] = entity
	check(nodes.lake is PathBlocker and nodes.lake.block_size == Vector2(10,8), "restored lake retains its exact logical footprint")
	check(nodes.cliff is PathBlocker and nodes.cliff.kind == &"cliff" and nodes.cliff.get_child_count() >= 4, "restored cliff retains its three surfaces and navigation kind")
	var nav := world.get_node("NavService") as NavServiceHolder
	check(nav.nav.is_world_solid(Vector2(-5,0)) and nav.nav.is_world_solid(Vector2(12,0)), "restored terrain remains impassable")
	for history: Dictionary in state.fog.memories[0].values():
		if not history.get("terrain_region",false): continue
		check(history.kind in [&"water",&"cliff"], "memory retains its minimap terrain classification")
		for part: Dictionary in history.parts:
			check(part.has("polygon") and part.get("texture") != null and part.uv.size() == part.polygon.size(), "memory retains polygon texture and complete UV coordinates")
			check(part.get("texture_repeat") == CanvasItem.TEXTURE_REPEAT_ENABLED, "memory retains repeating terrain texture settings")
	# A hidden removed cliff must keep its last observed value snapshot, while
	# no live blocker remains after restoring the save.
	nodes.cliff.free()
	holder.rebuild_now()
	var snapshot: Dictionary = JSON.parse_string(JSON.stringify(Saves.capture(bootstrap)))
	check(snapshot.entities.filter(func(record): return record.type == "terrain").size() == 1, "removed cliff is excluded from live saved entities")
	var orphan: Array = snapshot.fog.memories[0].filter(func(record): return record.get("terrain_region",false) and record.kind == "cliff" and record.entity == 0)
	check(orphan.size() == 1, "hidden removed cliff is serialized as an orphan terrain memory")
	check(Saves.save(bootstrap,SAVE_PATH).is_empty() and Saves.read(SAVE_PATH).error.is_empty(), "terrain match writes and reads a real save file")
	check(Saves.restore(bootstrap,snapshot).is_empty(), "orphan cliff history restores without a simulation entity")
	check(not nav.nav.is_world_solid(Vector2(12,0)), "orphan cliff visual memory does not create an invisible blocker")
	var memory_proxy: Node2D
	for proxy: Node2D in holder._memory_views.values():
		for child in proxy.get_children():
			if child.material is ShaderMaterial and child.material.shader == CLIFF_SHADER: memory_proxy = proxy
	check(memory_proxy != null, "restored orphan cliff creates a polygon memory proxy")
	if memory_proxy != null:
		for child in memory_proxy.get_children():
			if child.material is not ShaderMaterial: continue
			check(child.material.get_shader_parameter("fog_enabled") == true and child.material.get_shader_parameter("is_memory") == true, "restored cliff shader is bound to current fog as memory")
			check(child.material.get_shader_parameter("fog_mask") == holder._texture, "restored cliff uses the current match mask rather than serialized shader uniforms")
	var map := world.get_node("UILayer/HUD/Minimap") as Minimap
	map._process(0.1)
	check(map._terrain_shapes.size() == 2, "restored lake and orphan cliff remain in masked minimap terrain")
	check(map._markers.filter(func(marker): return marker.get("kind") in [&"water",&"cliff"]).is_empty(), "restored terrain has no unmasked minimap marker")
	var terrain_index := -1
	for i in snapshot.entities.size():
		if snapshot.entities[i].type == "terrain": terrain_index = i
	for size in [[0,8],[129,8],[INF,8],[true,8]]:
		var corrupt := snapshot.duplicate(true)
		corrupt.entities[terrain_index].block_size = size
		var before := entities.get_child_count()
		check(not Saves.restore(bootstrap,corrupt).is_empty() and entities.get_child_count() == before, "corrupt terrain dimensions reject before mutating match: %s" % str(size))
	var corrupt := snapshot.duplicate(true)
	var history_index: int = snapshot.fog.memories[0].find(orphan[0])
	corrupt.fog.memories[0][history_index].parts[0].uv = [[NAN,0]]
	check(not Saves.validate(corrupt).is_empty(), "corrupt polygon UVs reject before rendering")
	corrupt = snapshot.duplicate(true)
	corrupt.fog.memories[0][history_index].terrain_region = "true"
	check(not Saves.validate(corrupt).is_empty(), "corrupt terrain memory flags reject")
	corrupt = snapshot.duplicate(true)
	corrupt.fog.memories[0][history_index].kind = []
	check(not Saves.validate(corrupt).is_empty(), "corrupt memory kind cannot reach StringName construction")
	# New retry state is optional, so pre-merge saves still validate.
	for record in snapshot.entities:
		if record.type == "building": record.fields.erase("_spawn_retry_remaining")
	check(Saves.validate(snapshot).is_empty() and Saves.restore(bootstrap,snapshot).is_empty(), "older saves without spawn retry state remain compatible")
	world.free()
	paused = false
	DirAccess.remove_absolute(SAVE_PATH)
	print("Terrain save integration: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func _frame_image() -> Image:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	return root.get_texture().get_image()
