extends RefCounted

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
	return root
