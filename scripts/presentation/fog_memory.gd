extends RefCounted

static var _shader_uniforms: Dictionary = {}

static func visual_nodes(entity: Node2D) -> Array[Node2D]:
	var result: Array[Node2D] = []
	for child in entity.get_children():
		if child is Node2D and child.name in ["Billboard", "Body", "Marker", "Fallback", "GroundShadow"]: result.append(child)
	return result

## Resource art has no animation. Signals cover texture/rect/material edits;
## these cheap values cover colors and transforms that have no public signal.
static func resource_values(entity: Node2D, visuals: Array[Node2D]) -> Array:
	var values: Array = [entity.modulate, entity.z_index, entity.z_as_relative]
	for child in visuals:
		if not is_instance_valid(child): continue
		values.append_array([child.visible, child.transform, child.modulate, child.self_modulate, child.z_index,
			child.z_as_relative, child.texture_filter, child.texture_repeat, child.material])
		if child is Polygon2D: values.append_array(_polygon_values(child))
		# ShaderMaterial.set_shader_parameter does not emit Resource.changed.
		# Resources normally have no material; poll uniforms only for the rare
		# custom shader case so its visible edits still enter the snapshot.
		if child.material is ShaderMaterial: values.append_array(_shader_values(child.material))
		elif child.material is CanvasItemMaterial: values.append_array(_canvas_material_values(child.material))
	return values

static func _canvas_material_values(material: CanvasItemMaterial) -> Array:
	return [material.blend_mode, material.light_mode, material.particles_animation,
		material.particles_anim_h_frames, material.particles_anim_v_frames, material.particles_anim_loop]

static func _polygon_values(polygon: Polygon2D) -> Array:
	return [polygon.polygon, polygon.offset, polygon.color, polygon.vertex_colors, polygon.polygons,
		polygon.texture, polygon.uv, polygon.texture_scale, polygon.texture_offset, polygon.texture_rotation,
		polygon.invert_enabled, polygon.invert_border, polygon.antialiased]

static func _shader_values(material: ShaderMaterial) -> Array:
	if material.shader == null: return []
	var shader_id: int = material.shader.get_instance_id()
	if not _shader_uniforms.has(shader_id):
		var names: Array[StringName] = []
		for uniform in material.shader.get_shader_uniform_list(): names.append(StringName(uniform.name))
		_shader_uniforms[shader_id] = names
	var values: Array = [material.shader]
	for name in _shader_uniforms[shader_id]: values.append(material.get_shader_parameter(name))
	return values

## Cached static snapshots only need recapturing when a visible visual changes.
## Include material uniforms, so changing colors / construction art in place is
## observed, while hidden entities retain their last visible appearance.
static func appearance_key(entity: Node2D) -> int:
	var values: Array = [entity.modulate, entity.z_index, entity.z_as_relative]
	var fortification := entity.get_node_or_null("FortificationVisual")
	if fortification != null and fortification.visible: values.append(fortification.appearance_values())
	for child in entity.get_children():
		if child is not Node2D or not child.visible or child.name not in ["Billboard", "Body", "Marker", "Fallback", "GroundShadow"]: continue
		values.append_array([child.get_instance_id(), child.transform, child.modulate, child.self_modulate,
			child.z_index, child.z_as_relative, child.texture_filter, child.texture_repeat])
		if child is Sprite2D:
			values.append_array([child.texture, child.offset, child.centered])
		elif child is AnimatedSprite2D:
			values.append_array([child.sprite_frames, child.animation, child.frame, child.offset, child.centered])
		elif child is Polygon2D:
			values.append_array(_polygon_values(child))
		else: continue
		var material: Material = child.material
		values.append(material)
		if material is ShaderMaterial and material.shader != null:
			values.append_array(_shader_values(material))
		elif material is CanvasItemMaterial:
			values.append_array(_canvas_material_values(material))
	return hash(values)

