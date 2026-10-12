class_name PathBlocker
extends Node2D

## Square logical blocker used by pathfinding (and collision). Visual comes from
## exported AoE2 terrain / resource sheets when available.

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const TerrainVisualScript := preload("res://scripts/presentation/terrain_visual.gd")

@export var sim_pos := Vector2.ZERO
@export var block_size := Vector2(2.0, 2.0)
@export var auto_block_size := true
@export var sheet_base := ""
@export var frame_index := 0
@export var kind := &"block"

var block_half := Vector2.ONE
var _selection: Line2D

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
		for label in ["Billboard", "Body", "Fallback"]:
			var previous := get_node_or_null(label)
			if previous != null: previous.free()
		TerrainVisualScript.populate(self, kind, block_size, sim_pos)
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
