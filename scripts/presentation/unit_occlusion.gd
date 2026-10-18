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
const STATIC_GROUPS := [&"buildings", &"resource_nodes", &"path_blockers", &"occlusion_memories"]
const SPATIAL_CELL_PIXELS := 256.0
var last_update_usec := 0
var static_candidates := 0
var static_registered := 0
var mask_redraws := 0
var _static_actors: Dictionary = {}
var _static_sources: Dictionary = {}
var _dynamic_actors: Dictionary = {}
var _spatial_cells: Dictionary = {}
var _unindexed_sources: Dictionary = {}
var _dirty_sources: Dictionary = {}
var _queued_nodes: Dictionary = {}
var _copy_pool: Dictionary = {}
var _copy_orders: Dictionary = {}
var _outline_params: Dictionary = {}
var _composition_invalid := true
var _pending_mask_frames := 0
var _polygon_sources: Dictionary = {}
var _white_texture: ImageTexture

## Static sprites do not process every frame. This child receives inherited
## transform notifications, including when an actor/ancestor moves or scales.
class TransformTracker extends Node2D:
	var owner_ref: WeakRef
	var source_id := 0
	func _ready() -> void:
		set_notify_transform(true)
	func _notification(what: int) -> void:
		if what == NOTIFICATION_TRANSFORM_CHANGED and owner_ref != null:
			var renderer: Node = owner_ref.get_ref()
			if renderer != null:
				renderer._mark_source_dirty(source_id)

static func ensure_for(unit: Node) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var viewport := unit.get_viewport()
	if viewport.has_meta(KEY) and is_instance_valid(viewport.get_meta(KEY)):
		return
	var renderer := load("res://scripts/presentation/unit_occlusion.gd").new() as Node
	viewport.set_meta(KEY, renderer)
	viewport.add_child.call_deferred(renderer)


static func notify_static_entity(actor: Node) -> void:
	# A placement preview joins the buildings group after its node_added event.
	# Register that transition once, without rescanning buildings every frame.
	if not actor.is_inside_tree():
		return
	var viewport := actor.get_viewport()
	if not viewport.has_meta(KEY):
		return
	var renderer: Node = viewport.get_meta(KEY)
	if is_instance_valid(renderer):
		renderer._queue_node(actor)

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
	get_tree().node_added.connect(_queue_node)
	get_tree().node_removed.connect(_remove_node)
	for group in STATIC_GROUPS:
		for actor in get_tree().get_nodes_in_group(group): _register_static_actor(actor)
	for actor in get_tree().get_nodes_in_group("units"):
		if actor is Node2D and actor.get_viewport() == get_viewport():
			_dynamic_actors[actor.get_instance_id()] = actor

func _process(_delta: float) -> void:
	update_mask()

func _exit_tree() -> void:
	for overlay in outlines.values():
		if is_instance_valid(overlay):
			overlay.queue_free()

func _queue_node(node: Node) -> void:
	# node_added can precede the node's cached viewport/group initialization.
	# Check its final viewport when draining this queue after _ready completes.
	if node is Node2D and not node is TransformTracker:
		_queued_nodes[node.get_instance_id()] = weakref(node)

func _is_static_actor(node: Node) -> bool:
	for group in STATIC_GROUPS:
		if node.is_in_group(group): return true
	return false

func _register_static_actor(actor: Node) -> void:
	if actor is not Node2D or actor.get_viewport() != get_viewport(): return
	var actor_id := actor.get_instance_id()
	if not _static_actors.has(actor_id): _static_actors[actor_id] = []
	for source in actor.get_children():
		if (source is Sprite2D or source is Polygon2D) and source.name != &"GroundShadow":
			_register_static_source(actor, source)
		elif source.name == &"FortificationVisual":
			for sprite in source.get_children():
				if sprite is Sprite2D: _register_static_source(actor, sprite)

func _register_static_source(actor: Node2D, source: Node2D) -> void:
	var id := source.get_instance_id()
	if _static_sources.has(id): return
	_static_sources[id] = {"actor":actor, "source":source, "cells":[]}
	_static_actors[actor.get_instance_id()].append(id)
	source.item_rect_changed.connect(_mark_source_dirty.bind(id))
	if source is Sprite2D:
		source.texture_changed.connect(_mark_source_dirty.bind(id))
	else:
		# Polygon2D has no texture_changed signal. Geometry polling is confined
		# to the few terrain polygons; the thousands of static sprites stay cached.
		_polygon_sources[id] = [source.polygon, source.offset, source.invert_enabled, source.invert_border]
	var tracker := TransformTracker.new()
	tracker.name = "OcclusionTransformTracker"
	tracker.owner_ref = weakref(self)
	tracker.source_id = id
	source.add_child(tracker)
	_mark_source_dirty(id)

