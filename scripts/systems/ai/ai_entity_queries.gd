class_name AiEntityQueries
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

const BuildSystemScript := preload("res://scripts/systems/build_system.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

## Original DAT footprints are smaller than the rendered ground covered by the
## imported artwork. Reserve original tiles at the same 4× distance scale as
## movement/vision, then leave one original tile for workers and army traffic.
## This is settlement planning only; player/protocol construction rules stay intact.
const SETTLEMENT_FOOTPRINT_SCALE := 4.0
const SETTLEMENT_LANE_WIDTH := 4.0
const SETTLEMENT_EDGE_MARGIN := 4.0
const SETTLEMENT_SLOT_STEP := 8
const SETTLEMENT_MAX_RADIUS := 96


static func idle_villager(villagers: Array[Node2D]) -> Node2D:
	for villager in villagers:
		if villager.get("order") == Enums.OrderType.NONE:
			return villager
	return null


static func any_villager(villagers: Array[Node2D]) -> Node2D:
	return villagers[0] if not villagers.is_empty() else null


static func nearest_resource(
	from_unit: Node2D, nodes: Array[Node2D], resource_type: Enums.ResourceType
) -> Node2D:
	var nearest: Node2D
	var nearest_distance := INF
	for node in nodes:
		if not FogAccess.can_see(from_unit, node):
			continue
		if int(node.get("resource_type")) != int(resource_type):
			continue
		if float(node.get("amount")) <= 0.0:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest


static func nearest_any_resource(from_unit: Node2D, nodes: Array[Node2D]) -> Node2D:
	var nearest: Node2D
	var nearest_distance := INF
	for node in nodes:
		if not FogAccess.can_see(from_unit, node):
			continue
		if float(node.get("amount")) <= 0.0:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest


static func nearest_resource_near_base(
	from_unit: Node2D,
	nodes: Array[Node2D],
	resource_type: Enums.ResourceType,
	base_pos: Vector2,
	max_radius: float
) -> Node2D:
	if base_pos == Vector2.ZERO:
		return nearest_resource(from_unit, nodes, resource_type)
	var nearest: Node2D
	var nearest_distance := INF
	var max_sq := max_radius * max_radius
	for node in nodes:
		if not FogAccess.can_see(from_unit, node):
			continue
		if int(node.get("resource_type")) != int(resource_type):
			continue
		if float(node.get("amount")) <= 0.0:
			continue
		var node_pos: Vector2 = node.get("sim_pos")
		if base_pos.distance_squared_to(node_pos) > max_sq:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node_pos)
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest


static func nearest_any_resource_near_base(
	from_unit: Node2D,
	nodes: Array[Node2D],
	base_pos: Vector2,
	max_radius: float
) -> Node2D:
	if base_pos == Vector2.ZERO:
		return nearest_any_resource(from_unit, nodes)
	var nearest: Node2D
	var nearest_distance := INF
	var max_sq := max_radius * max_radius
	for node in nodes:
		if not FogAccess.can_see(from_unit, node):
			continue
		if float(node.get("amount")) <= 0.0:
			continue
		var node_pos: Vector2 = node.get("sim_pos")
		if base_pos.distance_squared_to(node_pos) > max_sq:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node_pos)
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest


static func nearest_hostile_in_radius(
	unit: Node2D,
	entities: Node2D,
	enemy_team: Enums.Team,
	radius: float
) -> Node2D:
	var vision := _vision_service_from(unit)
	if vision != null and vision.has_method("nearest_hostile"):
		return vision.call("nearest_hostile", unit, enemy_team, radius) as Node2D
	var nearest: Node2D
	var nearest_distance := INF
	var radius_squared := radius * radius
	if entities == null:
		return null
	for node in entities.get_children():
		if not FogAccess.can_see(unit, node):
			continue
		if node.get("team") != enemy_team:
			continue
		if node.get("is_placement_ghost") == true:
			continue
		if not node.has_method("take_damage"):
			continue
		if float(node.get("hp")) <= 0.0:
			continue
		var distance: float = unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance <= radius_squared and distance < nearest_distance:
			nearest = node as Node2D
			nearest_distance = distance
	return nearest


static func _vision_service_from(unit: Node) -> Object:
	if unit == null or not unit.is_inside_tree():
		return null
	var holders := unit.get_tree().get_nodes_in_group("vision_service")
	if holders.is_empty():
		return null
	var holder := holders[0]
	if holder.has_meta("vision"):
		return holder.get_meta("vision")
	return null


static func find_town_center(buildings: Array[Node2D]) -> Node2D:
	for building in buildings:
		var building_def := building.get("def") as BuildingDef
		if building_def != null and building_def.id == &"town_center":
			return building
	return null


static func has_building(buildings: Array[Node2D], building_id: StringName) -> bool:
	for building in buildings:
		var building_def := building.get("def") as BuildingDef
		if building_def != null and building_def.id == building_id:
			return true
	return false


static func has_incomplete_building(buildings: Array[Node2D], building_id: StringName) -> bool:
	for building in buildings:
		var building_def := building.get("def") as BuildingDef
		if (
			building_def != null
			and building_def.id == building_id
			and not bool(building.get("is_complete"))
		):
			return true
	return false


