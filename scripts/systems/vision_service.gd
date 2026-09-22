class_name VisionService
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

## Vision queries over SpatialHash. Units/buildings register; observers use vision_radius.

const SpatialHashScript := preload("res://scripts/systems/spatial_hash.gd")
const DEFAULT_VISION_RADIUS := 16.0
const DEFAULT_CELL_SIZE := 2.0

var hash: SpatialHashScript = SpatialHashScript.new()


func setup(cell_size: float = DEFAULT_CELL_SIZE) -> void:
	hash.setup(cell_size)


func clear() -> void:
	hash.clear()


func register(entity: Object) -> void:
	if not _is_indexable(entity):
		return
	hash.insert(entity, entity.get("sim_pos") as Vector2)


func unregister(entity: Object) -> void:
	hash.remove(entity)


func sync_position(entity: Object) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if not hash.has_entity(entity):
		if _is_indexable(entity):
			register(entity)
		return
	if not _is_indexable(entity):
		unregister(entity)
		return
	hash.move(entity, entity.get("sim_pos") as Vector2)


func rebuild_from_tree(tree: SceneTree) -> void:
	clear()
	if tree == null:
		return
	for node in tree.get_nodes_in_group("units"):
		register(node)
	for node in tree.get_nodes_in_group("buildings"):
		register(node)


func vision_radius_of(observer: Object) -> float:
	if observer == null:
		return DEFAULT_VISION_RADIUS
	if observer.has_method("resolved_vision_radius"):
		return float(observer.call("resolved_vision_radius"))
	var override_variant: Variant = observer.get("vision_radius_override")
	if override_variant is float and float(override_variant) >= 0.0:
		return float(override_variant)
	var building_def := observer.get("def") as BuildingDef
	if building_def != null:
		return building_def.vision_radius if observer.get("is_complete") else building_def.construction_vision_radius
	var unit_def := observer.get("def") as UnitDef
	if unit_def != null:
		return unit_def.resolved_vision_radius()
	return DEFAULT_VISION_RADIUS


func others_in_radius(observer: Object, radius: float = -1.0) -> Array:
	## Any other indexed living unit/building inside vision (team-agnostic).
	var result: Array = []
	if observer == null or not is_instance_valid(observer):
		return result
	var pos_variant: Variant = observer.get("sim_pos")
	if not (pos_variant is Vector2):
		return result
	var query_radius := radius if radius >= 0.0 else vision_radius_of(observer)
	for entity in hash.query_radius(pos_variant as Vector2, query_radius):
		if entity == null or entity == observer or not is_instance_valid(entity):
			continue
		if entity.get("is_placement_ghost") == true:
			continue
		if float(entity.get("hp")) <= 0.0:
			continue
		result.append(entity)
	return result


func hostiles_in_radius(
	observer: Object,
	enemy_team: Enums.Team,
	radius: float = -1.0
) -> Array:
	var result: Array = []
	if observer == null or not is_instance_valid(observer):
		return result
	var pos_variant: Variant = observer.get("sim_pos")
	if not (pos_variant is Vector2):
		return result
	var query_radius := radius if radius >= 0.0 else vision_radius_of(observer)
	for entity in hash.query_radius(pos_variant as Vector2, query_radius):
		if _is_valid_hostile(observer, entity, enemy_team):
			result.append(entity)
	return result


func nearest_hostile(
	observer: Object,
	enemy_team: Enums.Team,
	radius: float = -1.0
) -> Object:
	var nearest: Object = null
	var nearest_distance := INF
	if observer == null or not is_instance_valid(observer):
		return null
	var pos_variant: Variant = observer.get("sim_pos")
	if not (pos_variant is Vector2):
		return null
	var from_pos := pos_variant as Vector2
	var query_radius := radius if radius >= 0.0 else vision_radius_of(observer)
	for entity in hash.query_radius(from_pos, query_radius):
		if not _is_valid_hostile(observer, entity, enemy_team):
			continue
		var other_pos: Vector2 = entity.get("sim_pos")
		var distance := from_pos.distance_squared_to(other_pos)
		if distance < nearest_distance:
			nearest = entity
			nearest_distance = distance
	return nearest


static func _is_indexable(entity: Object) -> bool:
	if entity == null or not is_instance_valid(entity):
		return false
	if entity.get("is_placement_ghost") == true:
		return false
	if not entity.has_method("take_damage"):
		return false
	if entity.get("sim_pos") == null:
		return false
	if float(entity.get("hp")) <= 0.0:
		return false
	return true


static func _is_valid_hostile(observer: Object, target: Object, enemy_team: Enums.Team) -> bool:
	if target == null or target == observer or not is_instance_valid(target):
		return false
	if not FogAccess.can_see(observer, target):
		return false
	if target.get("team") != enemy_team:
		return false
	if target.get("is_placement_ghost") == true:
		return false
	if not target.has_method("take_damage"):
		return false
	if float(target.get("hp")) <= 0.0:
		return false
	return true