func _mark_source_dirty(id: int) -> void:
	if _static_sources.has(id): _dirty_sources[id] = true

func _remove_node(node: Node) -> void:
	var id := node.get_instance_id()
	_queued_nodes.erase(id)
	if _static_sources.has(id): _remove_static_source(id)
	if _static_actors.has(id):
		for source_id in _static_actors[id].duplicate(): _remove_static_source(source_id)
		_static_actors.erase(id)
	if _dynamic_actors.has(id):
		_dynamic_actors.erase(id)
		if outlines.has(id):
			if is_instance_valid(outlines[id]): outlines[id].queue_free()
			outlines.erase(id)
		_outline_params.erase(id)
		for name in [&"Billboard", &"Body"]:
			var source := node.get_node_or_null(NodePath(name))
			if source != null: _release_copy(source.get_instance_id())
	_release_copy(id)

func _release_copy(id: int) -> void:
	if _copy_pool.has(id):
		if is_instance_valid(_copy_pool[id]): _copy_pool[id].free()
		_copy_pool.erase(id)
		copies.erase(id)
		_copy_orders.erase(id)
		_composition_invalid = true

func _remove_static_source(id: int) -> void:
	if not _static_sources.has(id): return
	_remove_source_cells(id)
	_static_sources.erase(id)
	_polygon_sources.erase(id)
	_unindexed_sources.erase(id)
	_dirty_sources.erase(id)
	_release_copy(id)

func _remove_source_cells(id: int) -> void:
	for cell in _static_sources[id].cells:
		if _spatial_cells.has(cell):
			_spatial_cells[cell].erase(id)
			if _spatial_cells[cell].is_empty(): _spatial_cells.erase(cell)
	_static_sources[id].cells = []

func _refresh_source(id: int) -> void:
	var record: Dictionary = _static_sources[id]
	var source: Node2D = record.source
	if not is_instance_valid(source):
		_remove_static_source(id)
		return
	_remove_source_cells(id)
	_unindexed_sources.erase(id)
	var bounds := _source_bounds(source)
	if not bounds.has_area(): return
	# A CanvasLayer has its own camera transform; keep rare layer actors in the
	# direct candidate set instead of incorrectly indexing them in world space.
	var ancestor: Node = source
	while ancestor != get_viewport() and ancestor != null:
		if ancestor is CanvasLayer:
			_unindexed_sources[id] = true
			return
		ancestor = ancestor.get_parent()
	var world_bounds: Rect2 = source.get_global_transform() * bounds
	var first := Vector2i((world_bounds.position / SPATIAL_CELL_PIXELS).floor())
	var last := Vector2i((world_bounds.end / SPATIAL_CELL_PIXELS).floor())
	for x in range(first.x, last.x + 1):
		for y in range(first.y, last.y + 1):
			var cell := Vector2i(x, y)
			if not _spatial_cells.has(cell): _spatial_cells[cell] = {}
			_spatial_cells[cell][id] = true
			record.cells.append(cell)

func _refresh_registry() -> void:
	var queued := _queued_nodes.values()
	_queued_nodes.clear()
	for reference: WeakRef in queued:
		var node: Node = reference.get_ref()
		if node == null or not node.is_inside_tree() or node.get_viewport() != get_viewport(): continue
		if node.is_in_group("units"):
			_dynamic_actors[node.get_instance_id()] = node
		if _is_static_actor(node): _register_static_actor(node)
		elif (node is Sprite2D or node is Polygon2D) and node.get_parent() is Node2D and _is_static_actor(node.get_parent()):
			_register_static_actor(node.get_parent())
	for id in _polygon_sources:
		var polygon: Polygon2D = _static_sources[id].source
		var geometry := [polygon.polygon, polygon.offset, polygon.invert_enabled, polygon.invert_border]
		if geometry != _polygon_sources[id]:
			_polygon_sources[id] = geometry
			_mark_source_dirty(id)
	var changed := _dirty_sources.keys()
	_dirty_sources.clear()
	for id in changed:
		if _static_sources.has(id): _refresh_source(id)
	static_registered = _static_sources.size()

