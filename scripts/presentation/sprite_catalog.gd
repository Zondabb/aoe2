class_name SpriteCatalog
extends RefCounted

## Paths and helpers for exported AoE2 sprite sheets under assets/sprites/.

const UNIT_SHEETS := {
	&"villager": "res://assets/sprites/units/villager_walk",
	&"swordsman": "res://assets/sprites/units/swordsman_walk",
	&"archer": "res://assets/sprites/units/archer_walk",
	&"chu_ko_nu": "res://assets/sprites/units/chu_ko_nu_walk",
	&"teutonic_knight": "res://assets/sprites/units/teutonic_knight_walk",
}

const BUILDING_SHEETS := {
	&"town_center": {
		&"chinese": "res://assets/sprites/buildings/tc_asian_feudal_top",
		&"default": "res://assets/sprites/buildings/tc_dark_main",
	},
	&"house": {
		&"chinese": "res://assets/sprites/buildings/house_asian_feudal",
		&"default": "res://assets/sprites/buildings/house_dark",
	},
	&"barracks": {
		&"default": "res://assets/sprites/buildings/barracks_asian_feudal",
	},
	&"archery_range": {
		&"default": "res://assets/sprites/buildings/archery_asian_feudal",
	},
	&"stable": {
		&"chinese": "res://assets/sprites/buildings/stable_asian_feudal",
		&"default": "res://assets/sprites/buildings/stable_ne_feudal",
	},
}

const RESOURCE_SHEETS := {
	Enums.ResourceType.FOOD: "res://assets/sprites/resources/berry_bush",
	Enums.ResourceType.WOOD: "res://assets/sprites/resources/tree_oak",
	Enums.ResourceType.GOLD: "res://assets/sprites/resources/gold_mine",
}

const UNIT_PIXEL_SIZE := 0.04
const BUILDING_PIXEL_SIZE := 0.03
const RESOURCE_PIXEL_SIZE := 0.035
const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"

## Authored sheet rows: 0=S, 1=SW, 2=W, 3=NW, 4=N. Mirrored facings use flip_h.
static func quantize_xz_facing(velocity: Vector3) -> Dictionary:
	var planar := Vector3(velocity.x, 0.0, velocity.z)
	if planar.length_squared() < 0.000001:
		return {"dir": 0, "flip": false}
	# 0 = +Z (South), increasing toward +X (East).
	var angle := atan2(planar.x, planar.z)
	var sector := posmod(int(round(angle / (PI / 4.0))), 8)
	match sector:
		0:
			return {"dir": 0, "flip": false} # S
		1:
			return {"dir": 1, "flip": true} # SE <- SW
		2:
			return {"dir": 2, "flip": true} # E <- W
		3:
			return {"dir": 3, "flip": true} # NE <- NW
		4:
			return {"dir": 4, "flip": false} # N
		5:
			return {"dir": 3, "flip": false} # NW
		6:
			return {"dir": 2, "flip": false} # W
		_:
			return {"dir": 1, "flip": false} # SW


static func unit_sheet_base(unit_id: StringName) -> String:
	return String(UNIT_SHEETS.get(unit_id, ""))


static func building_sheet_base(building_id: StringName, civ_id: StringName) -> String:
	if not BUILDING_SHEETS.has(building_id):
		return ""
	var by_civ: Dictionary = BUILDING_SHEETS[building_id]
	if by_civ.has(civ_id):
		return String(by_civ[civ_id])
	return String(by_civ.get(&"default", ""))


static func resource_sheet_base(resource_type: int) -> String:
	return String(RESOURCE_SHEETS.get(resource_type, ""))


static func sheet_paths_exist(base: String) -> bool:
	if base.is_empty():
		return false
	return ResourceLoader.exists(base + ".png") and ResourceLoader.exists(base + ".json")


static func load_meta(base: String) -> Dictionary:
	if not ResourceLoader.exists(base + ".json"):
		return {}
	var file := FileAccess.open(base + ".json", FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


static func load_texture(base: String) -> Texture2D:
	if not ResourceLoader.exists(base + ".png"):
		return null
	return load(base + ".png") as Texture2D


static func average_hotspot(meta: Dictionary) -> Vector2:
	var hotspots: Variant = meta.get("hotspots", [])
	if typeof(hotspots) != TYPE_ARRAY or (hotspots as Array).is_empty():
		var fw := float(meta.get("frame_w", 1))
		var fh := float(meta.get("frame_h", 1))
		return Vector2(fw * 0.5, fh)
	var sum := Vector2.ZERO
	var count := 0
	for entry in hotspots:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		sum += Vector2(float(entry.get("x", 0)), float(entry.get("y", 0)))
		count += 1
	if count == 0:
		return Vector2.ZERO
	return sum / float(count)


static func offset_for_hotspot(meta: Dictionary, hotspot: Vector2) -> Vector2:
	## Keep the cell hotspot at the node origin (feet / ground peg).
	var frame_w := float(meta.get("frame_w", 1))
	var frame_h := float(meta.get("frame_h", 1))
	return Vector2(frame_w * 0.5 - hotspot.x, frame_h * 0.5 - hotspot.y)


static func build_unit_sprite_frames(meta: Dictionary, texture: Texture2D) -> SpriteFrames:
	var frames := SpriteFrames.new()
	var frame_w := int(meta.get("frame_w", 1))
	var frame_h := int(meta.get("frame_h", 1))
	var cols := int(meta.get("cols", 1))
	var directions := maxi(1, int(meta.get("directions", 1)))
	var frames_per_dir := maxi(1, int(meta.get("frames_per_direction", 1)))
	var frame_count := int(meta.get("frame_count", frames_per_dir * directions))
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	for direction in directions:
		var anim_name := StringName("dir_%d" % direction)
		frames.add_animation(anim_name)
		frames.set_animation_speed(anim_name, 12.0)
		frames.set_animation_loop(anim_name, true)
		for step in frames_per_dir:
			var index := direction * frames_per_dir + step
			if index >= frame_count:
				break
			frames.add_frame(anim_name, _atlas_frame(texture, cols, frame_w, frame_h, index))
	return frames


static func first_atlas_texture(meta: Dictionary, texture: Texture2D) -> AtlasTexture:
	return _atlas_frame(
		texture,
		int(meta.get("cols", 1)),
		int(meta.get("frame_w", 1)),
		int(meta.get("frame_h", 1)),
		0
	)


static func _atlas_frame(
	texture: Texture2D, cols: int, frame_w: int, frame_h: int, index: int
) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	var col := index % maxi(cols, 1)
	var row := index / maxi(cols, 1)
	atlas.region = Rect2(col * frame_w, row * frame_h, frame_w, frame_h)
	return atlas


static func configure_billboard_sprite(sprite: Node, pixel_size: float, offset: Vector2) -> void:
	if sprite is AnimatedSprite3D:
		var animated := sprite as AnimatedSprite3D
		animated.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		animated.shaded = false
		animated.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		animated.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		animated.pixel_size = pixel_size
		animated.centered = true
		animated.offset = offset
		animated.position = Vector3.ZERO
	elif sprite is Sprite3D:
		var static_sprite := sprite as Sprite3D
		static_sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		static_sprite.shaded = false
		static_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		static_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		static_sprite.pixel_size = pixel_size
		static_sprite.centered = true
		static_sprite.offset = offset
		static_sprite.position = Vector3.ZERO
