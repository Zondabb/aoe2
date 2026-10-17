extends SceneTree

## Run with the real GL backend, without --headless. Exercise the same ghost
## object that becomes a construction site, and compare actual framebuffers.
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const SPRITES := preload("res://scripts/presentation/sprite_catalog.gd")
const OCCLUSION := preload("res://scripts/presentation/unit_occlusion.gd")
const FOG_HOLDER := preload("res://scripts/systems/fog_of_war_holder.gd")
const MEMORY := preload("res://scripts/presentation/fog_memory.gd")
const BG := Color("526543")
const IDS: Array[StringName] = [&"town_center", &"house", &"castle", &"farm", &"gate"]
var viewport: SubViewport
var entities: Node2D
var renderer: Node
var actors: Array[BuildingAgent] = []
var workers: Array[UnitAgent] = []
var boxes: Array[Rect2i] = []
var checks := 0
var failures: Array[String] = []

class Observer extends Node2D:
	var hp := 100.0
	var team := 0
	var sim_pos := Vector2.ZERO
	func resolved_vision_radius() -> float: return 12.0

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

func label_at(value: String, at: Vector2) -> void:
	var label := Label.new()
	label.text = value
	label.position = at
	viewport.add_child(label)

func changed_pixels(before: Image, after: Image, box: Rect2i) -> int:
	var changed := 0
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if not before.get_pixel(x, y).is_equal_approx(after.get_pixel(x, y)):
				changed += 1
	return changed

func ink_pixels(image: Image, box: Rect2i) -> int:
	var count := 0
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if not image.get_pixel(x, y).is_equal_approx(BG): count += 1
	return count

