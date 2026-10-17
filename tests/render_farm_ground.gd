extends SceneTree

## Real framebuffer regression: farm soil must never cover workers or shadows,
## even when its Y-sorted entity origin is in front of the worker's feet.
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const FARM := preload("res://scripts/entities/farm_agent.gd")
const SPRITES := preload("res://scripts/presentation/sprite_catalog.gd")
const MEMORY := preload("res://scripts/presentation/fog_memory.gd")
const OCCLUSION := preload("res://scripts/presentation/unit_occlusion.gd")
const TERRAIN := preload("res://scripts/presentation/terrain_visual.gd")
const POSES: Array[Vector2] = [Vector2(-3, -3), Vector2.ZERO, Vector2(3, 3), Vector2(-3, 3), Vector2(3, -3)]
var viewport: SubViewport
var entities: Node2D
var ground: Node2D
var farm: BuildingAgent
var worker: UnitAgent
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func capture() -> Image:
	await frame()
	return viewport.get_texture().get_image()

func changed_pixels(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			if not a.get_pixel(x, y).is_equal_approx(b.get_pixel(x, y)): count += 1
	return count

func check_worker(reference: Image, actual: Image, label: String) -> void:
	var opaque := 0
	var covered := 0
	for y in reference.get_height():
		for x in reference.get_width():
			var pixel := reference.get_pixel(x, y)
			if pixel.a < 0.999: continue
			opaque += 1
			var rendered := actual.get_pixel(x, y)
			if maxf(absf(pixel.r - rendered.r), maxf(absf(pixel.g - rendered.g), absf(pixel.b - rendered.b))) > 2.01 / 255.0:
				covered += 1
	var minimum := maxi(10, int(100.0 * pow(viewport.canvas_transform.get_scale().x, 2.0)))
	check(opaque > minimum, label + ": reference contains a real villager silhouette")
	check(covered == 0, "%s: soil covers no opaque villager pixels (%d covered)" % [label, covered])

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Farm rendering checks require a graphical backend")
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(400, 300)
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	ground = Node2D.new()
	ground.position = Vector2(200, 190)
	viewport.add_child(ground)
	TERRAIN.setup_grass(ground, Rect2(-20, -20, 40, 40))
	entities = Node2D.new()
	entities.position = ground.position
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	farm = BUILDING.instantiate() as BuildingAgent
	farm.set_script(FARM)
	farm.def = GameCatalog.get_building(&"farm")
	farm.match_state = state
	entities.add_child(farm)
	worker = UNIT.instantiate() as UnitAgent
	worker.def = GameCatalog.get_unit(&"villager")
	worker.match_state = state
	entities.add_child(worker)
	worker.set_physics_process(false)
	var body := worker.get_node("Billboard") as AnimatedSprite2D
	body.stop()
	var shadow := worker.get_node("GroundShadow") as CanvasItem
	await frame()
	var renderer: Node = viewport.get_meta(OCCLUSION.KEY)
	renderer.enabled = false
	for civ_id in [&"chinese", &"teutons"]:
		farm.civ = load("res://data/civs/%s.tres" % civ_id)
		worker.civ = farm.civ
		var bare_reference: Image
		for phase in ["preview", "foundation", "50%", "99%", "complete", "harvesting"]:
			farm.is_placement_ghost = phase == "preview"
			farm.start_construction()
			if phase == "preview": farm.set_ghost_visual(true)
			else: farm.clear_ghost_visual()
			if phase == "50%": farm.add_build_progress(farm.def.build_time * 0.5)
			if phase == "99%": farm.add_build_progress(farm.def.build_time * 0.99)
			if phase in ["complete", "harvesting"]: farm.add_build_progress(farm.def.build_time)
			if phase == "harvesting": farm.call("extract", 0.1)
			var soil := farm.get_node("Billboard") as Sprite2D
			var bounds := soil.transform * soil.get_rect()
			check(bounds.is_equal_approx(Rect2(-172.8, -86.4, 345.6, 172.8)), "%s/%s: farm retains native 3x3 artwork scale" % [civ_id, phase])
			var expected_base := SPRITES.building_sheet_base(&"farm", civ_id, 0) if phase == "harvesting" else SPRITES.foundation_sheet_base(&"farm", civ_id, 0)
			check(farm._sprite_sheet_base == expected_base, "%s/%s: crops only appear during harvesting" % [civ_id, phase])
			check(soil.z_index < shadow.z_index, "soil is beneath villagers' foot shadows")
			check(not (farm.get_node("GroundShadow") as CanvasItem).visible, "flat farmland has no floating building shadow")
			farm.set_selected(true)
			var selection := farm.get_node("SelectionRing") as Line2D
			check(selection.points[0].is_equal_approx(Vector2(0, -86.4)) and selection.points[2].is_equal_approx(Vector2(0, 86.4)), "farm selection follows the original-size soil boundary")
			farm.set_selected(false)
			for pose in POSES:
				worker.position = IsoMath.world_to_screen(pose)
				farm.hide()
				ground.hide()
				shadow.hide()
				var reference := await capture()
				farm.show()
				ground.show()
				var actual := await capture()
				if pose == Vector2.ZERO:
					if phase == "foundation": bare_reference = actual
					if phase == "complete": check(changed_pixels(bare_reference, actual) == 0, "unworked completion preserves exactly the bare-soil framebuffer")
					if phase == "harvesting": check(changed_pixels(bare_reference, actual) > 100, "first gathering visibly plants the field in the framebuffer")
				check_worker(reference, actual, "%s/%s/%s" % [civ_id, phase, pose])
				shadow.show()
				var with_shadow := await capture()
				check(changed_pixels(actual, with_shadow) > 5, "worker's ground shadow remains visible on the field")
				if phase in ["complete", "harvesting"] and pose == Vector2(-3, -3):
					with_shadow.save_png("res://.godot/farm-%s.png" % phase)
				if phase == "harvesting" and pose == Vector2(-3, -3):
					with_shadow.save_png("res://.godot/farm-ground-after.png")
					renderer.enabled = true
					check(changed_pixels(with_shadow, await capture()) == 0, "flat farm never creates a false occlusion outline")
					renderer.enabled = false
		# The same layer and ground size survive fog snapshots and age refreshes.
		var snapshot := {"position":farm.position, "parts":MEMORY.capture(farm)}
		var memory := MEMORY.make_view(snapshot)
		entities.add_child(memory)
		farm.hide()
		shadow.hide()
		ground.hide()
		memory.hide()
		var reference := await capture()
		ground.show()
		memory.show()
		check_worker(reference, await capture(), "remembered farm")
		check(memory.get_child_count() == 1 and (memory.get_child(0) as CanvasItem).z_index < shadow.z_index, "fog memory retains only the flat soil layer")
		memory.free()
		farm.show()
		for age in 4:
			state.set_age(0, age)
			check((farm.get_node("Billboard") as Sprite2D).z_index == farm.FARM_GROUND_Z, "age refresh preserves ground layering")
	# Crouched work frames and zoomed views use the same ground ordering.
	worker.position = IsoMath.world_to_screen(Vector2(-1, -1))
	for action in [&"walk_dir_0", &"gather_food_dir_0", &"build_dir_0"]:
		body.animation = action
		body.frame = 0
		worker._apply_billboard_hotspot(body, action, 0)
		for zoom in [0.45, 1.5]:
			viewport.canvas_transform = Transform2D(0, Vector2(200, 150) * (1.0 - zoom)).scaled_local(Vector2.ONE * zoom)
			farm.hide()
			ground.hide()
			shadow.hide()
			var reference := await capture()
			farm.show()
			ground.show()
			var actual := await capture()
			check_worker(reference, actual, "%s at zoom %s" % [action, zoom])
			renderer.enabled = true
			check(changed_pixels(actual, await capture()) == 0, "work animations and zoom never trigger farm occlusion")
			renderer.enabled = false
	viewport.canvas_transform = Transform2D.IDENTITY
	# Compare two original-size fields with their display edges touching.
	var neighbor := BUILDING.instantiate() as BuildingAgent
	neighbor.def = farm.def
	neighbor.match_state = state
	neighbor.sim_pos = Vector2(172.8 / IsoMath.SCALE_X, 0)
	entities.add_child(neighbor)
	var first := farm.get_node("Billboard") as Sprite2D
	var second := neighbor.get_node("Billboard") as Sprite2D
	check((first.to_global(Vector2(144, 0))).is_equal_approx(second.to_global(Vector2(0, -72))), "original-size farm soil shares an exact display edge")
	worker.position = Vector2.ZERO
	shadow.show()
	await frame()
	viewport.get_texture().get_image().save_png("res://.godot/farm-ground-adjacent.png")
	viewport.free()
	print("FARM GROUND GPU: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
