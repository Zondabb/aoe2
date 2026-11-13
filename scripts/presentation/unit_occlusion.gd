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
const FOCUS_MARGIN_PIXELS := 16.0
var _static_geometry_revision := 0
var _focus_revision := -1
var _focus_canvas := Transform2D.IDENTITY
var _focus_envelopes: Dictionary = {}
var _focus_sources: Array = []

## Typed fields keep the per-frame merge/sort/copy loop out of Variant-backed
## dictionaries. Their values still come from the same source sprite state.
class DrawPart extends RefCounted:
	var actor: Node2D
	var source: Node2D
	var texture: Texture2D
	var transform := Transform2D.IDENTITY
	var dynamic := false
	var needs_outline := false
	var z := 0
	var y := 0.0
	var screen_bounds := Rect2()
	func _init(owner_actor: Node2D, sprite: Node2D, image: Texture2D, xform: Transform2D, moving: bool, depth: int, world_y: float, bounds := Rect2()) -> void:
		actor = owner_actor
		source = sprite
		texture = image
		transform = xform
		dynamic = moving
		z = depth
		y = world_y
		screen_bounds = bounds

class OutlineParameters extends RefCounted:
	var outline_color := Color(-1, -1, -1, -1)
	var mask_size := Vector2(-1, -1)
	var unit_order := -1
	var frame_uv := Vector4(-1, -1, -1, -1)
	var outline_step := Vector2(-1, -1)

## Static sprites do not process every frame. This child receives inherited
## transform notifications, including when an actor/ancestor moves or scales.
class TransformTracker extends Node2D:
	var owner_ref: WeakRef
	var source_id := 0
	func _ready() -> void:
		set_notify_transform(true)
		get_global_transform()
	func _notification(what: int) -> void:
		if what == NOTIFICATION_TRANSFORM_CHANGED and owner_ref != null:
			# Consume the invalid global transform so a later ancestor move can
			# invalidate it again. This tracker has no drawing that would do so.
			get_global_transform()
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
	# Copies receive an already interpolated screen transform every draw frame.
	mask_view.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
		_polygon_sources[id] = [source.polygon, source.offset, source.invert_enabled, source.invert_border, source.texture]
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
	_static_geometry_revision += 1
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
	_static_geometry_revision += 1
	var record: Dictionary = _static_sources[id]
	var source: Node2D = record.source
	if not is_instance_valid(source):
		_remove_static_source(id)
		return
	_remove_source_cells(id)
	_unindexed_sources.erase(id)
	var bounds := _source_bounds(source)
	record.bounds = bounds
	record.world_bounds = Rect2()
	if not bounds.has_area(): return
	record.world_transform = source.get_global_transform()
	record.world_bounds = record.world_transform * bounds
	record.texture = source.texture if source.texture != null else _opaque_texture()
	# A CanvasLayer has its own camera transform; keep rare layer actors in the
	# direct candidate set instead of incorrectly indexing them in world space.
	var ancestor: Node = source
	while ancestor != get_viewport() and ancestor != null:
		if ancestor is CanvasLayer:
			_unindexed_sources[id] = true
			return
		ancestor = ancestor.get_parent()
	var world_bounds: Rect2 = record.world_bounds
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
		var geometry := [polygon.polygon, polygon.offset, polygon.invert_enabled, polygon.invert_border, polygon.texture]
		if geometry != _polygon_sources[id]:
			_polygon_sources[id] = geometry
			_mark_source_dirty(id)
	var changed := _dirty_sources.keys()
	_dirty_sources.clear()
	for id in changed:
		if _static_sources.has(id): _refresh_source(id)
	static_registered = _static_sources.size()

func _query_static_sources(screen: Rect2, unit_bounds: Array[Rect2] = []) -> Array:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var regions: Array[Rect2] = unit_bounds if not unit_bounds.is_empty() else [screen]
	var found := _unindexed_sources.duplicate()
	var visited := {}
	for region in regions:
		var world_rect: Rect2 = inverse * region
		var first := Vector2i((world_rect.position / SPATIAL_CELL_PIXELS).floor())
		var last := Vector2i((world_rect.end / SPATIAL_CELL_PIXELS).floor())
		for x in range(first.x, last.x + 1):
			for y in range(first.y, last.y + 1):
				var cell := Vector2i(x, y)
				if visited.has(cell): continue
				visited[cell] = true
				if _spatial_cells.has(cell): found.merge(_spatial_cells[cell])
	static_candidates = found.size()
	return found.keys()

