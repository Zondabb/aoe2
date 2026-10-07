extends Node

## One screen-sized mask per game viewport, shared by all unit outlines.
## Copies render in the same Z/Y/tree order as the game. Foreground units clear
## the static mask so outlines never draw over another unobscured unit.
const DEPTH := preload("res://shaders/occlusion_depth.gdshader")
const OUTLINE := preload("res://shaders/occluded_unit_outline.gdshader")
const COLORS := preload("res://scripts/presentation/team_color_catalog.gd")
const KEY := &"unit_occlusion_renderer"
var enabled := true
var mask_view: SubViewport
var copies: Dictionary = {}
var outlines: Dictionary = {}

static func ensure_for(unit: Node) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var viewport := unit.get_viewport()
	if viewport.has_meta(KEY) and is_instance_valid(viewport.get_meta(KEY)):
		return
	var renderer := load("res://scripts/presentation/unit_occlusion.gd").new() as Node
	viewport.set_meta(KEY, renderer)
	viewport.add_child.call_deferred(renderer)

func _ready() -> void:
	mask_view = SubViewport.new()
	mask_view.name = "UnitOcclusionMask"
	mask_view.disable_3d = true
	mask_view.transparent_bg = true
	mask_view.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	mask_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(mask_view)
	# Run after unit animation updates, before queued canvas redraws are flushed.
	# frame_pre_draw is too late: uniforms update immediately but Sprite2D UVs
	# would still belong to the previous animation frame, especially on Web.
	process_priority = 100

func _process(_delta: float) -> void:
	update_mask()

func _exit_tree() -> void:
	for overlay in outlines.values():
		if is_instance_valid(overlay):
			overlay.queue_free()

func _visible(node: CanvasItem) -> bool:
	return node.get_viewport() == get_viewport() and node.is_visible_in_tree() and node.modulate.a > 0.01

static func _effective_z(item: CanvasItem) -> int:
	var value := item.z_index
	while item.z_as_relative and item.get_parent() is CanvasItem:
		item = item.get_parent() as CanvasItem
		value += item.z_index
	return value

static func _before(a: Dictionary, b: Dictionary) -> bool:
	if a.z != b.z:
		return a.z < b.z
	if a.y != b.y:
		return a.y < b.y
	return (b.source as Node).is_greater_than(a.source)

func _part(actor: Node2D, source: Node2D, dynamic: bool, screen: Rect2) -> Dictionary:
	if not _visible(source):
		return {}
	var texture: Texture2D
	if source is AnimatedSprite2D:
		if source.sprite_frames == null or not source.sprite_frames.has_animation(source.animation):
			return {}
		texture = source.sprite_frames.get_frame_texture(source.animation, source.frame)
	elif source is Sprite2D:
		texture = source.texture
	else:
		return {}
	if texture == null:
		return {}
	var transform := source.get_global_transform_with_canvas()
	var bounds := Rect2(source.offset, texture.get_size())
	if source.centered:
		bounds.position -= bounds.size * 0.5
	if not screen.intersects(transform * bounds):
		return {}
	return {"actor": actor, "source": source, "texture": texture, "transform": transform,
		"dynamic": dynamic, "z": _effective_z(source), "y": source.global_position.y}

