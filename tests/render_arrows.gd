extends SceneTree
## Native framebuffer preview. Faint guides and simultaneous samples are only
## explanatory overlays; every actor and projectile uses its real scene/art.
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE := preload("res://scenes/entities/projectile_view.tscn")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const BG := Color("344635")
var viewport: SubViewport
var state: MatchState
var samples: Array[ProjectileAgent] = []
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func label_at(text: String, at: Vector2, size := 20, color := Color("e4e6d6")) -> void:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	viewport.add_child(label)

func panel(rect: Rect2, color: Color) -> void:
	var background := ColorRect.new()
	background.position = rect.position
	background.size = rect.size
	background.color = color
	background.z_index = -100
	viewport.add_child(background)

func line(parent: Node, points: PackedVector2Array, color: Color, width := 1.0) -> void:
	var guide := Line2D.new()
	guide.points = points
	guide.default_color = color
	guide.width = width
	guide.z_index = -1
	parent.add_child(guide)

func unit_at(parent: Node2D, id: StringName, position: Vector2, side := Enums.Team.PLAYER) -> UnitAgent:
	var actor := UNIT.instantiate() as UnitAgent
	actor.def = Catalog.get_unit(id)
	actor.sim_pos = position
	actor.team = side
	actor.match_state = state
	parent.add_child(actor)
	actor.set_physics_process(false)
	actor.set_process(false)
	return actor

func lane(id: StringName, origin: Vector2, direction: Vector2, building := false) -> void:
	var entities := Node2D.new()
	entities.position = origin
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	var weapon := Catalog.building_weapon(id) if building else Catalog.get_unit(id)
	if weapon == null:
		failures.append("Missing weapon: " + String(id))
		return
	var source: Node2D
	if building:
		var actor := BUILDING.instantiate() as BuildingAgent
		actor.def = Catalog.get_building(id)
		actor.match_state = state
		actor.team = Enums.Team.PLAYER
		actor.civ = load("res://data/civs/chinese.tres")
		entities.add_child(actor)
		actor.set_physics_process(false)
		actor.set_process(false)
		source = actor
	else:
		var actor := unit_at(entities, id, Vector2.ZERO)
		var facing := Sprites.quantize_xz_facing(direction)
		actor._facing_dir = int(facing.dir)
		actor._facing_flip = bool(facing.flip)
		actor._combat_anim_time = maxf(0.0, weapon.attack_release_delay)
		actor._apply_billboard_frame(true, &"attack", false)
		source = actor
	var aim := direction.normalized() * weapon.attack_range
	unit_at(entities, &"militia", aim, Enums.Team.AI)
	var endpoint := Iso.world_to_screen(aim)
	line(entities, PackedVector2Array([Vector2.ZERO, endpoint]), Color(0.8, 0.86, 0.72, 0.2))
	for t in [0.08, 0.25, 0.43, 0.62, 0.8, 0.94]:
		var shot := PROJECTILE.instantiate() as ProjectileAgent
		entities.add_child(shot)
		shot.setup(Vector2.ZERO, aim, weapon, Enums.Team.PLAYER, source)
		shot.set_physics_process(false)
		shot.set_process(false)
		shot._traveled = weapon.attack_range * t
		shot.sim_pos = aim * t
		shot._sync_visual(t)
		samples.append(shot)
	var path := PackedVector2Array()
	for i in 61:
		path.append(samples.back()._screen_pos_for_progress(i / 60.0))
	line(entities, path, Color(0.95, 0.86, 0.6, 0.27))
	line(entities, PackedVector2Array([Vector2.ZERO, Vector2(0, -weapon.projectile_launch_height)]), Color(0.9, 0.9, 0.75, 0.25))
	line(entities, PackedVector2Array([endpoint + Vector2(-7, 0), endpoint + Vector2(7, 0)]), Color("b8c8a5"), 2.0)
	line(entities, PackedVector2Array([endpoint + Vector2(0, -7), endpoint + Vector2(0, 7)]), Color("b8c8a5"), 2.0)

