class_name AiEntityQueries
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

const BuildSystemScript := preload("res://scripts/systems/build_system.gd")


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
	# 环 TC 放置，优先在村民/资源一侧（朝地图中心），避免路径穿过 TC
	var offsets := [
		Vector2(6.0, 0.0),
		Vector2(6.0, 4.0),
		Vector2(4.0, 6.0),
		Vector2(0.0, 6.0),
		Vector2(8.0, 2.0),
		Vector2(8.0, 6.0),
		Vector2(6.0, 8.0),
		Vector2(10.0, 0.0),
		Vector2(10.0, 4.0),
		Vector2(8.0, 8.0),
		Vector2(4.0, 10.0),
		Vector2(12.0, 2.0),
	]
	# A four-age base outgrows the opening slots. Expand toward the map center.
	for radius in range(14, 39, 4):
		for offset in range(0, radius + 1, 4):
			offsets.append(Vector2(radius, offset))
			offsets.append(Vector2(offset, radius))
	for index in offsets.size():
		var slot := (build_slot + index) % offsets.size()
		var candidate: Vector2 = origin + offsets[slot] * side
		var fog := FogAccess.for_node(town_center)
		var state: MatchState = town_center.get("match_state")
		if state != null and state.fog_enabled and fog != null and not fog.footprint_visible(town_center.get("team"), candidate, building_def.footprint, true):
			continue
		if BuildSystemScript.can_place(building_def.footprint, candidate, existing):
			return candidate
	return null


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
