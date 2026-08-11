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

## Villager work animations — each value is a sheet base path (without extension).
const VILLAGER_ACTION_SHEETS := {
	&"walk": "res://assets/sprites/units/villager_walk",
	&"idle": "res://assets/sprites/units/villager_idle",
	&"gather_food": "res://assets/sprites/units/villager_gather_food",
	&"chop": "res://assets/sprites/units/villager_chop",
	&"mine": "res://assets/sprites/units/villager_mine",
	&"build": "res://assets/sprites/units/villager_build",
	&"die": "res://assets/sprites/units/villager_die",
}

## Combat sheets keyed by unit id → action → sheet base path.
const UNIT_COMBAT_SHEETS := {
	&"swordsman": {
		&"attack": "res://assets/sprites/units/swordsman_attack",
		&"die": "res://assets/sprites/units/swordsman_die",
	},
	&"archer": {
		&"attack": "res://assets/sprites/units/archer_attack",
		&"die": "res://assets/sprites/units/archer_die",
	},
	&"chu_ko_nu": {
		&"attack": "res://assets/sprites/units/chu_ko_nu_attack",
		&"die": "res://assets/sprites/units/chu_ko_nu_die",
	},
	&"teutonic_knight": {
		&"attack": "res://assets/sprites/units/teutonic_knight_attack",
		&"die": "res://assets/sprites/units/teutonic_knight_die",
	},
	&"villager": {
		&"attack": "res://assets/sprites/units/villager_chop",
		&"die": "res://assets/sprites/units/villager_die",
	},
}

const PROJECTILE_SHEET := "res://assets/sprites/units/arrow"

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
## Must match RtsCamera3D yaw so upright sprites face the lens (no billboard).
const ISO_CAMERA_YAW_DEGREES := 45.0
const ISO_SPRITE_YAW_RADIANS := deg_to_rad(ISO_CAMERA_YAW_DEGREES + 180.0)

const UNIT_PIXEL_SCALE_2D := 2.2
const BUILDING_PIXEL_SCALE_2D := 2.0
const RESOURCE_PIXEL_SCALE_2D := 2.0

## Authored sheet rows: 0=S, 1=SW, 2=W, 3=NW, 4=N. Mirrored facings use flip_h.
## Accepts Vector2 logical (x,z) or Vector3 (x,_,z).
## Facings follow 2:1 iso *screen* directions (S = toward camera / down),
## not raw world +Z — world_to_screen uses right=(x-z), down=(x+z).
static func quantize_xz_facing(velocity: Variant) -> Dictionary:
	var vx := 0.0
	var vz := 0.0
	if velocity is Vector2:
		var v2 := velocity as Vector2
		vx = v2.x
		vz = v2.y
	elif velocity is Vector3:
		var v3 := velocity as Vector3
		vx = v3.x
		vz = v3.z
	# Screen-space delta for classic 2:1 iso (scale cancels in atan2).
	var sx := vx - vz
	var sy := vx + vz
	if sx * sx + sy * sy < 0.000001:
		return {"dir": 0, "flip": false}
	# 0 = screen-down (toward camera = S), increasing toward screen-right (E).
	var angle := atan2(sx, sy)
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


static func projectile_sheet_base() -> String:
	return PROJECTILE_SHEET


static func combat_sheet_base(unit_id: StringName, action: StringName) -> String:
	if not UNIT_COMBAT_SHEETS.has(unit_id):
		return ""
	var by_action: Dictionary = UNIT_COMBAT_SHEETS[unit_id]
	return String(by_action.get(action, ""))


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


static func load_villager_metas_by_action() -> Dictionary:
	var result := {}
	for action: StringName in VILLAGER_ACTION_SHEETS:
		var base := String(VILLAGER_ACTION_SHEETS[action])
		if not sheet_paths_exist(base):
			continue
		var meta := load_meta(base)
		if not meta.is_empty():
			result[action] = meta
	return result


static func parse_directional_animation(anim: StringName) -> Dictionary:
	var name := String(anim)
	const MARKER := "_dir_"
	var marker_index := name.rfind(MARKER)
	if marker_index >= 0:
		var action_name := name.substr(0, marker_index)
		return {
			"action": StringName(action_name) if not action_name.is_empty() else &"",
			"direction": int(name.substr(marker_index + MARKER.length())),
		}
	if name.begins_with("dir_"):
		return {"action": &"", "direction": int(name.substr(4))}
	return {"action": &"", "direction": 0}


static func sheet_index_for_frame(meta: Dictionary, direction: int, frame_in_anim: int) -> int:
	var frames_per_dir := maxi(1, int(meta.get("frames_per_direction", 1)))
	return direction * frames_per_dir + frame_in_anim