## Capture only visual values, never simulation nodes or scripts.
static func capture(entity: Node2D) -> Array:
	var parts: Array = []
	var fortification := entity.get_node_or_null("FortificationVisual")
	if fortification != null and fortification.visible: parts.append_array(fortification.fog_memory_parts())
	for child in entity.get_children():
		if child is not Node2D or not child.visible or child.name not in ["Billboard", "Body", "Marker", "Fallback", "GroundShadow"]:
			continue
		var part := {"transform": child.transform, "color": child.modulate * entity.modulate,
			"z":child.z_index + entity.z_index if child.z_as_relative else child.z_index,
			"self_modulate":child.self_modulate, "z_as_relative":entity.z_as_relative if child.z_as_relative else false,
			"texture_filter":child.texture_filter, "texture_repeat":child.texture_repeat}
		if child is Sprite2D:
			part["texture"] = child.texture
			part["offset"] = child.offset
			part["centered"] = child.centered
		elif child is AnimatedSprite2D:
			part["texture"] = child.sprite_frames.get_frame_texture(child.animation, child.frame)
			part["offset"] = child.offset
			part["centered"] = child.centered
		elif child is Polygon2D:
			part["polygon"] = child.polygon.duplicate()
			# Keep the combined color snapshot used by callers, while retaining
			# Polygon2D's own color separately (vertex colors can override it).
			part["modulate"] = part["color"]
			part["color"] *= child.color
			part["polygon_color"] = child.color
			part["polygon_offset"] = child.offset
			part["vertex_colors"] = child.vertex_colors.duplicate()
			part["polygons"] = child.polygons.duplicate(true)
			part["texture"] = child.texture
			part["uv"] = child.uv.duplicate()
			part["texture_scale"] = child.texture_scale
			part["texture_offset"] = child.texture_offset
			part["texture_rotation"] = child.texture_rotation
			part["invert_enabled"] = child.invert_enabled
			part["invert_border"] = child.invert_border
			part["antialiased"] = child.antialiased
		else:
			continue
		if child.material != null:
			part["material"] = child.material.duplicate()
		parts.append(part)
	return parts

static func make_view(snapshot: Dictionary) -> Node2D:
	var root := Node2D.new()
	root.name = "FogMemory"
	root.position = snapshot.position
	root.modulate = Color(0.4, 0.4, 0.4)
	root.set_meta("fog_memory", true)
	root.add_to_group("occlusion_memories")
	update_view(root, snapshot)
	return root

static func update_view(root: Node2D, snapshot: Dictionary) -> void:
	if root.position != snapshot.position: root.position = snapshot.position
	var appearance: int = snapshot.appearance if snapshot.has("appearance") else hash(snapshot.parts)
	if root.has_meta("fog_appearance") and root.get_meta("fog_appearance") == appearance:
		return
	root.set_meta("fog_appearance", appearance)
	for child in root.get_children(): child.free()
	for part in snapshot.parts:
		var visual: Node2D
		if part.has("polygon"):
			var polygon := Polygon2D.new()
			polygon.polygon = part.polygon
			polygon.color = part.get("polygon_color", Color.WHITE)
			polygon.offset = part.get("polygon_offset", Vector2.ZERO)
			polygon.vertex_colors = part.get("vertex_colors", PackedColorArray())
			polygon.polygons = part.get("polygons", [])
			polygon.texture = part.get("texture")
			polygon.uv = part.get("uv", PackedVector2Array())
			polygon.texture_scale = part.get("texture_scale", Vector2.ONE)
			polygon.texture_offset = part.get("texture_offset", Vector2.ZERO)
			polygon.texture_rotation = part.get("texture_rotation", 0.0)
			polygon.invert_enabled = part.get("invert_enabled", false)
			polygon.invert_border = part.get("invert_border", 100.0)
			polygon.antialiased = part.get("antialiased", false)
			visual = polygon
		else:
			var sprite := Sprite2D.new()
			sprite.texture = part.texture
			sprite.offset = part.offset
			sprite.centered = part.centered
			visual = sprite
		visual.transform = part.transform
		visual.modulate = part.get("modulate", part.color)
		visual.self_modulate = part.get("self_modulate", Color.WHITE)
		visual.z_index = part.z
		visual.z_as_relative = part.get("z_as_relative", true)
		visual.texture_filter = part.get("texture_filter", CanvasItem.TEXTURE_FILTER_PARENT_NODE)
		visual.texture_repeat = part.get("texture_repeat", CanvasItem.TEXTURE_REPEAT_PARENT_NODE)
		visual.material = part.get("material")
		root.add_child(visual)
