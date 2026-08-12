class_name ResourceNode
extends Node2D

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

@export var resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
@export var amount := 100.0
@export var gather_rate := 4.0

var sim_pos := Vector2.ZERO
var _use_billboard := false
var block_half := Vector2.ONE

static func resource_blocks_pathfinding(type: Enums.ResourceType) -> bool:
	match type:
		Enums.ResourceType.FOOD:
			return false
		Enums.ResourceType.WOOD, Enums.ResourceType.GOLD:
			return true
		_:
			return true

static func pathfinding_footprint(type: Enums.ResourceType) -> Vector2:
	if not resource_blocks_pathfinding(type):
		return Vector2.ZERO
	var base := SpriteCatalogScript.resource_sheet_base(type)
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		if not meta.is_empty():
			return SpriteCatalogScript.pathfinding_footprint_from_meta(meta)
	match type:
		Enums.ResourceType.WOOD:
			return Vector2(1.2, 1.2)
		Enums.ResourceType.GOLD:
			return Vector2(8.0, 8.0)
		_:
			return Vector2.ZERO

static func edge_distance(from: Vector2, center: Vector2, type: Enums.ResourceType) -> float:
	var footprint := pathfinding_footprint(type)
	if footprint.length_squared() <= 0.0:
		return from.distance_to(center)
	var half := footprint * 0.5
	var delta := from - center
	var nearest := center + Vector2(
		clampf(delta.x, -half.x, half.x),
		clampf(delta.y, -half.y, half.y)
	)
	return from.distance_to(nearest)

func approach_point(from: Vector2, unit_radius: float = 0.35) -> Vector2:
	var footprint := pathfinding_footprint(resource_type)
	if footprint.length_squared() <= 0.0:
		return sim_pos
	var half := footprint * 0.5
	var to_unit := from - sim_pos
	if to_unit.length_squared() <= 0.0001:
		to_unit = Vector2(1.0, 0.0)
	else:
		to_unit = to_unit.normalized()
	var stand_radius := maxf(half.x, half.y) + unit_radius + 0.05
	return sim_pos + to_unit * stand_radius

func _ready() -> void:
	add_to_group("resource_nodes")
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	IsoMathScript.sync_node(self, sim_pos)
	block_half = pathfinding_footprint(resource_type) * 0.5
	_setup_presentation()

func extract(delta: float) -> float:
	if delta <= 0.0 or amount <= 0.0 or gather_rate <= 0.0:
		return 0.0
	var extracted := minf(amount, gather_rate * delta)
	amount -= extracted
	if is_zero_approx(amount):
		amount = 0.0
		visible = false
		_release_nav_grid_if_depleted()
	return extracted

func _release_nav_grid_if_depleted() -> void:
	if amount > 0.0:
		return
	if not resource_blocks_pathfinding(resource_type):
		return
	if not is_inside_tree():
		return
	var grid := get_tree().get_first_node_in_group("nav_grid")
	if grid != null and grid.has_method("mark_resource"):
		grid.call("mark_resource", self, false)

func _setup_presentation() -> void:
	var existing_billboard := get_node_or_null("Billboard") as Sprite2D
	var existing_marker := get_node_or_null("Marker") as CanvasItem
	var base := SpriteCatalogScript.resource_sheet_base(resource_type)
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			var billboard := existing_billboard
			if billboard == null:
				billboard = Sprite2D.new()
				billboard.name = "Billboard"
				add_child(billboard)
			billboard.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)
			SpriteCatalogScript.configure_sprite_2d(
				billboard, SpriteCatalogScript.RESOURCE_PIXEL_SCALE_2D, offset
			)
			billboard.visible = true
			_use_billboard = true
			SpriteCatalogScript.ensure_ground_shadow_2d(self, 16.0)
			if existing_marker != null:
				existing_marker.visible = false
			return
	if existing_billboard != null:
		existing_billboard.visible = false
	if existing_marker != null:
		existing_marker.visible = true
