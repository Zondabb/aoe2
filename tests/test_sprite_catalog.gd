extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var south: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(0, 1))
	if int(south["dir"]) != 0 or bool(south["flip"]):
		failures.append("south facing should use authored dir 0 without flip")
	var east: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(1, 0))
	if int(east["dir"]) != 2 or not bool(east["flip"]):
		failures.append("east facing should flip authored west (dir 2)")
	var west: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(-1, 0))
	if int(west["dir"]) != 2 or bool(west["flip"]):
		failures.append("west facing should use authored dir 2 without flip")
	var north: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector2(0, -1))
	if int(north["dir"]) != 4 or bool(north["flip"]):
		failures.append("north facing should use authored dir 4 without flip")

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
			if not flipped.x.is_equal_approx(-frame_offset.x):
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

	if not ResourceLoader.exists("res://assets/terrain/grass.png"):
		failures.append("terrain grass texture should exist")
	return failures
