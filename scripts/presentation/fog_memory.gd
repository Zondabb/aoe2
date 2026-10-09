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
	var values: Array = [entity.modulate]
	for child in visuals:
		if not is_instance_valid(child): continue
		values.append_array([child.visible, child.transform, child.modulate, child.z_index, child.material])
		if child is Polygon2D: values.append_array([child.color, child.polygon])
		# ShaderMaterial.set_shader_parameter does not emit Resource.changed.
		# Resources normally have no material; poll uniforms only for the rare
		# custom shader case so its visible edits still enter the snapshot.
		if child.material is ShaderMaterial: values.append_array(_shader_values(child.material))
		elif child.material is CanvasItemMaterial: values.append_array(_canvas_material_values(child.material))
	return values

static func _canvas_material_values(material: CanvasItemMaterial) -> Array:
	return [material.blend_mode, material.light_mode, material.particles_animation,
		material.particles_anim_h_frames, material.particles_anim_v_frames, material.particles_anim_loop]

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
	var values: Array = [entity.modulate]
	for child in entity.get_children():
		if child is not Node2D or not child.visible or child.name not in ["Billboard", "Body", "Marker", "Fallback", "GroundShadow"]: continue
		values.append_array([child.get_instance_id(), child.transform, child.modulate, child.z_index])
		if child is Sprite2D:
			values.append_array([child.texture, child.offset, child.centered])
		elif child is AnimatedSprite2D:
			values.append_array([child.sprite_frames, child.animation, child.frame, child.offset, child.centered])
		elif child is Polygon2D:
			values.append_array([child.polygon, child.color])
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
	for child in entity.get_children():
		if child is not Node2D or not child.visible or child.name not in ["Billboard", "Body", "Marker", "Fallback", "GroundShadow"]:
			continue
		var part := {"transform": child.transform, "color": child.modulate * entity.modulate, "z": child.z_index}
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
			part["color"] *= child.color
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
		if part.has("texture"):
			var sprite := Sprite2D.new()
			sprite.texture = part.texture
			sprite.offset = part.offset
			sprite.centered = part.centered
			visual = sprite
		else:
			var polygon := Polygon2D.new()
			polygon.polygon = part.polygon
			visual = polygon
		visual.transform = part.transform
		visual.modulate = part.color
		visual.z_index = part.z
		visual.material = part.get("material")
		root.add_child(visual)
