class_name PathBlocker
extends Node2D

## Rectangular authoring/broadphase footprint. Authored water uses a shared
## inset shoreline for rendering, pathfinding, collision and placement.

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const TerrainVisualScript := preload("res://scripts/presentation/terrain_visual.gd")
const ShoreGeometry := preload("res://scripts/world/shore_geometry.gd")

@export var sim_pos := Vector2.ZERO
@export var block_size := Vector2(2.0, 2.0)
@export var auto_block_size := true
@export var sheet_base := ""
@export var frame_index := 0
@export var kind := &"block"

var block_half := Vector2.ONE
var _selection: Line2D
var water_contours: Array[PackedVector2Array] = []
## Network terrain is immutable after the host supplies its actual coast. In
## particular, deferred editor-style refreshes must not replace a keyframe.
var water_contours_authoritative := false

func get_water_contours() -> Array[PackedVector2Array]:
	return water_contours

func freeze_water_contours() -> void:
	if kind != &"water" or auto_block_size: return
	water_contours = ShoreGeometry.quantize_contours(water_contours)
	water_contours_authoritative = true

func apply_authoritative_water_contours(contours: Array) -> void:
	if kind != &"water" or auto_block_size: return
	water_contours = ShoreGeometry.quantize_contours(contours)
	water_contours_authoritative = true
	if has_meta("lockstep_water_pending"): remove_meta("lockstep_water_pending")
	if not is_inside_tree(): return
	_refresh_water_visual()
	for holder in get_tree().get_nodes_in_group("nav_service"):
		if holder.get_parent().is_ancestor_of(self): holder.invalidate_static_geometry()

func _refresh_water_visual() -> void:
	for label in ["Billboard", "Body", "Fallback"]:
		var previous := get_node_or_null(label)
		if previous != null: previous.free()
	TerrainVisualScript.populate(self, kind, block_size, sim_pos)

func _exit_tree() -> void:
	if not _uses_generated_shore() or get_parent() == null: return
	for sibling in get_parent().get_children():
		if sibling != self and sibling is PathBlocker and sibling._uses_generated_shore():
			sibling._refresh_water_regions(self)
			sibling.call_deferred("_refresh_water_regions")
			break

func _refresh_water_regions(excluding: Node = null) -> void:
	if water_contours_authoritative or has_meta("lockstep_water_pending") or not is_inside_tree() or get_parent() == null: return
	var nodes: Array[PathBlocker] = []
	for sibling in get_parent().get_children():
		if sibling != excluding and sibling is PathBlocker and sibling.is_inside_tree() and sibling._uses_generated_shore() and not sibling.is_queued_for_deletion():
			nodes.append(sibling)
	var remaining := nodes.duplicate()
	while not remaining.is_empty():
		var component: Array[PathBlocker] = [remaining.pop_back()]
		var rects: Array[Rect2] = [Rect2(component[0].sim_pos - component[0].block_size * 0.5, component[0].block_size)]
		var index := 0
		while index < component.size():
			var base := Rect2(component[index].sim_pos - component[index].block_size * 0.5, component[index].block_size)
			for candidate in remaining.duplicate():
				var rect := Rect2(candidate.sim_pos - candidate.block_size * 0.5, candidate.block_size)
				if base.grow(0.0001).intersects(rect):
					component.append(candidate)
					rects.append(rect)
					remaining.erase(candidate)
			index += 1
		var contours := ShoreGeometry.build_contours(rects)
		for actor in component:
			if actor.water_contours == contours and actor.get_node_or_null("Billboard") != null: continue
			actor.water_contours = contours
			actor._refresh_water_visual()
	for holder in get_tree().get_nodes_in_group("nav_service"):
		if holder.get_parent().is_ancestor_of(self): holder.invalidate_static_geometry()

func _uses_generated_shore() -> bool:
	return kind == &"water" and not auto_block_size and not water_contours_authoritative and not has_meta("lockstep_water_pending")