static func _overlaps_units(bounds: Rect2, buckets: Dictionary) -> bool:
	var first := Vector2i((bounds.position / SPATIAL_CELL_PIXELS).floor())
	var last := Vector2i((bounds.end / SPATIAL_CELL_PIXELS).floor())
	for x in range(first.x, last.x + 1):
		for y in range(first.y, last.y + 1):
			for unit_rect: Rect2 in buckets.get(Vector2i(x, y), []):
				if bounds.intersects(unit_rect): return true
	return false

static func _rect_buckets(regions: Array[Rect2]) -> Dictionary:
	var buckets := {}
	for bounds in regions:
		var first := Vector2i((bounds.position / SPATIAL_CELL_PIXELS).floor())
		var last := Vector2i((bounds.end / SPATIAL_CELL_PIXELS).floor())
		for x in range(first.x, last.x + 1):
			for y in range(first.y, last.y + 1):
				var cell := Vector2i(x, y)
				if not buckets.has(cell): buckets[cell] = []
				buckets[cell].append(bounds)
	return buckets

func _focused_static_sources(screen: Rect2, unit_parts: Array[DrawPart]) -> Array:
	var canvas := get_viewport().get_canvas_transform()
	var reuse := _focus_revision == _static_geometry_revision and _focus_canvas == canvas and _focus_envelopes.size() == unit_parts.size()
	if reuse:
		for part in unit_parts:
			var id := part.source.get_instance_id()
			if not _focus_envelopes.has(id) or not (_focus_envelopes[id] as Rect2).encloses(part.screen_bounds):
				reuse = false
				break
	if reuse:
		static_candidates = _focus_sources.size()
		return _focus_sources
	# These envelopes are a conservative broad phase, not stale render data.
	# Exact overlap, visibility, depth and all moving transforms are still read
	# every frame. Rebuild as soon as any unit leaves its envelope or static
	# geometry/camera changes; no refresh interval or visual precision changes.
	_focus_revision = _static_geometry_revision
	_focus_canvas = canvas
	_focus_envelopes.clear()
	var regions: Array[Rect2] = []
	for part in unit_parts:
		var envelope := part.screen_bounds.grow(FOCUS_MARGIN_PIXELS)
		_focus_envelopes[part.source.get_instance_id()] = envelope
		regions.append(envelope)
	var buckets := _rect_buckets(regions)
	_focus_sources = []
	for id in _query_static_sources(screen, regions):
		var record: Dictionary = _static_sources[id]
		if _unindexed_sources.has(id) or (record.has("world_bounds") and _overlaps_units(canvas * record.world_bounds, buckets)):
			_focus_sources.append(id)
	static_candidates = _focus_sources.size()
	return _focus_sources

func _visible(node: CanvasItem) -> bool:
	return node.get_viewport() == get_viewport() and node.is_visible_in_tree() and node.modulate.a > 0.01

static func _effective_z(item: CanvasItem) -> int:
	var value := item.z_index
	while item.z_as_relative and item.get_parent() is CanvasItem:
		item = item.get_parent() as CanvasItem
		value += item.z_index
	return value

static func _before(a: DrawPart, b: DrawPart) -> bool:
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

