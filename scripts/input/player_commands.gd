extends RefCounted

## Match-local routing keeps offline scenes and test arenas independent of a lobby.
static func local_team(node: Node) -> Enums.Team:
	var parent := node
	while parent != null:
		if parent.has_meta("local_team"):
			return int(parent.get_meta("local_team")) as Enums.Team
		parent = parent.get_parent()
	return Enums.Team.PLAYER

static func is_online(node: Node) -> bool:
	var parent := node
	while parent != null:
		if parent.get_meta("online_match", false):
			return true
		parent = parent.get_parent()
	return false

static func runtime(node: Node) -> Node:
	var parent := node
	while parent != null:
		var network := parent.get_node_or_null("NetworkMatch")
		if network != null:
			return network
		parent = parent.get_parent()
	return null

static func entity_id(node: Node, entity: Node2D) -> int:
	var network := runtime(node)
	return int(network.entity_id(entity)) if network != null else -1

static func submit(node: Node, command: Dictionary) -> bool:
	var network := runtime(node)
	return bool(network.submit_command(command)) if network != null else false

static func unit_order(source: Node, unit: Node2D, op: String, target: Variant = null) -> void:
	if is_online(source):
		var command := {"op": op, "unit_id": entity_id(source, unit)}
		if op == "move":
			command["pos"] = [target.x, target.y]
		elif op == "build":
			command["building_id"] = entity_id(source, target)
		elif op in ["attack", "gather"]:
			command["target_id"] = entity_id(source, target)
		submit(source, command)
	elif op == "stop":
		unit.call("command_stop")
	else:
		unit.call("command_" + op, target)


static func research_age(source: Node, building: Node2D, cancel: bool = false) -> bool:
	if not is_instance_valid(building):
		return false
	if is_online(source):
		return submit(source, {"op": "cancel_research_age" if cancel else "research_age", "building_id": entity_id(source, building)})
	return bool(building.call("cancel_age_upgrade" if cancel else "start_age_upgrade"))


static func research_technology(source: Node, building: Node2D, technology_id: String, cancel: bool = false) -> bool:
	if not is_instance_valid(building):
		return false
	if is_online(source):
		return submit(source, {"op": "cancel_technology" if cancel else "research_technology", "building_id": entity_id(source, building), "technology_id": technology_id})
	var state := building.get("match_state") as MatchState
	if state == null or state.technology_progression == null:
		return false
	return bool(state.technology_progression.cancel_research(building)) if cancel else bool(state.technology_progression.start_research(building, technology_id))