func check_native_alignment(actor: BuildingAgent, base: String, label: String) -> void:
	var sprite := actor.get_node("Billboard") as Sprite2D
	var meta := SPRITES.load_meta(base)
	var expected := SPRITES.first_atlas_texture(meta, SPRITES.load_texture(base))
	check(sprite.visible and sprite.texture != null, label + ": native sprite is visible")
	check(sprite.texture.get_image().get_data() == expected.get_image().get_data(), label + ": original sprite pixels are unchanged")
	check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.ORIGINAL_ART_PIXEL_SCALE_2D), label + ": original pixel scale is retained")
	var offset := SPRITES.offset_for_hotspot_2d(meta, SPRITES.average_hotspot(meta))
	check(sprite.offset.is_equal_approx(offset), label + ": original hotspot anchors the footprint")

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "native rendering runner requires a graphical backend")
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(2250, 1140)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.size = viewport.size
	ground.color = BG
	ground.z_index = -100
	viewport.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.team_ages[0] = Enums.Age.CASTLE
	state.team_ages[1] = Enums.Age.CASTLE
	# Create the renderer before the previews. Confirmation must register a
	# previously ignored ghost even after its node_added event has been drained.
	for row in 2:
		var worker := UNIT.instantiate() as UnitAgent
		worker.def = GameCatalog.get_unit(&"villager")
		worker.team = row
		worker.match_state = state
		worker.civ = load("res://data/civs/%s.tres" % ["chinese", "teutons"][row])
		entities.add_child(worker)
		worker.set_physics_process(false)
		worker.position = Vector2(225, 405 + row * 530)
		workers.append(worker)
	await frame()
	renderer = viewport.get_meta(OCCLUSION.KEY)
	for row in 2:
		var civ_id: String = ["chinese", "teutons"][row]
		for col in IDS.size():
			var actor := BUILDING.instantiate() as BuildingAgent
			actor.def = GameCatalog.get_building(IDS[col])
			actor.civ = load("res://data/civs/%s.tres" % civ_id)
			actor.team = row
			actor.match_state = state
			actor.is_placement_ghost = true
			actor.start_construction()
			entities.add_child(actor)
			actor.position = Vector2(225 + col * 450, 420 + row * 530)
			actor.set_ghost_visual(true)
			actors.append(actor)
			boxes.append(Rect2i(450 * col + 5, 40 + row * 530, 440, 490))
			label_at("%s / %s" % [civ_id, IDS[col]], Vector2(450 * col + 40, 15 + row * 530))
	await frame()
	var preview := viewport.get_texture().get_image()
	preview.save_png("res://.godot/building-foundations-preview.png")
	for actor in actors:
		var preview_base := SPRITES.foundation_sheet_base(actor.def.id, actor.civ.id, 2) if actor.def.id == &"farm" else SPRITES.building_sheet_base(actor.def.id, actor.civ.id, 2)
		check_native_alignment(actor, preview_base, "preview %s/%s" % [actor.civ.id, actor.def.id])
		check(not renderer.get("_static_actors").has(actor.get_instance_id()), "preview is excluded from the static occlusion registry")
		actor.clear_ghost_visual()
	await frame()
	var foundation := viewport.get_texture().get_image()
	foundation.save_png("res://.godot/building-foundations-000.png")
	for index in actors.size():
		var actor := actors[index]
		var base := SPRITES.foundation_sheet_base(actor.def.id, actor.civ.id, 2, actor.def.footprint)
		check_native_alignment(actor, base, "foundation %s/%s" % [actor.civ.id, actor.def.id])
		check((actor.get_node("Billboard") as Sprite2D).z_index < 0, "foundation remains below walking units")
		var shadow := actor.get_node_or_null("GroundShadow") as CanvasItem
		check(shadow == null or not shadow.visible, "foundation has no completed-building ground shadow")
		check(renderer.get("_static_actors").has(actor.get_instance_id()), "confirmed preview enters the renderer registry")
		check(ink_pixels(foundation, boxes[index]) > 100, "foundation is present in the actual framebuffer")
		check(changed_pixels(preview, foundation, boxes[index]) > 100, "confirmation removes placement tint and displays the foundation in the framebuffer")
		actor.add_build_progress(actor.def.build_time * 0.5)
	await frame()
	var half := viewport.get_texture().get_image()
	half.save_png("res://.godot/building-foundations-050.png")
	for index in actors.size():
		check(changed_pixels(foundation, half, boxes[index]) == 0, "50% construction preserves exactly the foundation framebuffer")
		actors[index].add_build_progress(actors[index].def.build_time * 0.49)
	await frame()
	var nearly := viewport.get_texture().get_image()
	nearly.save_png("res://.godot/building-foundations-099.png")
	for index in actors.size():
		check(changed_pixels(foundation, nearly, boxes[index]) == 0, "99% construction never displays the completed roof")
		actors[index].add_build_progress(actors[index].def.build_time)
	await frame()
	var complete := viewport.get_texture().get_image()
	complete.save_png("res://.godot/building-foundations-100.png")
	for index in actors.size():
		var actor := actors[index]
		check(actor.is_complete, "100% construction reaches the completed state")
		var complete_base := SPRITES.foundation_sheet_base(actor.def.id, actor.civ.id, 2) if actor.def.id == &"farm" else SPRITES.building_sheet_base(actor.def.id, actor.civ.id, 2)
		check_native_alignment(actor, complete_base, "completed %s/%s" % [actor.civ.id, actor.def.id])
		if actor.def.id == &"farm":
			# A neighboring completed castle can extend into this preview cell.
			# The isolated farm runner compares the unchanged soil framebuffer.
			check(not actor.farm_has_crops and actor._uses_foundation_visual(), "farm completion retains bare soil until first harvest")
		else:
			check(changed_pixels(nearly, complete, boxes[index]) > 100, "completion reveals the full building in the framebuffer")
		if actor.def.id == &"town_center":
			var shadow := actor.get_node_or_null("GroundShadow") as Sprite2D
			check(shadow != null and shadow.visible, "completed town center restores its separate original ground shadow")
			check((actor.get_node("Billboard") as Sprite2D).z_index == actor.TOWN_CENTER_SOLID_Z, "completed town center roof restores its covering layer")
	# Original foundation is below a worker, while the completed TC roof covers
	# the same worker and the shared outline renderer reveals the occluded edge.
	renderer.enabled = false
	await frame()
	var without_outline := viewport.get_texture().get_image()
	renderer.enabled = true
	await frame()
	var with_outline := viewport.get_texture().get_image()
	for row in 2:
		check(changed_pixels(without_outline, with_outline, boxes[row * 5]) > 5, "completed town center correctly outlines its covered worker")
	viewport.free()
	await process_frame
	await test_fog_memory()
	print("BUILDING FOUNDATION GPU: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func remembered_texture(snapshot: Dictionary) -> Texture2D:
	for part in snapshot.parts:
		if part.has("texture") and int(part.z) == -1:
			return part.texture
	return null

func test_fog_memory() -> void:
	var fog_view := SubViewport.new()
	fog_view.size = Vector2i(600, 400)
	fog_view.disable_3d = true
	root.add_child(fog_view)
	var world := Node2D.new()
	fog_view.add_child(world)
	var fog_entities := Node2D.new()
	fog_entities.name = "Entities"
	world.add_child(fog_entities)
	var state := MatchState.new()
	state.setup_defaults()
	var observer := Observer.new()
	fog_entities.add_child(observer)
	var enemy := BUILDING.instantiate() as BuildingAgent
	enemy.def = GameCatalog.get_building(&"town_center")
	enemy.civ = load("res://data/civs/chinese.tres")
	enemy.team = Enums.Team.AI
	enemy.sim_pos = Vector2(4, 0)
	enemy.match_state = state
	enemy.start_construction()
	fog_entities.add_child(enemy)
	FOG_HOLDER.install(world, state, -64, 64)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	var key := enemy.get_instance_id()
	var snapshot: Dictionary = holder.fog.memories[0][key]
	var texture := remembered_texture(snapshot)
	check(texture == (enemy.get_node("Billboard") as Sprite2D).texture, "visible unfinished enemy memory captures the actual foundation texture")
	check(snapshot.parts.size() == 1, "foundation fog snapshot contains no completed shadow or roof")
	observer.sim_pos = Vector2(-40, -40)
	holder.rebuild_now()
	var proxy: Node2D = holder.get("_memory_views")[key]
	var appearance: int = snapshot.appearance
	check(not enemy.visible and proxy.visible, "losing vision displays the observed foundation memory")
	enemy.add_build_progress(enemy.def.build_time)
	holder.rebuild_now()
	snapshot = holder.fog.memories[0][key]
	check(snapshot.appearance == appearance and remembered_texture(snapshot) == texture, "hidden completion retains the last observed foundation")
	check(proxy.get_child_count() == 1 and (proxy.get_child(0) as Sprite2D).texture == texture, "fog proxy does not leak a completed building or shadow")
	observer.sim_pos = Vector2.ZERO
	holder.rebuild_now()
	snapshot = holder.fog.memories[0][key]
	check(enemy.visible and not proxy.visible and snapshot.appearance != appearance, "reobservation refreshes the completed building and retires its visible memory")
	check(snapshot.parts.size() == 2, "reobserved town center remembers its complete roof and ground shadow")
	fog_view.free()
	await process_frame