func update_mask() -> void:
	if not is_inside_tree() or mask_view == null:
		return
	if not enabled:
		for overlay in outlines.values():
			if is_instance_valid(overlay):
				overlay.hide()
		mask_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	var size := Vector2i(get_viewport().get_visible_rect().size)
	if size.x < 2 or size.y < 2:
		return
	# Match the framebuffer, including Window stretch. A logical-resolution mask
	# can disagree by an edge pixel with the displayed building after resizing.
	var stretch := get_viewport().get_stretch_transform()
	var pixel_size := Vector2i((Vector2(size) * stretch.get_scale()).round())
	if mask_view.size != pixel_size:
		mask_view.size = pixel_size
	var screen := Rect2(Vector2.ZERO, Vector2(size))
	var parts: Array[Dictionary] = []
	var alive_outlines: Dictionary = {}
	var static_count := 0
	for group in [&"buildings", &"resource_nodes", &"path_blockers", &"occlusion_memories"]:
		for actor in get_tree().get_nodes_in_group(group):
			if actor is not Node2D or not _visible(actor) or actor.get("is_placement_ghost") == true:
				continue
			for source in actor.get_children():
				if source is not Sprite2D or source.name == &"GroundShadow" or source.z_index < 0:
					continue
				var part := _part(actor, source, false, screen)
				if not part.is_empty():
					parts.append(part)
					static_count += 1
	for actor in get_tree().get_nodes_in_group("units"):
		if actor is not Node2D or actor.get_viewport() != get_viewport():
			continue
		var id: int = actor.get_instance_id()
		alive_outlines[id] = true
		if is_instance_valid(outlines.get(id)):
			outlines[id].visible = false
		if not _visible(actor):
			continue
		for name in [&"Billboard", &"Body"]:
			var source := actor.get_node_or_null(NodePath(name)) as Node2D
			if source == null:
				continue
			var part := _part(actor, source, true, screen)
			if not part.is_empty():
				parts.append(part)
				break
	for id in outlines.keys():
		if not alive_outlines.has(id):
			if is_instance_valid(outlines[id]):
				outlines[id].queue_free()
			outlines.erase(id)
	parts.sort_custom(_before)
	var alive_copies: Dictionary = {}
	var order := 0
	for part in parts:
		order += 1
		var source: Node2D = part.source
		var id := source.get_instance_id()
		alive_copies[id] = true
		var copy := copies.get(id) as Sprite2D
		if copy == null:
			copy = Sprite2D.new()
			copy.material = ShaderMaterial.new()
			copy.material.shader = DEPTH
			mask_view.add_child(copy)
			copies[id] = copy
		_copy_sprite(copy, source, part.texture)
		copy.transform = stretch * part.transform
		copy.modulate.a = source.modulate.a * source.self_modulate.a * part.actor.modulate.a
		var rank := 0 if part.dynamic else order
		copy.material.set_shader_parameter("drawing_order", Vector2(rank % 256, rank / 256) / 255.0)
		mask_view.move_child(copy, mask_view.get_child_count() - 1)
		if part.dynamic and static_count > 0:
			_update_outline(part, order)
	for id in copies.keys():
		if not alive_copies.has(id):
			copies[id].free()
			copies.erase(id)
	mask_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if static_count > 0 and not outlines.is_empty() else SubViewport.UPDATE_DISABLED

static func _copy_sprite(copy: Sprite2D, source: Node2D, texture: Texture2D) -> void:
	copy.texture = texture
	copy.centered = source.centered
	copy.offset = source.offset
	copy.flip_h = source.flip_h
	copy.flip_v = source.flip_v
	copy.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

func _update_outline(part: Dictionary, order: int) -> void:
	var actor: Node2D = part.actor
	var source: Node2D = part.source
	var id := actor.get_instance_id()
	var overlay := outlines.get(id) as Sprite2D
	if overlay == null:
		overlay = Sprite2D.new()
		overlay.name = "OccludedOutline"
		overlay.z_index = 2
		overlay.material = ShaderMaterial.new()
		overlay.material.shader = OUTLINE
		overlay.material.set_shader_parameter("occlusion_map", mask_view.get_texture())
		actor.add_child(overlay)
		outlines[id] = overlay
	_copy_sprite(overlay, source, part.texture)
	overlay.transform = source.transform
	overlay.modulate.a = source.modulate.a * source.self_modulate.a
	var texture: Texture2D = part.texture
	var uv := Rect2(Vector2.ZERO, Vector2.ONE)
	var sheet_size := texture.get_size()
	if texture is AtlasTexture:
		sheet_size = texture.atlas.get_size()
		uv = Rect2(texture.region.position / sheet_size, texture.region.size / sheet_size)
	var pixel_scale: float = minf(part.transform.x.length(), part.transform.y.length())
	var color := COLORS.fallback_color(COLORS.resolve_color_id(int(actor.get("team")), actor.get("match_state")))
	overlay.material.set_shader_parameter("outline_color", color.lightened(0.2))
	overlay.material.set_shader_parameter("mask_size", Vector2(mask_view.size))
	overlay.material.set_shader_parameter("unit_order", float(order))
	overlay.material.set_shader_parameter("frame_uv", Vector4(uv.position.x, uv.position.y, uv.end.x, uv.end.y))
	overlay.material.set_shader_parameter("outline_step", Vector2.ONE / sheet_size * maxf(1.0, 1.5 / maxf(pixel_scale, 0.01)))
	overlay.visible = true