func _ready() -> void:
	add_to_group("path_blockers")
	if sim_pos == Vector2.ZERO:
		sim_pos = IsoMathScript.screen_to_world(position)
	IsoMathScript.sync_node(self, sim_pos)
	if auto_block_size:
		_sync_block_size_from_sprite()
	block_half = block_size * 0.5
	if kind in [&"water", &"cliff"] and not auto_block_size:
		add_to_group("terrain_regions")
	_setup_visual()
	_setup_selection()

func set_selected(value: bool) -> void:
	if _selection != null:
		_selection.visible = value

func _setup_selection() -> void:
	_selection = Line2D.new()
	_selection.name = "SelectionFootprint"
	_selection.points = TerrainVisualScript.footprint(block_size)
	_selection.closed = true
	_selection.width = 2.0
	_selection.default_color = Color(1.0, 0.9, 0.35)
	_selection.z_index = 100
	_selection.visible = false
	add_child(_selection)

func _pixel_scale_for_sheet() -> float:
	match kind:
		&"water":
			return 2.4
		&"cliff":
			return 1.6
		_:
			return SpriteCatalogScript.RESOURCE_PIXEL_SCALE_2D

func _sync_block_size_from_sprite() -> void:
	if sheet_base.is_empty():
		return
	block_size = SpriteCatalogScript.pathfinding_footprint_for_sheet(
		sheet_base, _pixel_scale_for_sheet()
	)

func _setup_visual() -> void:
	# New map terrain specifies its footprint explicitly. Keep old auto-sized
	# SLP blockers / test arenas intact, including their generic fallback art.
	if kind in [&"water", &"cliff"] and not auto_block_size:
		# Replica creation precedes state restore. Building the host's shoreline
		# from each newly added neighbor would regenerate it many times.
		if kind == &"water" and has_meta("lockstep_water_pending"): return
		if kind == &"water" and water_contours_authoritative:
			_refresh_water_visual()
			return
		for label in ["Billboard", "Body", "Fallback"]:
			var previous := get_node_or_null(label)
			if previous != null: previous.free()
		water_contours = []
		if kind == &"water": _refresh_water_regions()
		else:
			TerrainVisualScript.populate(self, kind, block_size, sim_pos)
			_refresh_water_regions()
		if is_instance_valid(_selection):
			_selection.points = TerrainVisualScript.footprint(block_size)
		return
	var billboard := get_node_or_null("Billboard") as Sprite2D
	if billboard == null:
		billboard = Sprite2D.new()
		billboard.name = "Billboard"
		add_child(billboard)
	if not sheet_base.is_empty() and SpriteCatalogScript.sheet_paths_exist(sheet_base):
		var meta := SpriteCatalogScript.load_meta(sheet_base)
		var texture := SpriteCatalogScript.load_texture(sheet_base)
		if not meta.is_empty() and texture != null:
			billboard.texture = SpriteCatalogScript.atlas_frame_at(meta, texture, frame_index)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)
			SpriteCatalogScript.configure_sprite_2d(
				billboard, _pixel_scale_for_sheet(), offset
			)
			billboard.visible = true
			SpriteCatalogScript.ensure_ground_shadow_2d(
				self, maxf(block_size.x, block_size.y) * 6.0
			)
			return
	billboard.visible = false
	var marker := get_node_or_null("Fallback") as Polygon2D
	if marker == null:
		marker = Polygon2D.new()
		marker.name = "Fallback"
		add_child(marker)
	var rx := block_size.x * IsoMathScript.SCALE_X * 0.45
	var ry := block_size.y * IsoMathScript.SCALE_Y * 0.45
	marker.polygon = PackedVector2Array([
		Vector2(0, -ry), Vector2(rx, 0), Vector2(0, ry), Vector2(-rx, 0)
	])
	match kind:
		&"water":
			marker.color = Color(0.2, 0.45, 0.85, 0.65)
		&"cliff":
			marker.color = Color(0.45, 0.38, 0.28, 0.8)
		&"ore":
			marker.color = Color(0.92, 0.72, 0.12, 0.75)
		_:
			marker.color = Color(0.55, 0.4, 0.25, 0.75)
	marker.visible = true