static func hotspot_at_index(meta: Dictionary, sheet_index: int) -> Vector2:
	var hotspots: Variant = meta.get("hotspots", [])
	if typeof(hotspots) == TYPE_ARRAY:
		var entries := hotspots as Array
		if sheet_index >= 0 and sheet_index < entries.size():
			var entry: Variant = entries[sheet_index]
			if typeof(entry) == TYPE_DICTIONARY:
				return Vector2(
					float((entry as Dictionary).get("x", 0)),
					float((entry as Dictionary).get("y", 0))
				)
	var frame_w := float(meta.get("frame_w", 1))
	var frame_h := float(meta.get("frame_h", 1))
	return Vector2(frame_w * 0.5, frame_h)


static func hotspot_for_frame(meta: Dictionary, direction: int, frame_in_anim: int, flip_h: bool) -> Vector2:
	var hotspot := hotspot_at_index(meta, sheet_index_for_frame(meta, direction, frame_in_anim))
	if flip_h:
		hotspot.x = float(meta.get("frame_w", 1)) - hotspot.x
	return hotspot


static func offset_for_frame_2d(
	meta: Dictionary, direction: int, frame_in_anim: int, flip_h: bool = false
) -> Vector2:
	return offset_for_hotspot_2d(meta, hotspot_for_frame(meta, direction, frame_in_anim, flip_h))


static func offset_for_hotspot(meta: Dictionary, hotspot: Vector2) -> Vector2:
	## Keep the cell hotspot at the node origin (feet / ground peg).
	## Sprite3D offset Y is up when billboarded; atlas hotspot Y grows downward,
	## so a near-bottom hotspot must produce a positive offset.y.
	var frame_w := float(meta.get("frame_w", 1))
	var frame_h := float(meta.get("frame_h", 1))
	return Vector2(frame_w * 0.5 - hotspot.x, hotspot.y - frame_h * 0.5)


static func build_unit_sprite_frames(meta: Dictionary, texture: Texture2D) -> SpriteFrames:
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	_add_directional_animations(frames, "", meta, texture, true)
	return frames


static func append_unit_combat_frames(
	frames: SpriteFrames, unit_id: StringName
) -> Dictionary:
	var metas := {}
	if not UNIT_COMBAT_SHEETS.has(unit_id):
		return metas
	var by_action: Dictionary = UNIT_COMBAT_SHEETS[unit_id]
	for action: StringName in by_action:
		var base := String(by_action[action])
		if not sheet_paths_exist(base):
			continue
		var meta := load_meta(base)
		var texture := load_texture(base)
		if meta.is_empty() or texture == null:
			continue
		var loop := action != &"die" and action != &"attack"
		_add_directional_animations(frames, String(action), meta, texture, loop)
		metas[action] = meta
	return metas


static func build_villager_sprite_frames() -> SpriteFrames:
	var frames := SpriteFrames.new()
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	for action: StringName in VILLAGER_ACTION_SHEETS:
		var base := String(VILLAGER_ACTION_SHEETS[action])
		if not sheet_paths_exist(base):
			continue
		var meta := load_meta(base)
		var texture := load_texture(base)
		if meta.is_empty() or texture == null:
			continue
		var loop := action != &"die"
		_add_directional_animations(frames, String(action), meta, texture, loop)
	return frames


static func villager_walk_meta() -> Dictionary:
	var base := String(VILLAGER_ACTION_SHEETS.get(&"walk", ""))
	if base.is_empty() or not ResourceLoader.exists(base + ".json"):
		return {}
	return load_meta(base)


static func _add_directional_animations(
	frames: SpriteFrames,
	prefix: String,
	meta: Dictionary,
	texture: Texture2D,
	loop: bool = true
) -> void:
	var frame_w := int(meta.get("frame_w", 1))
	var frame_h := int(meta.get("frame_h", 1))
	var cols := int(meta.get("cols", 1))
	var directions := maxi(1, int(meta.get("directions", 1)))
	var frames_per_dir := maxi(1, int(meta.get("frames_per_direction", 1)))
	var frame_count := int(meta.get("frame_count", frames_per_dir * directions))
	for direction in directions:
		var anim_name := _direction_animation_name(prefix, direction)
		frames.add_animation(anim_name)
		frames.set_animation_speed(anim_name, 12.0)
		frames.set_animation_loop(anim_name, loop)
		for step in frames_per_dir:
			var index := direction * frames_per_dir + step
			if index >= frame_count:
				break
			frames.add_frame(anim_name, _atlas_frame(texture, cols, frame_w, frame_h, index))


