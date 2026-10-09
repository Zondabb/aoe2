extends SceneTree

## Original SLP pixels must retain their relative sizes across actors and actions.
## Add -- --render on a desktop backend to save the calibrated game-sprite preview.
const SPRITES := preload("res://scripts/presentation/sprite_catalog.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const RESOURCE := preload("res://scripts/entities/resource_node.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var holder := Node2D.new()
	root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	check(is_equal_approx(SPRITES.UNIT_PIXEL_SCALE_2D, SPRITES.BUILDING_PIXEL_SCALE_2D), "units and buildings use the same original-art zoom")
	# Actual scenes exercise the actor setup, upgrade refresh and every action sheet.
	for id in GameCatalog.units():
		var unit := UNIT.instantiate() as UnitAgent
		unit.def = GameCatalog.get_unit(id)
		unit.match_state = state
		unit.sim_pos = Vector2(1, 1)
		holder.add_child(unit)
		unit.set_physics_process(false)
		var sprite := unit.get_node("Billboard") as AnimatedSprite2D
		check(sprite.visible, "%s has its original sprite" % id)
		check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.BUILDING_PIXEL_SCALE_2D), "%s keeps original proportion to buildings" % id)
		unit.set_selected(true)
		check((unit.get_node("SelectionRing") as CanvasItem).visible, "%s selection remains visible" % id)
		for animation in sprite.sprite_frames.get_animation_names():
			var parsed := SPRITES.parse_directional_animation(animation)
			var meta := SPRITES.load_meta(SPRITES.unit_animation_sheet_base(unit.def.id, animation))
			for flip in [false, true]:
				unit._facing_flip = flip
				for frame_index in sprite.sprite_frames.get_frame_count(animation):
					sprite.animation = animation
					sprite.frame = frame_index
					sprite.flip_h = flip
					unit._apply_billboard_hotspot(sprite, animation, frame_index)
					var hotspot := SPRITES.hotspot_for_frame(meta, parsed.direction, frame_index, flip)
					var frame_size := sprite.sprite_frames.get_frame_texture(animation, frame_index).get_size()
					var peg := (hotspot - frame_size * 0.5 + sprite.offset) * sprite.scale
					check(peg.is_zero_approx(), "%s %s frame %d flip %s keeps its original ground peg" % [id, animation, frame_index, flip])
					check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.UNIT_PIXEL_SCALE_2D), "%s %s action preserves scale" % [id, animation])
		unit.apply_definition_upgrade(GameCatalog.get_unit(id))
		check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.UNIT_PIXEL_SCALE_2D), "%s upgrade refresh preserves scale" % id)
		unit.free()
	for civ_id in [&"chinese", &"teutons"]:
		for age in 4:
			state.set_age(0, age)
			for id in GameCatalog.buildings():
				var building := BUILDING.instantiate() as BuildingAgent
				building.def = GameCatalog.get_building(id)
				building.civ = load("res://data/civs/%s.tres" % civ_id)
				building.match_state = state
				building.sim_pos = Vector2(1, 1)
				holder.add_child(building)
				var sprite := building.get_node("Billboard") as Sprite2D
				check(sprite.visible, "%s %s era %d original sprite is visible" % [civ_id, id, age])
				check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.UNIT_PIXEL_SCALE_2D), "%s %s era %d preserves original human/building ratio" % [civ_id, id, age])
				building.free()
	for type in [Enums.ResourceType.FOOD, Enums.ResourceType.WOOD, Enums.ResourceType.GOLD, Enums.ResourceType.STONE]:
		var resource := RESOURCE.new() as ResourceNode
		resource.resource_type = type
		resource.sim_pos = Vector2(1, 1)
		holder.add_child(resource)
		var sprite := resource.get_node("Billboard") as Sprite2D
		check(sprite.visible, "resource type %d retains original art" % type)
		check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.UNIT_PIXEL_SCALE_2D), "resource type %d retains original ratio to people/buildings" % type)
		check(resource.block_half == ResourceNode.pathfinding_footprint(type) * 0.5, "resource type %d keeps playable collision geometry" % type)
		resource.free()
	holder.free()
	if "--render" in OS.get_cmdline_user_args():
		await _render_preview()
	print("ORIGINAL ART SCALE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _render_preview() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1400, 1020)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.color = Color("526543")
	ground.size = Vector2(viewport.size)
	ground.z_index = -100
	viewport.add_child(ground)
	for case in 4:
		var civ_id := "chinese" if case % 2 == 0 else "teutons"
		var state := MatchState.new()
		state.setup_defaults()
		state.progression_enabled = true
		state.set_age(0, 0 if case < 2 else 1)
		var entities := Node2D.new()
		entities.position = Vector2(350 + (case % 2) * 700, 325 + (case / 2) * 500)
		entities.y_sort_enabled = true
		viewport.add_child(entities)
		var building := BUILDING.instantiate() as BuildingAgent
		building.def = GameCatalog.get_building(&"town_center" if case < 2 else &"barracks")
		building.civ = load("res://data/civs/%s.tres" % civ_id)
		building.match_state = state
		entities.add_child(building)
		for index in 5:
			var unit := UNIT.instantiate() as UnitAgent
			unit.def = GameCatalog.get_unit(&"villager" if index != 4 else &"militia")
			unit.civ = building.civ
			unit.match_state = state
			unit.sim_pos = IsoMath.screen_to_world(Vector2(-180 + index * 90, 45 if index < 4 else -30))
			entities.add_child(unit)
			unit.set_physics_process(false)
			var sprite := unit.get_node("Billboard") as AnimatedSprite2D
			var anim: StringName = [&"idle_dir_0", &"walk_dir_1", &"chop_dir_0", &"mine_dir_0", &"attack_dir_0"][index]
			sprite.animation = anim
			sprite.frame = mini(4, sprite.sprite_frames.get_frame_count(anim) - 1)
			unit._apply_billboard_hotspot(sprite, anim, sprite.frame)
			unit.set_selected(true)
		for index in 3:
			var resource := RESOURCE.new() as ResourceNode
			resource.resource_type = [Enums.ResourceType.WOOD, Enums.ResourceType.GOLD, Enums.ResourceType.FOOD][index]
			resource.sim_pos = IsoMath.screen_to_world(Vector2(-250 + index * 90, 140))
			entities.add_child(resource)
		var label := Label.new()
		label.text = "%s  |  %s  |  original artwork × %.1f" % [civ_id.to_upper(), "DARK AGE / TC" if case < 2 else "FEUDAL AGE / BARRACKS", SPRITES.ORIGINAL_ART_PIXEL_SCALE_2D]
		label.position = entities.position + Vector2(-300, -300)
		label.add_theme_font_size_override("font_size", 20)
		viewport.add_child(label)
	for frame in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	viewport.get_texture().get_image().save_png("res://.godot/original-art-scale.png")
	viewport.free()
