class_name ResourceNode
extends Node2D

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const TreeVariants := preload("res://scripts/presentation/tree_variants.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")

## Counts every change of any resource's position, type or size override:
## the fog/minimap caches reuse their per-record geometry while it is unchanged.
static var geometry_revision := 0
@export var resource_type: Enums.ResourceType = Enums.ResourceType.FOOD:
	set(value):
		resource_type = value
		geometry_revision += 1
var amount_q: int = 100 * Fixed.SCALE
var gather_rate_q: int = 4 * Fixed.SCALE
var _gather_remainder: int = 0
@export var amount: float = 100.0:
	get: return float(amount_q) / Fixed.SCALE
	set(value): amount_q = maxi(0, roundi(value * Fixed.SCALE))
@export var gather_rate: float = 4.0:
	get: return float(gather_rate_q) / Fixed.SCALE
	set(value): gather_rate_q = maxi(0, roundi(value * Fixed.SCALE))
## Generated forests reserve one converted terrain tile per tree. Old maps keep
## their existing playable footprints unless a size is explicitly supplied.
@export var block_size_override := Vector2.ZERO:
	set(value):
		block_size_override = value
		geometry_revision += 1
var block_size: Vector2:
	get: return selection_footprint(resource_type) if resource_type == Enums.ResourceType.FOOD else pathfinding_size()

var sim_pos := Vector2.ZERO:
	set(value):
		sim_pos = value
		geometry_revision += 1
var _use_billboard := false
var block_half := Vector2.ONE

static func resource_blocks_pathfinding(type: Enums.ResourceType) -> bool:
	match type:
		Enums.ResourceType.FOOD:
			return false
		Enums.ResourceType.WOOD, Enums.ResourceType.GOLD, Enums.ResourceType.STONE:
			return true
		_:
			return true

func pathfinding_size() -> Vector2:
	if not resource_blocks_pathfinding(resource_type): return Vector2.ZERO
	if block_size_override.x > 0 and block_size_override.y > 0:
		return block_size_override
	return pathfinding_footprint(resource_type)

static func pathfinding_footprint(type: Enums.ResourceType) -> Vector2:
	if not resource_blocks_pathfinding(type):
		return Vector2.ZERO
	# Use fixed playable sizes. Art-derived AABBs (esp. gold) are huge and break gather reach.
	match type:
		Enums.ResourceType.WOOD:
			return Vector2(1.2, 1.2)
		Enums.ResourceType.GOLD, Enums.ResourceType.STONE:
			return Vector2(2.0, 2.0)
		_:
			return Vector2.ZERO

static func selection_footprint(type: Enums.ResourceType) -> Vector2:
	match type:
		Enums.ResourceType.WOOD:
			return Vector2(1.2, 1.2)
		Enums.ResourceType.GOLD, Enums.ResourceType.STONE:
			return Vector2(2.0, 2.0)
		Enums.ResourceType.FOOD:
			return Vector2(0.8, 0.8)
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
	var footprint := pathfinding_size()
	if footprint.length_squared() <= 0.0:
		return sim_pos
	var half := footprint * 0.5
	# Navigation/collision treats resources as boxes. A circular stand radius
	# places diagonal work points inside that box, leaving the goal blocked.
	var clearance := half + Vector2.ONE * (maxf(unit_radius, 0.0) + 0.05)
	var offset := from - sim_pos
	var point := Vector2(clampf(offset.x, -clearance.x, clearance.x), clampf(offset.y, -clearance.y, clearance.y))
	if absf(offset.x) <= clearance.x and absf(offset.y) <= clearance.y:
		# If already inside the stand-off band, choose its closest outer face.
		if clearance.x - absf(offset.x) <= clearance.y - absf(offset.y):
			point.x = clearance.x * (-1.0 if offset.x < 0.0 else 1.0)
		else:
			point.y = clearance.y * (-1.0 if offset.y < 0.0 else 1.0)
	return sim_pos + point