func _part(actor: Node2D, source: Node2D, dynamic: bool, screen: Rect2) -> DrawPart:
	if not _visible(source):
		return null
	var texture: Texture2D
	if source is AnimatedSprite2D:
		if source.sprite_frames == null or not source.sprite_frames.has_animation(source.animation):
			return null
		texture = source.sprite_frames.get_frame_texture(source.animation, source.frame)
	elif source is Sprite2D:
		texture = source.texture
	elif source is Polygon2D:
		texture = source.texture if source.texture != null else _opaque_texture()
	else:
		return null
	if texture == null:
		return null
	var transform := source.get_global_transform_with_canvas()
	if dynamic and actor.has_method("render_canvas_transform"):
		transform = actor.render_canvas_transform(source)
	var bounds := _source_bounds(source, texture)
	if not screen.intersects(transform * bounds):
		return null
	var world_y := source.global_position.y
	if dynamic and actor.has_method("render_global_transform"):
		world_y = actor.render_global_transform(source).origin.y
	return DrawPart.new(actor, source, texture, transform, dynamic, _effective_z(source), world_y, transform * bounds)

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
	var parts: Array[DrawPart] = []
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
			if part != null:
				parts.append(part)
				break
	# A viewport without a visible unit needs neither static queries nor a mask.
	var visible_units := parts.size()
	var unit_bounds: Array[Rect2] = []
	for part in parts:
		unit_bounds.append(part.screen_bounds)
	var unit_buckets := _rect_buckets(unit_bounds)
	static_candidates = 0
	if visible_units > 0:
		var actor_states := {}
		var canvas := get_viewport().get_canvas_transform()
		for id in _focused_static_sources(screen, parts):
			var record: Dictionary = _static_sources[id]
			if not record.has("world_bounds") or not record.world_bounds.has_area(): continue
			# Global-transform notifications can be deferred until the transform
			# is requested. Refresh moved candidates before rejecting their cache.
			if record.source.get_global_transform() != record.world_transform:
				_refresh_source(id)
			var source_canvas: Transform2D = record.source.get_canvas_transform() if _unindexed_sources.has(id) else canvas
			# Only pixels inside a visible unit can produce an outline. Static
			# silhouettes elsewhere cannot change the result, including foreground
			# units clearing depth; omit their copies and repeated property reads.
			if not _overlaps_units(source_canvas * record.world_bounds, unit_buckets): continue
			var actor: Node2D = record.actor
			var source: Node2D = record.source
			var actor_id := actor.get_instance_id()
			if not actor_states.has(actor_id):
				actor_states[actor_id] = _is_static_actor(actor) and _visible(actor) and actor.get("is_placement_ghost") != true
			if not actor_states[actor_id] or not _visible(source): continue
			var z := _effective_z(source)
			if z < 0: continue
			var transform: Transform2D = source_canvas * record.world_transform
			var bounds: Rect2 = transform * record.bounds
			if not _overlaps_units(bounds, unit_buckets): continue
			parts.append(DrawPart.new(actor, source, record.texture, transform, false, z, record.world_transform.origin.y, bounds))
			static_count += 1
	# A unit outside every retained static silhouette cannot be occluded and
	# cannot clear depth for another unit beneath one. Keep all intersecting
	# foreground units in the mask, but create an outline only where a later
	# static in the exact Z/Y/tree order can cover that unit.
	var static_buckets := {}
	for part in parts:
		if part.dynamic: continue
		var bounds := part.screen_bounds
		var first := Vector2i((bounds.position / SPATIAL_CELL_PIXELS).floor())
		var last := Vector2i((bounds.end / SPATIAL_CELL_PIXELS).floor())
		for x in range(first.x, last.x + 1):
			for y in range(first.y, last.y + 1):
				var cell := Vector2i(x, y)
				if not static_buckets.has(cell): static_buckets[cell] = []
				static_buckets[cell].append(part)
	var relevant_parts: Array[DrawPart] = []
	for part in parts:
		if not part.dynamic:
			relevant_parts.append(part)
			continue
		var intersects_static := false
		var bounds := part.screen_bounds
		var first := Vector2i((bounds.position / SPATIAL_CELL_PIXELS).floor())
		var last := Vector2i((bounds.end / SPATIAL_CELL_PIXELS).floor())
		for x in range(first.x, last.x + 1):
			for y in range(first.y, last.y + 1):
				for occluder: DrawPart in static_buckets.get(Vector2i(x, y), []):
					if not bounds.intersects(occluder.screen_bounds): continue
					intersects_static = true
					part.needs_outline = part.needs_outline or _before(part, occluder)
		if intersects_static: relevant_parts.append(part)
	parts = relevant_parts
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
			copy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
		if part.dynamic and part.needs_outline:
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

func _update_outline(part: DrawPart, order: int) -> void:
	var actor: Node2D = part.actor
	var source: Node2D = part.source
	var id := actor.get_instance_id()
	var overlay := outlines.get(id) as Sprite2D
	if overlay == null:
		overlay = Sprite2D.new()
		overlay.name = "OccludedOutline"
		# Its parent supplies the actor interpolation; this local copy is updated
		# in _process and must not acquire a second interpolation delay.
		overlay.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
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
	var parameters: OutlineParameters = _outline_params.get(id)
	if parameters == null:
		parameters = OutlineParameters.new()
		_outline_params[id] = parameters
	var outline_color := color.lightened(0.2)
	if parameters.outline_color != outline_color:
		overlay.material.set_shader_parameter(&"outline_color", outline_color)
		parameters.outline_color = outline_color
	var mask_size := Vector2(mask_view.size)
	if parameters.mask_size != mask_size:
		overlay.material.set_shader_parameter(&"mask_size", mask_size)
		parameters.mask_size = mask_size
	if parameters.unit_order != order:
		overlay.material.set_shader_parameter(&"unit_order", float(order))
		parameters.unit_order = order
	var frame_uv := Vector4(uv.position.x, uv.position.y, uv.end.x, uv.end.y)
	if parameters.frame_uv != frame_uv:
		overlay.material.set_shader_parameter(&"frame_uv", frame_uv)
		parameters.frame_uv = frame_uv
	var outline_step := Vector2.ONE / sheet_size * maxf(1.0, 1.5 / maxf(pixel_scale, 0.01))
	if parameters.outline_step != outline_step:
		overlay.material.set_shader_parameter(&"outline_step", outline_step)
		parameters.outline_step = outline_step
	if not overlay.visible: overlay.show()
