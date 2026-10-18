extends Node2D
## Original DAT/SLP shapes. Never rotate an isometric sprite in screen space.
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Colors := preload("res://scripts/presentation/team_color_catalog.gd")
const Occlusion := preload("res://scripts/presentation/unit_occlusion.gd")
const MANIFEST_PATH := "res://data/fortification_sprites.json"
static var _manifest: Dictionary = {}
var _refresh_remaining := 0.0
var _signature: Array = []
var sheet_base := ""
var frame_index := 0

static func manifest() -> Dictionary:
	if _manifest.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
		if parsed is Dictionary: _manifest = parsed
	return _manifest

func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if _refresh_remaining <= 0.0:
		_refresh_remaining = 0.25
		refresh()

func _wall_shape(building: BuildingAgent, catalog: Dictionary) -> int:
	var directions: Array[Vector2] = []
	if building.get_parent() != null:
		for neighbor in building.get_parent().get_children():
			if neighbor == building or neighbor is not BuildingAgent or neighbor.is_queued_for_deletion(): continue
			if neighbor.def == null or not Walls.is_fortification(neighbor.def.id) or neighbor.team != building.team: continue
			if neighbor.is_placement_ghost and not building.is_placement_ghost: continue
			var delta: Vector2 = neighbor.sim_pos - building.sim_pos
			if neighbor.def.id == &"gate":
				var tip := Walls.direction(neighbor.wall_orientation) * 1.5
				delta = delta - tip if (delta - tip).length_squared() < (delta + tip).length_squared() else delta + tip
			var snapped := delta.round()
			if not delta.is_equal_approx(snapped) or maxf(absf(delta.x), absf(delta.y)) != 1.0: continue
			if not directions.has(snapped): directions.append(snapped)
	# The original post covers an endpoint, a corner, or a junction. Only a
	# straight run uses a panel; derive its axis from neighbours after demolition.
	if directions.size() == 2 and directions[0] == -directions[1]:
		for orientation in 4:
			if directions[0] == Walls.direction(orientation) or directions[0] == -Walls.direction(orientation):
				return int(catalog.orientation_frames[orientation])
	return int(catalog.post_frame)

func refresh() -> void:
	var building := get_parent() as BuildingAgent
	if building == null or building.def == null: return
	var catalog := manifest()
	if catalog.is_empty(): return
	var civ_id := String(building.civ.id) if building.civ != null else "chinese"
	var civ: Dictionary = catalog.civilizations.get(civ_id, catalog.civilizations.chinese)
	var record: Dictionary = civ.get(String(building.def.id), {})
	if record.is_empty(): return
	var complete := building.is_complete or building.is_placement_ghost
	var color_id := Colors.resolve_color_id(building.team, building.match_state)
	var orientation := posmod(building.wall_orientation, 4)
	var count := 1
	var index := 0
	var base: String = record.complete
	if building.def.id == &"gate":
		if complete:
			index = orientation * 2 + (1 if building.gate_open else 0)
		else:
			base = catalog.gate_foundation_tile
			count = 4
	else:
		index = _wall_shape(building, catalog)
		if not complete:
			base = record.construction
			var stages := int(record.construction_stages)
			var progress := building.build_progress / maxf(1.0, building.def.build_time)
			index = index * stages + clampi(floori(progress * stages), 0, stages - 1) if int(record.construction_shapes) > 1 else 0
	var signature: Array = [base, index, count, orientation, color_id, complete]
	if signature == _signature: return
	_signature = signature
	sheet_base = base
	frame_index = index
	var metadata := Sprites.load_meta(base)
	var texture := Sprites.load_texture(base)
	if metadata.is_empty() or texture == null:
		push_error("Missing original fortification sheet: " + base)
		return
	# Native 96 x 48 tile diamonds must meet exactly on the 44 x 22 sim grid.
	# Uniform scaling keeps original perspective and aligns all four gate axes.
	var pixel_scale := Iso.SCALE_X / float(catalog.source_tile_half[0])
	while get_child_count() > count:
		get_child(get_child_count() - 1).free()
	while get_child_count() < count:
		var sprite := Sprite2D.new()
		sprite.name = "OriginalSprite%d" % get_child_count()
		add_child(sprite)
	for i in count:
		var sprite := get_child(i) as Sprite2D
		sprite.texture = Sprites.atlas_frame_at(metadata, texture, index)
		Sprites.configure_sprite_2d(sprite, pixel_scale,
			Sprites.offset_for_hotspot_2d(metadata, Sprites.hotspot_at_index(metadata, index)))
		Sprites.apply_player_color(sprite, base, color_id)
		sprite.z_index = 0 if complete else -1
		if count == 4: sprite.position = Iso.world_to_screen(Walls.direction(orientation) * (float(i) - 1.5))
	Occlusion.notify_static_entity(building)
	if building.match_state != null and building.match_state.fog != null: building.match_state.fog.dirty = true

func appearance_values() -> Array:
	var values: Array = [transform, modulate, self_modulate]
	for sprite: Sprite2D in get_children():
		values.append_array([sprite.texture, sprite.transform, sprite.offset, sprite.centered,
			sprite.modulate, sprite.self_modulate, sprite.z_index, sprite.material])
	return values

func visual_rect_canvas() -> Rect2:
	var result := Rect2()
	var metadata := Sprites.load_meta(sheet_base)
	var bounds: Array = metadata.get("content_bounds", [])
	for sprite: Sprite2D in get_children():
		var local := sprite.get_rect()
		if frame_index < bounds.size():
			var rect: Dictionary = bounds[frame_index]
			local = Rect2(local.position + Vector2(rect.x, rect.y), Vector2(rect.w, rect.h))
		var canvas_rect := sprite.global_transform * local
		result = result.merge(canvas_rect) if result.has_area() else canvas_rect
	return result

## Freeze the shown atlas frame and team shader, including an open gate.
func fog_memory_parts() -> Array:
	var building := get_parent() as Node2D
	var parts: Array = []
	for sprite: Sprite2D in get_children():
		var part := {"texture": sprite.texture, "offset": sprite.offset, "centered": sprite.centered,
			"transform": transform * sprite.transform, "color": sprite.modulate * modulate * building.modulate,
			"self_modulate": sprite.self_modulate * self_modulate,
			"z": sprite.z_index + z_index + building.z_index, "z_as_relative": building.z_as_relative,
			"texture_filter": sprite.texture_filter, "texture_repeat": sprite.texture_repeat}
		if sprite.material != null: part["material"] = sprite.material.duplicate()
		parts.append(part)
	return parts
