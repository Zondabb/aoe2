class_name GatherSystem
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

## Called at resource exhaustion, not every physics tick. Never read hidden
## stock, and keep the job around its previous work site after a delivery.
static func resource_candidates(unit: Node2D, type: int, origin: Vector2) -> Array[WeakRef]:
	var nodes: Array[Node] = []
	if unit.is_inside_tree():
		nodes.assign(unit.get_tree().get_nodes_in_group("resource_nodes"))
	elif unit.get_parent() != null:
		nodes.assign(unit.get_parent().get_children())
	var ranked: Array[Dictionary] = []
	for node in nodes:
		if not resource_usable(unit, node, type):
			continue
		var point: Vector2 = node.get("sim_pos")
		ranked.append({"distance": Fixed.distance_squared(origin, point), "id": int(node.get_meta("net_id", node.get_instance_id())), "node": weakref(node)})
	# Ties have a stable result; do not send all workers to different resource
	# kinds merely because their hands became empty at the drop-off point.
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.id < b.id if a.distance == b.distance else a.distance < b.distance)
	var result: Array[WeakRef] = []
	for candidate in ranked:
		result.append(candidate.node)
	return result


static func resource_usable(unit: Node2D, resource: Variant, type: int) -> bool:
	if not is_instance_valid(resource) or resource.is_queued_for_deletion() or not resource.has_method("extract"):
		return false
	if unit.is_inside_tree() and resource.get_parent() != unit.get_parent():
		return false
	if not FogAccess.can_see(unit, resource):
		return false
	if int(resource.get("resource_type")) != type or float(resource.get("amount")) <= 0.0 or float(resource.get("gather_rate")) <= 0.0:
		return false
	if resource.get("def") is BuildingDef:
		return resource.get("team") == unit.get("team") and resource.get("is_complete") == true and resource.get("is_placement_ghost") != true and float(resource.get("hp")) > 0.0
	return true


static func work_point(resource: Node2D, from: Vector2, radius: float) -> Vector2:
	if resource.has_method("approach_point"):
		return resource.call("approach_point", from, radius)
	return resource.get("sim_pos")


## Validate a small local stencil, instead of snapping a forest-interior goal
## to distant empty ground. Alternative sides allow walking around obstacles.
static func work_points(resource: Node2D, from: Vector2, radius: float, nav: Object, reach: float) -> PackedVector2Array:
	var preferred := work_point(resource, from, radius)
	if nav == null:
		return PackedVector2Array([preferred])
	var center: Vector2 = resource.get("sim_pos")
	var probes := PackedVector2Array([preferred])
	if resource.has_method("approach_point") and preferred != center:
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			probes.append(work_point(resource, center + direction * 100.0, radius))
	var points: Array[Vector2] = []
	var seen := {}
	for probe in probes:
		var best_point := Vector2.ZERO
		var best_distance: int = 9223372036854775807
		var cell: Vector2i = nav.world_to_cell(probe)
		for y in range(-1, 2):
			for x in range(-1, 2):
				var point: Vector2 = nav.cell_to_world_center(cell + Vector2i(x, y))
				if seen.has(point) or not nav.is_world_walkable_with_radius(point, radius):
					continue
				var reach_q := Fixed.from_float(reach)
				if Fixed.distance_squared(point, work_point(resource, point, radius)) > reach_q * reach_q:
					continue
				var distance := Fixed.distance_squared(from, point)
				if distance < best_distance:
					best_distance = distance
					best_point = point
		if best_distance < 9223372036854775807:
			seen[best_point] = true
			points.append(best_point)
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return Fixed.distance_squared(from, a) < Fixed.distance_squared(from, b))
	return PackedVector2Array(points)

static func nearest_drop_off(
	unit: Node2D,
	resource_type: Enums.ResourceType
) -> Node2D:
	var nearest: Node2D
	var nearest_distance: int = 9223372036854775807
	var candidates: Array[Node] = []
	if unit.is_inside_tree():
		candidates.assign(unit.get_tree().get_nodes_in_group("drop_off_buildings"))
	elif unit.get_parent() != null:
		for child in unit.get_parent().get_children():
			if child.has_method("accepts_resource"):
				candidates.append(child)
	for node in candidates:
		var building := node as Node2D
		if building == null or building.get("team") != unit.get("team"):
			continue
		if not building.call("accepts_resource", resource_type):
			continue
		var distance := Fixed.distance_squared(unit.get("sim_pos"), building.get("sim_pos"))
		if distance < nearest_distance or (distance == nearest_distance and nearest != null and int(building.get_meta("net_id", building.get_instance_id())) < int(nearest.get_meta("net_id", nearest.get_instance_id()))):
			nearest = building
			nearest_distance = distance
	return nearest
