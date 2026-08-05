class_name GatherSystem
extends RefCounted

static func nearest_drop_off(
	unit: Node3D,
	resource_type: Enums.ResourceType
) -> Node3D:
	var nearest: Node3D
	var nearest_distance := INF
	var candidates: Array[Node] = []
	if unit.is_inside_tree():
		candidates.assign(unit.get_tree().get_nodes_in_group("drop_off_buildings"))
	elif unit.get_parent() != null:
		for child in unit.get_parent().get_children():
			if child.has_method("accepts_resource"):
				candidates.append(child)
	for node in candidates:
		var building := node as Node3D
		if building == null or building.get("team") != unit.get("team"):
			continue
		if not building.call("accepts_resource", resource_type):
			continue
		var distance := unit.position.distance_squared_to(building.position)
		if distance < nearest_distance:
			nearest = building
			nearest_distance = distance
	return nearest