static func _direction_animation_name(prefix: String, direction: int) -> StringName:
	if prefix.is_empty():
		return StringName("dir_%d" % direction)
	return StringName("%s_dir_%d" % [prefix, direction])


static func first_atlas_texture(meta: Dictionary, texture: Texture2D) -> AtlasTexture:
	return atlas_frame_at(meta, texture, 0)


static func atlas_frame_at(meta: Dictionary, texture: Texture2D, index: int) -> AtlasTexture:
	return _atlas_frame(
		texture,
		int(meta.get("cols", 1)),
		int(meta.get("frame_w", 1)),
		int(meta.get("frame_h", 1)),
		maxi(0, index)
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
	## Backward-compatible name: now configures fixed-yaw isometric cards (no billboard).
	configure_iso_sprite(sprite, pixel_size, offset)


static func configure_iso_sprite(sprite: Node, pixel_size: float, offset: Vector2) -> void:
	## Upright Sprite3D facing the fixed RTS camera — AoE sheets are pre-isometric.
	if sprite is AnimatedSprite3D:
		var animated := sprite as AnimatedSprite3D
		animated.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		animated.shaded = false
		animated.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		animated.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		animated.pixel_size = pixel_size
		animated.centered = true
		animated.offset = offset
		animated.position = Vector3.ZERO
		animated.rotation = Vector3(0.0, ISO_SPRITE_YAW_RADIANS, 0.0)
	elif sprite is Sprite3D:
		var static_sprite := sprite as Sprite3D
		static_sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		static_sprite.shaded = false
		static_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
		static_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		static_sprite.pixel_size = pixel_size
		static_sprite.centered = true
		static_sprite.offset = offset
		static_sprite.position = Vector3.ZERO
		static_sprite.rotation = Vector3(0.0, ISO_SPRITE_YAW_RADIANS, 0.0)


static func ensure_ground_shadow(parent: Node3D, radius: float) -> void:
	if parent == null:
		return
	var shadow := parent.get_node_or_null("GroundShadow") as MeshInstance3D
	if shadow == null:
		shadow = MeshInstance3D.new()
		shadow.name = "GroundShadow"
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(shadow)
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = 0.025
	mesh.radial_segments = 24
	mesh.rings = 1
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.0, 0.0, 0.0, 0.35)
	mesh.material = material
	shadow.mesh = mesh
	shadow.position = Vector3(0.0, 0.012, 0.0)
	shadow.scale = Vector3(1.15, 1.0, 0.7)
	shadow.visible = true


static func offset_for_hotspot_2d(meta: Dictionary, hotspot: Vector2) -> Vector2:
	## Sprite2D Y grows downward; keep feet on the node origin.
	var frame_w := float(meta.get("frame_w", 1))
	var frame_h := float(meta.get("frame_h", 1))
	return Vector2(frame_w * 0.5 - hotspot.x, frame_h * 0.5 - hotspot.y)


static func configure_sprite_2d(
	sprite: Node, pixel_scale: float, offset_pixels: Vector2
) -> void:
	if sprite is AnimatedSprite2D:
		var animated := sprite as AnimatedSprite2D
		animated.centered = true
		animated.offset = offset_pixels
		animated.scale = Vector2(pixel_scale, pixel_scale)
		animated.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		animated.position = Vector2.ZERO
		if animated.is_playing():
			animated.stop()
	elif sprite is Sprite2D:
		var static_sprite := sprite as Sprite2D
		static_sprite.centered = true
		static_sprite.offset = offset_pixels
		static_sprite.scale = Vector2(pixel_scale, pixel_scale)
		static_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		static_sprite.position = Vector2.ZERO


static func ensure_ground_shadow_2d(parent: Node2D, radius_px: float) -> void:
	if parent == null:
		return
	var shadow := parent.get_node_or_null("GroundShadow") as Polygon2D
	if shadow == null:
		shadow = Polygon2D.new()
		shadow.name = "GroundShadow"
		shadow.z_index = -1
		parent.add_child(shadow)
		parent.move_child(shadow, 0)
	shadow.polygon = _ellipse_points(radius_px * 1.15, radius_px * 0.55, 24)
	shadow.color = Color(0.0, 0.0, 0.0, 0.35)
	shadow.visible = true


static func _ellipse_points(radius_x: float, radius_y: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := maxi(segments, 8)
	for index in count:
		var angle := TAU * float(index) / float(count)
		points.append(Vector2(cos(angle) * radius_x, sin(angle) * radius_y))
	return points
