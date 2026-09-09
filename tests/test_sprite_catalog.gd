extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	# Screen-down / toward camera = logical (+X,+Z) on 2:1 iso.
	var south: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(1, 1))
	if int(south["dir"]) != 0 or bool(south["flip"]):
		failures.append("screen-south facing should use authored dir 0 without flip")
	var east: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(1, -1))
	if int(east["dir"]) != 2 or not bool(east["flip"]):
		failures.append("screen-east facing should flip authored west (dir 2)")
	var west: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(-1, 1))
	if int(west["dir"]) != 2 or bool(west["flip"]):
		failures.append("screen-west facing should use authored dir 2 without flip")
	var north: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(-1, -1))
	if int(north["dir"]) != 4 or bool(north["flip"]):
		failures.append("screen-north facing should use authored dir 4 without flip")
	var plus_z: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(0, 1))
	if int(plus_z["dir"]) != 1 or bool(plus_z["flip"]):
		failures.append("logical +Z should face screen SW (authored dir 1)")

	var villager_base := SpriteCatalogScript.unit_sheet_base(&"villager")
	if not SpriteCatalogScript.sheet_paths_exist(villager_base):
		failures.append("villager walk sheet should exist under assets/sprites/units")
	else:
		var meta := SpriteCatalogScript.load_meta(villager_base)
		if int(meta.get("directions", 0)) != 5:
			failures.append("villager sheet should declare 5 authored directions")
		var texture := SpriteCatalogScript.load_texture(villager_base)
		if texture == null:
			failures.append("villager sheet texture should load")
		else:
			var frames := SpriteCatalogScript.build_unit_sprite_frames(meta, texture)
			if not frames.has_animation(&"dir_0") or frames.get_frame_count(&"dir_0") <= 0:
				failures.append("villager SpriteFrames should include dir_0 walk frames")
			var frame_offset := SpriteCatalogScript.offset_for_frame_2d(meta, 0, 0, false)
			# Feet near bottom → offset.y negative so Sprite2D lifts the art above the origin.
			if frame_offset.y >= 0.0:
				failures.append(
					"2D per-frame hotspot offset.y should be negative so sprites stand above ground"
				)
			var flipped := SpriteCatalogScript.offset_for_frame_2d(meta, 0, 0, true)
			if not is_equal_approx(flipped.x, -frame_offset.x):
				failures.append("flipped hotspot should mirror offset.x around cell center")
			var parsed := SpriteCatalogScript.parse_directional_animation(&"walk_dir_2")
			if String(parsed["action"]) != "walk" or int(parsed["direction"]) != 2:
				failures.append("parse_directional_animation should split action and direction")
			var parsed_dir := SpriteCatalogScript.parse_directional_animation(&"dir_3")
			if int(parsed_dir["direction"]) != 3:
				failures.append("parse_directional_animation should parse bare dir_N animations")
			var probe := AnimatedSprite2D.new()
			SpriteCatalogScript.configure_sprite_2d(probe, 2.2, frame_offset)
			if not probe.centered:
				failures.append("2D sprites should be centered")
			if probe.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
				failures.append("2D sprites should use nearest filtering")
			if not probe.scale.is_equal_approx(Vector2(2.2, 2.2)):
				failures.append("configure_sprite_2d should apply pixel_scale")
			probe.free()

		var villager_frames := SpriteCatalogScript.build_villager_sprite_frames()
		if villager_frames.has_animation(&"walk_dir_0"):
			if villager_frames.get_frame_count(&"walk_dir_0") <= 0:
				failures.append("villager combined frames should include walk_dir_0")
			if (
				SpriteCatalogScript.sheet_paths_exist(
					String(SpriteCatalogScript.VILLAGER_ACTION_SHEETS.get(&"idle", ""))
				)
				and not villager_frames.has_animation(&"idle_dir_0")
			):
				failures.append("villager idle sheet exported but idle_dir_0 missing")
			if (
				SpriteCatalogScript.sheet_paths_exist(
					String(SpriteCatalogScript.VILLAGER_ACTION_SHEETS.get(&"chop", ""))
				)
				and not villager_frames.has_animation(&"chop_dir_0")
			):
				failures.append("villager chop sheet exported but chop_dir_0 missing")

	var arrow_base := SpriteCatalogScript.projectile_sheet_base()
	if SpriteCatalogScript.sheet_paths_exist(arrow_base):
		var arrow_meta := SpriteCatalogScript.load_meta(arrow_base)
		if int(arrow_meta.get("directions", 0)) != SpriteCatalogScript.ARROW_DIRECTION_COUNT:
			failures.append("arrow sheet should declare 16 direction groups")
		if int(arrow_meta.get("frames_per_direction", 0)) != SpriteCatalogScript.ARROW_FRAMES_PER_DIRECTION:
			failures.append("arrow sheet should declare 11 frames per direction")
		if not is_equal_approx(
			SpriteCatalogScript.screen_delta_to_clock_hours(Vector2(0.0, 1.0)), 6.0
		):
			failures.append("screen-down delta should read as 6 o'clock")
		var six_frame := SpriteCatalogScript.projectile_frame_for_flight(6.0, 0)
		if int(six_frame["group"]) != 0 or bool(six_frame["flip"]):
			failures.append("6 o'clock should use arrow group 0 without flip")
		var six_mid := SpriteCatalogScript.projectile_frame_for_flight(6.0, 4)
		if int(six_mid["index"]) != 4:
			failures.append("sequence step should advance within the fixed direction group")
		var eleven_half := SpriteCatalogScript.projectile_frame_for_flight(11.5, 0)
		if int(eleven_half["group"]) != SpriteCatalogScript.ARROW_DIRECTION_COUNT - 1:
			failures.append("11:30 should use the last arrow direction group")
		var three_frame := SpriteCatalogScript.projectile_frame_for_flight(3.0, 0)
		if not bool(three_frame["flip"]):
			failures.append("3 o'clock should mirror authored arrow frames")
		if int(three_frame["group"]) != int(SpriteCatalogScript.projectile_frame_for_flight(9.0, 0)["group"]):
			failures.append("3 o'clock mirror should match 9 o'clock source group")
		var seq_end := SpriteCatalogScript.projectile_frame_for_flight(6.0, 10)
		if int(seq_end["step"]) != SpriteCatalogScript.ARROW_FRAMES_PER_DIRECTION - 1:
			failures.append("flight sequence step should reach the last in-group frame")

	if not ResourceLoader.exists("res://assets/terrain/grass.png"):
		failures.append("terrain grass texture should exist")
	return failures