func _ready() -> void:
	add_to_group("resource_nodes")
	EntityRegistryScript.register(self)
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	IsoMathScript.sync_node(self, sim_pos)
	block_half = pathfinding_size() * 0.5
	_setup_presentation()
	set_selected(false)


func _exit_tree() -> void:
	EntityRegistryScript.unregister(self, "removed")

func extract(delta: float) -> float:
	return Fixed.to_float(extract_fixed(Fixed.delta_time(delta)))

## Preserve the sub-unit remainder so 30 fixed steps extract exactly one
## second's rate. Capacity is expressed in resource sub-units, never time.
@warning_ignore("integer_division")
func extract_fixed(time_units: int, capacity_q: int = 2147483647) -> int:
	if time_units <= 0 or amount_q <= 0 or gather_rate_q <= 0 or capacity_q <= 0:
		return 0
	var numerator: int = gather_rate_q * time_units + _gather_remainder
	var extracted: int = mini(mini(amount_q, capacity_q), numerator / Fixed.TIME_SCALE)
	_gather_remainder = numerator % Fixed.TIME_SCALE
	amount_q -= extracted
	if amount_q == 0:
		visible = false
		_emit_resource_depleted()
		_release_nav_if_depleted()
	return extracted


func _emit_resource_depleted() -> void:
	var entity_id := EntityRegistryScript.id_of(self)
	if entity_id < 0:
		return
	AiEventBufferScript.push_for_entity({
		"type": AiProtocolScript.EVENT_RESOURCE_DEPLETED,
		"entity_id": entity_id,
		"resource_type": AiProtocolScript.resource_type_name(resource_type),
	}, self)

func _release_nav_if_depleted() -> void:
	if amount > 0.0:
		return
	if not resource_blocks_pathfinding(resource_type):
		return
	if not is_inside_tree():
		return
	var holder := get_tree().get_first_node_in_group("nav_service")
	if holder != null and holder.has_method("rebuild_from_scene"):
		holder.call("rebuild_from_scene")

func set_selected(selected: bool) -> void:
	_configure_selection_footprint()
	var ring := get_node_or_null("SelectionRing") as CanvasItem
	if ring != null:
		ring.visible = selected


func _setup_presentation() -> void:
	var existing_billboard := get_node_or_null("Billboard") as Sprite2D
	var existing_marker := get_node_or_null("Marker") as CanvasItem
	var base := SpriteCatalogScript.resource_sheet_base(resource_type)
	var frame_index := 0
	if resource_type == Enums.ResourceType.WOOD:
		var tree := TreeVariants.at_position(sim_pos)
		if SpriteCatalogScript.sheet_paths_exist(tree.base):
			base = tree.base
			frame_index = tree.frame
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			var billboard := existing_billboard
			if billboard == null:
				billboard = Sprite2D.new()
				billboard.name = "Billboard"
				add_child(billboard)
			billboard.texture = SpriteCatalogScript.atlas_frame_at(meta, texture, frame_index)
			var hotspot := SpriteCatalogScript.hotspot_at_index(meta, frame_index) if resource_type == Enums.ResourceType.WOOD else SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)
			SpriteCatalogScript.configure_sprite_2d(
				billboard, SpriteCatalogScript.RESOURCE_PIXEL_SCALE_2D, offset
			)
			billboard.visible = true
			_use_billboard = true
			SpriteCatalogScript.ensure_ground_shadow_2d(self, 16.0)
			if existing_marker != null:
				existing_marker.visible = false
			_configure_selection_footprint()
			return
	if existing_billboard != null:
		existing_billboard.visible = false
	if existing_marker != null:
		existing_marker.visible = true
	_configure_selection_footprint()


func _configure_selection_footprint() -> void:
	var footprint := selection_footprint(resource_type)
	if footprint.length_squared() <= 0.0:
		return
	var ring := get_node_or_null("SelectionRing")
	if ring is Line2D:
		return
	SpriteCatalogScript.configure_selection_footprint(self, footprint * 0.5)
