extends RefCounted

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var south: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector3(0, 0, 1))
	if int(south["dir"]) != 0 or bool(south["flip"]):
		failures.append("south facing should use authored dir 0 without flip")
	var east: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector3(1, 0, 0))
	if int(east["dir"]) != 2 or not bool(east["flip"]):
		failures.append("east facing should flip authored west (dir 2)")
	var west: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector3(-1, 0, 0))
	if int(west["dir"]) != 2 or bool(west["flip"]):
		failures.append("west facing should use authored dir 2 without flip")
	var north: Dictionary = SpriteCatalogScript.quantize_xz_facing(Vector3(0, 0, -1))
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
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot(meta, hotspot)
			# Feet sit below the frame center in atlas space → billboard must lift up.
			if offset.y <= 0.0:
				failures.append(
					"hotspot offset.y should be positive so sprites stand above ground"
				)

	if not ResourceLoader.exists("res://assets/terrain/grass.png"):
		failures.append("terrain grass texture should exist")
	return failures