func enlarged_row(id: StringName, at: Vector2) -> void:
	var weapon := Catalog.get_unit(id)
	var meta := Sprites.load_meta(weapon.projectile_flight_sheet)
	var texture := Sprites.load_texture(weapon.projectile_flight_sheet)
	for i in 7:
		var clock := 3.0 + i * 1.5
		var frame := Sprites.projectile_frame_for_flight(clock, 5, meta)
		var sprite := Sprite2D.new()
		sprite.texture = Sprites.atlas_frame_at(meta, texture, int(frame.index))
		sprite.flip_h = bool(frame.flip)
		Sprites.configure_sprite_2d(sprite, Sprites.ORIGINAL_ART_PIXEL_SCALE_2D * 3.0, Vector2.ZERO)
		sprite.position = at + Vector2(i * 125, 0)
		viewport.add_child(sprite)

func _run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1680, 1500)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	panel(Rect2(Vector2.ZERO, viewport.size), BG)
	panel(Rect2(24, 108, 1632, 252), Color("3d5140"))
	panel(Rect2(24, 380, 1280, 340), Color("3d5140"))
	panel(Rect2(1324, 380, 332, 340), Color("3d5140"))
	panel(Rect2(24, 740, 1632, 380), Color("3d5140"))
	panel(Rect2(24, 1140, 1632, 336), Color("26372d"))
	state = MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.set_age(0, 1)
	state.set_age(1, 1)
	state.frozen = true
	state.set_team_color_id(0, 1)
	state.set_team_color_id(1, 2)
	label_at("原版箭矢 / 射程 / 发射高度", Vector2(36, 22), 30)
	label_at("原版素材等比例 1.2×  ·  每条轨迹显示同一发射的 6 个时刻  ·  淡线仅为预览辅助", Vector2(38, 68), 19)
	label_at("射手 →  基础射程 4 格", Vector2(46, 128), 23)
	label_at("← 射手  基础射程 4 格", Vector2(872, 128), 23)
	lane(&"archer", Vector2(138, 291), Vector2(1, -1))
	lane(&"archer", Vector2(1515, 291), Vector2(-1, 1))
	label_at("箭塔 →  基础射程 8 格", Vector2(46, 400), 23)
	lane(&"watch_tower", Vector2(160, 674), Vector2(1, -1), true)
	label_at("射手 ↑  4 格", Vector2(1350, 400), 23)
	lane(&"archer", Vector2(1490, 698), Vector2(-1, -1))
	label_at("← 城镇中心  基础射程 6 格", Vector2(46, 760), 23)
	lane(&"town_center", Vector2(1325, 1050), Vector2(-1, 1), true)
	label_at("3× 局部放大 · 方向帧", Vector2(46, 1156), 23)
	label_at("原版箭矢", Vector2(60, 1220), 20)
	enlarged_row(&"archer", Vector2(300, 1240))
	label_at("原版标枪", Vector2(60, 1323), 20)
	enlarged_row(&"skirmisher", Vector2(300, 1340))
	label_at("箭矢使用 SLP 3799\n标枪使用 SLP 3820\n轨迹方程为运行时近似", Vector2(1230, 1210), 19, Color("afc0ae"))
	for i in 5:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	for shot in samples:
		var sprite := shot.get_node("Sprite") as Sprite2D
		if sprite.texture == null or not sprite.visible:
			failures.append("Projectile lacks visible native texture")
	var result := image.save_png("res://.godot/arrows-preview.png")
	if result != OK: failures.append("Screenshot: " + error_string(result))
	# Prove native arrows reach the framebuffer, including the upward shot.
	for shot in samples: shot.hide()
	await process_frame
	await RenderingServer.frame_post_draw
	var hidden := viewport.get_texture().get_image()
	var changed := 0
	for y in 1120:
		for x in 1680:
			if image.get_pixel(x, y) != hidden.get_pixel(x, y): changed += 1
	if changed < 120: failures.append("Native projectiles changed too few framebuffer pixels: %d" % changed)
	for index in samples.size():
		var center := Vector2i(samples[index].global_position)
		var visible_pixels := 0
		for y in range(maxi(0, center.y - 32), mini(1120, center.y + 32)):
			for x in range(maxi(0, center.x - 32), mini(1680, center.x + 32)):
				if image.get_pixel(x, y) != hidden.get_pixel(x, y): visible_pixels += 1
		if visible_pixels == 0: failures.append("Projectile sample %d is absent from the framebuffer" % index)
	viewport.free()
	for failure in failures: push_error(failure)
	print("ARROW GPU: %d projectile samples, %d changed pixels, %d failures" % [samples.size(), changed, failures.size()])
	quit(0 if failures.is_empty() else 1)