func _query_static_sources(screen: Rect2) -> Array:
	var world_rect: Rect2 = get_viewport().get_canvas_transform().affine_inverse() * screen
	var first := Vector2i((world_rect.position / SPATIAL_CELL_PIXELS).floor())
	var last := Vector2i((world_rect.end / SPATIAL_CELL_PIXELS).floor())
	var found := _unindexed_sources.duplicate()
	for x in range(first.x, last.x + 1):
		for y in range(first.y, last.y + 1):
			var cell := Vector2i(x, y)
			if _spatial_cells.has(cell): found.merge(_spatial_cells[cell])
	static_candidates = found.size()
	return found.keys()

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

static func _source_bounds(source: Node2D, texture: Texture2D = null) -> Rect2:
	if source is Polygon2D:
		if source.polygon.size() < 3: return Rect2()
		var bounds := Rect2(source.polygon[0] + source.offset, Vector2.ZERO)
		for point in source.polygon: bounds = bounds.expand(point + source.offset)
		if source.invert_enabled: bounds = bounds.grow(source.invert_border)
		return bounds
	if texture == null and source is Sprite2D: texture = source.texture
	if texture == null: return Rect2()
	var bounds := Rect2(source.offset, texture.get_size())
	if source.centered: bounds.position -= bounds.size * 0.5
	return bounds

func _opaque_texture() -> ImageTexture:
	if _white_texture == null:
		var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		white.fill(Color.WHITE)
		_white_texture = ImageTexture.create_from_image(white)
	return _white_texture

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
	elif source is Polygon2D:
		texture = source.texture if source.texture != null else _opaque_texture()
	else:
		return {}
	if texture == null:
		return {}
	var transform := source.get_global_transform_with_canvas()
	var bounds := _source_bounds(source, texture)
	if not screen.intersects(transform * bounds):
		return {}
	return {"actor": actor, "source": source, "texture": texture, "transform": transform,
		"dynamic": dynamic, "z": _effective_z(source), "y": source.global_position.y}

func update_mask() -> void:
	var started := Time.get_ticks_usec()
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
		_composition_invalid = true
	var screen := Rect2(Vector2.ZERO, Vector2(size))
	_refresh_registry()
	var parts: Array[Dictionary] = []
	var alive_outlines: Dictionary = {}
	var shown_outlines: Dictionary = {}
	var static_count := 0
	for actor in _dynamic_actors.values():
		if actor is not Node2D or actor.get_viewport() != get_viewport():
			continue
		var id: int = actor.get_instance_id()
		alive_outlines[id] = true
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
	# A viewport without a visible unit needs neither static queries nor a mask.
	var visible_units := parts.size()
	static_candidates = 0
	if visible_units > 0:
		for id in _query_static_sources(screen):
			var record: Dictionary = _static_sources[id]
			var actor: Node2D = record.actor
			var source: Node2D = record.source
			if not _is_static_actor(actor) or not _visible(actor) or actor.get("is_placement_ghost") == true or _effective_z(source) < 0: continue
			var part := _part(actor, source, false, screen)
			if not part.is_empty():
				parts.append(part)
				static_count += 1
	for id in outlines.keys():
		if not alive_outlines.has(id):
			if is_instance_valid(outlines[id]):
				outlines[id].queue_free()
			outlines.erase(id)
	parts.sort_custom(_before)
	var alive_copies: Dictionary = {}
	var composition_changed := _composition_invalid
	_composition_invalid = false
	var order := 0
	for part in parts:
		order += 1
		var source: Node2D = part.source
		var id := source.get_instance_id()
		alive_copies[id] = true
		var copy := _copy_pool.get(id) as Node2D
		if copy == null:
			copy = Polygon2D.new() if source is Polygon2D else Sprite2D.new()
			copy.material = ShaderMaterial.new()
			copy.material.shader = DEPTH
			mask_view.add_child(copy)
			_copy_pool[id] = copy
			composition_changed = true
		copies[id] = copy
		if not copy.visible:
			copy.show()
			composition_changed = true
		if source is Polygon2D:
			composition_changed = _copy_polygon(copy, source, part.texture) or composition_changed
		else:
			composition_changed = _copy_sprite(copy, source, part.texture) or composition_changed
		var transform: Transform2D = stretch * part.transform
		if copy.transform != transform:
			copy.transform = transform
			composition_changed = true
		var opacity: float = source.modulate.a * source.self_modulate.a * part.actor.modulate.a
		if not is_equal_approx(copy.modulate.a, opacity):
			copy.modulate.a = opacity
			composition_changed = true
		var rank := 0 if part.dynamic else order
		if _copy_orders.get(id, -1) != rank:
			copy.material.set_shader_parameter("drawing_order", Vector2(rank % 256, rank / 256) / 255.0)
			_copy_orders[id] = rank
			composition_changed = true
		if copy.get_index() != order - 1:
			mask_view.move_child(copy, order - 1)
			composition_changed = true
		if part.dynamic and static_count > 0:
			_update_outline(part, order)
			shown_outlines[part.actor.get_instance_id()] = true
	for id in outlines:
		if not shown_outlines.has(id) and is_instance_valid(outlines[id]) and outlines[id].visible:
			outlines[id].hide()
	for id in copies.keys():
		if not alive_copies.has(id):
			copies[id].hide()
			copies.erase(id)
			composition_changed = true
	# CanvasItem child order and a newly created atlas copy can reach the GL draw
	# list one frame after their uniforms. Render a second settling frame before
	# keeping the mask, otherwise same-Y reorder/new foreground units use old depth.
	if composition_changed: _pending_mask_frames = 2
	var should_draw := static_count > 0 and visible_units > 0 and _pending_mask_frames > 0
	mask_view.render_target_update_mode = SubViewport.UPDATE_ONCE if should_draw else SubViewport.UPDATE_DISABLED
	if should_draw:
		mask_redraws += 1
		_pending_mask_frames -= 1
	last_update_usec = Time.get_ticks_usec() - started