static func find_complete_building(buildings: Array[Node2D], building_id: StringName) -> Node2D:
	for building in buildings:
		var building_def := building.get("def") as BuildingDef
		if (
			building_def != null
			and building_def.id == building_id
			and bool(building.get("is_complete"))
		):
			return building
	return null


static func all_buildings(entities: Node2D) -> Array[Node2D]:
	var result: Array[Node2D] = []
	if entities == null:
		return result
	for node in entities.get_children():
		if node.get("def") is BuildingDef:
			result.append(node as Node2D)
	return result


static func next_build_position(
	building_def: BuildingDef,
	town_center: Node2D,
	entities: Node2D,
	build_slot: int
) -> Variant:
	if town_center == null or entities == null or building_def == null:
		return null
	var existing := all_buildings(entities)
	var origin: Vector2 = town_center.get("sim_pos")
	var side := _build_side_sign(origin)
	var offsets: Array[Vector2] = []
	# Prefer the inner side of the map; expand in deterministic, roomy rings.
	for radius in range(16, SETTLEMENT_MAX_RADIUS + 1, SETTLEMENT_SLOT_STEP):
		for offset in range(0, radius + 1, SETTLEMENT_SLOT_STEP):
			offsets.append(Vector2(radius, offset))
			if offset != radius:
				offsets.append(Vector2(offset, radius))
	var resources: Array[Node2D] = []
	for node in entities.get_children():
		if node.has_method("extract") and not node.get("def") is BuildingDef:
			if float(node.get("amount")) > 0.0 and FogAccess.can_see(town_center, node):
				resources.append(node as Node2D)
	var bounds := _settlement_map_bounds(town_center)
	for index in offsets.size():
		var slot := posmod(build_slot + index, offsets.size())
		var candidate: Vector2 = origin + offsets[slot] * side
		var fog := FogAccess.for_node(town_center)
		var state: MatchState = town_center.get("match_state")
		if state != null and state.fog_enabled and fog != null and not fog.footprint_visible(town_center.get("team"), candidate, building_def.footprint, true):
			continue
		if can_plan_settlement(building_def.footprint, candidate, existing, resources, bounds):
			return candidate
	return null


## A building must leave a traversable lane around visual ground footprints,
## gathering space beside resources, and a lane inside rectangular map edges.
static func can_plan_settlement(
	footprint: Vector2, center: Vector2, existing: Array,
	resources: Array = [], bounds: Rect2 = Rect2()
) -> bool:
	if not BuildSystemScript.can_place(footprint, center, existing):
		return false
	var half := footprint * (SETTLEMENT_FOOTPRINT_SCALE * 0.5)
	if bounds.has_area():
		var margin := half + Vector2.ONE * SETTLEMENT_EDGE_MARGIN
		if not bounds.encloses(Rect2(center - margin, margin * 2.0)):
			return false
	for value in existing:
		var building := value as Node2D
		if not is_instance_valid(building) or building.is_queued_for_deletion() or building.get("is_placement_ghost") == true:
			continue
		var definition := building.get("def") as BuildingDef
		var other_half := (definition.footprint if definition != null else Vector2.ONE) * (SETTLEMENT_FOOTPRINT_SCALE * 0.5)
		if _settlement_boxes_overlap(center, half, building.get("sim_pos"), other_half):
			return false
	for value in resources:
		var resource := value as Node2D
		if not is_instance_valid(resource) or resource.is_queued_for_deletion() or float(resource.get("amount")) <= 0.0:
			continue
		var other_half := ResourceNodeScript.selection_footprint(resource.get("resource_type")) * (SETTLEMENT_FOOTPRINT_SCALE * 0.5)
		if _settlement_boxes_overlap(center, half, resource.get("sim_pos"), other_half):
			return false
	return true


static func _settlement_boxes_overlap(a: Vector2, half_a: Vector2, b: Vector2, half_b: Vector2) -> bool:
	var required := half_a + half_b + Vector2.ONE * SETTLEMENT_LANE_WIDTH
	var offset := (a - b).abs()
	return offset.x < required.x and offset.y < required.y


static func _settlement_map_bounds(town_center: Node2D) -> Rect2:
	var fog := FogAccess.for_node(town_center)
	if fog != null:
		return Rect2(fog.get("map_origin"), fog.get("map_end") - fog.get("map_origin"))
	# Fixtures and custom sandboxes may have no fog service.
	var ancestor: Node = town_center
	while ancestor != null:
		var bootstrap := ancestor.get_node_or_null("Bootstrap")
		if bootstrap != null:
			var bounds: Variant = bootstrap.get("map_bounds")
			if bounds is Rect2:
				return bounds
		ancestor = ancestor.get_parent()
	return Rect2()


## 基地在地图负角时村民在 TC 朝中心一侧；正角时相反。建筑跟同一侧扩展。
static func _build_side_sign(origin: Vector2) -> Vector2:
	var sx := 1.0
	var sy := 1.0
	if origin.x < -0.01:
		sx = 1.0
	elif origin.x > 0.01:
		sx = -1.0
	if origin.y < -0.01:
		sy = 1.0
	elif origin.y > 0.01:
		sy = -1.0
	return Vector2(sx, sy)
