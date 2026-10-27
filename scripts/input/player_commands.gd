extends RefCounted

const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")

static func is_spectator(node: Node) -> bool:
	var parent := node
	while parent != null:
		if parent.get_meta("spectator", false): return true
		parent = parent.get_parent()
	if is_instance_valid(node) and node.is_inside_tree():
		var session := node.get_node_or_null("/root/GameSession")
		return session != null and session.get("online_active") == true and session.get("online_spectator") == true
	return false

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
	if is_spectator(node): return false
	var network := runtime(node)
	return bool(network.submit_command(command)) if network != null else false

static func unit_order(source: Node, unit: Node2D, op: String, target: Variant = null, formation_speed := 0.0) -> void:
	if is_spectator(source): return
	if not is_instance_valid(unit) or unit.is_queued_for_deletion():
		return
	if is_online(source):
		var command := {"op": op, "unit_id": entity_id(source, unit)}
		if op == "move":
			command["pos"] = [target.x, target.y]
			if formation_speed > 0.0: command["formation_speed"] = formation_speed
		elif op == "build":
			command["building_id"] = entity_id(source, target)
		elif op in ["attack", "gather"]:
			command["target_id"] = entity_id(source, target)
		if not submit(source, command):
			return
	elif op == "stop":
		unit.call("command_stop")
	else:
		unit.call("command_" + op, target)
		if op == "move" and formation_speed > 0.0 and unit.has_method("set_formation_move_speed"):
			unit.call("set_formation_move_speed", formation_speed)
	if not is_online(source):
		var command := {"op": op, "unit_id": Registry.id_of(unit)}
		if op == "move": command["pos"] = [target.x, target.y]
		elif op == "build": command["building_id"] = Registry.id_of(target)
		elif op in ["attack", "gather"]: command["target_id"] = Registry.id_of(target)
		Registry.report_manual_command(command, local_team(source))
	_play_order_voice(source, unit, op, target)


## Keep confirmations on the local input route: replicated and AI orders call
## the unit methods directly and must never produce player acknowledgements.
static func _play_order_voice(source: Node, unit: Node2D, op: String, target: Variant) -> void:
	if unit.get("team") != local_team(source):
		return
	var health: Variant = unit.get("hp")
	if health != null and float(health) <= 0.0:
		return
	var audio := audio_service(source)
	if audio == null:
		return
	# A group order calls unit_order once per member in the same input frame.
	# Let its first accepted member speak, including when a guest sends orders.
	var frame := Engine.get_process_frames()
	if source.get_meta("audio_order_frame", -1) == frame:
		return
	var action := StringName(op)
	if op == "gather" and is_instance_valid(target):
		match target.get("resource_type"):
			Enums.ResourceType.WOOD: action = &"gather_wood"
			Enums.ResourceType.FOOD: action = &"gather_food"
			Enums.ResourceType.GOLD, Enums.ResourceType.STONE: action = &"gather_mine"
	if bool(audio.call("play_unit_voice", unit, action)):
		source.set_meta("audio_order_frame", frame)


static func audio_service(source: Node) -> Node:
	if not is_instance_valid(source) or not source.is_inside_tree():
		return null
	return source.get_node_or_null("/root/GameAudio")


static func play_ui(source: Node, event: StringName) -> void:
	var audio := audio_service(source)
	if audio != null:
		audio.call("play_event", event, &"ui")


static func research_age(source: Node, building: Node2D, cancel: bool = false) -> bool:
	if is_spectator(source): return false
	if not is_instance_valid(building):
		return false
	if is_online(source):
		return submit(source, {"op": "cancel_research_age" if cancel else "research_age", "building_id": entity_id(source, building)})
	var accepted := bool(building.call("cancel_age_upgrade" if cancel else "start_age_upgrade"))
	if accepted:
		Registry.report_manual_command({"op": "cancel_research_age" if cancel else "research_age", "building_id": Registry.id_of(building)}, local_team(source))
	return accepted


static func research_technology(source: Node, building: Node2D, technology_id: String, cancel: bool = false) -> bool:
	if is_spectator(source): return false
	if not is_instance_valid(building):
		return false
	if is_online(source):
		return submit(source, {"op": "cancel_technology" if cancel else "research_technology", "building_id": entity_id(source, building), "technology_id": technology_id})
	var state := building.get("match_state") as MatchState
	if state == null or state.technology_progression == null:
		return false
	var accepted := bool(state.technology_progression.cancel_research(building)) if cancel else bool(state.technology_progression.start_research(building, technology_id))
	if accepted:
		Registry.report_manual_command({"op": "cancel_technology" if cancel else "research_technology", "building_id": Registry.id_of(building), "technology_id": technology_id}, local_team(source))
	return accepted