static func _copy_sprite(copy: Sprite2D, source: Node2D, texture: Texture2D) -> bool:
	var changed := false
	if copy.texture != texture:
		copy.texture = texture
		changed = true
	if copy.centered != source.centered:
		copy.centered = source.centered
		changed = true
	if copy.offset != source.offset:
		copy.offset = source.offset
		changed = true
	if copy.flip_h != source.flip_h:
		copy.flip_h = source.flip_h
		changed = true
	if copy.flip_v != source.flip_v:
		copy.flip_v = source.flip_v
		changed = true
	if copy.texture_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
		copy.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		changed = true
	return changed

static func _copy_polygon(copy: Polygon2D, source: Polygon2D, texture: Texture2D) -> bool:
	var changed := false
	for property in [&"polygon", &"offset", &"uv", &"polygons", &"vertex_colors", &"color",
		&"texture_scale", &"texture_offset", &"texture_rotation", &"texture_filter", &"texture_repeat",
		&"invert_enabled", &"invert_border", &"antialiased"]:
		var value: Variant = source.get(property)
		if copy.get(property) != value:
			copy.set(property, value)
			changed = true
	if copy.texture != texture:
		copy.texture = texture
		changed = true
	return changed

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
	if overlay.transform != source.transform: overlay.transform = source.transform
	var opacity: float = source.modulate.a * source.self_modulate.a
	if not is_equal_approx(overlay.modulate.a, opacity): overlay.modulate.a = opacity
	var texture: Texture2D = part.texture
	var uv := Rect2(Vector2.ZERO, Vector2.ONE)
	var sheet_size := texture.get_size()
	if texture is AtlasTexture:
		sheet_size = texture.atlas.get_size()
		uv = Rect2(texture.region.position / sheet_size, texture.region.size / sheet_size)
	var pixel_scale: float = minf(part.transform.x.length(), part.transform.y.length())
	var color := COLORS.fallback_color(COLORS.resolve_color_id(int(actor.get("team")), actor.get("match_state")))
	if not _outline_params.has(id): _outline_params[id] = {}
	var parameters := {"outline_color": color.lightened(0.2), "mask_size": Vector2(mask_view.size),
		"unit_order":float(order), "frame_uv":Vector4(uv.position.x, uv.position.y, uv.end.x, uv.end.y),
		"outline_step":Vector2.ONE / sheet_size * maxf(1.0, 1.5 / maxf(pixel_scale, 0.01))}
	for key in parameters:
		if _outline_params[id].get(key) != parameters[key]:
			overlay.material.set_shader_parameter(key, parameters[key])
			_outline_params[id][key] = parameters[key]
	if not overlay.visible: overlay.show()
