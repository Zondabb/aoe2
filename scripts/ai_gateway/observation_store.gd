class_name ObservationStore
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")

var economy: Dictionary = {}
var derived: Dictionary = {}
var entities: Array = []
var map_bounds := Rect2()


func load_from_dict(observation: Dictionary) -> void:
	economy = observation.get("economy", {}) as Dictionary
	derived = observation.get("derived", {}) as Dictionary
	entities = observation.get("entities", []) as Array
	map_bounds = Rect2()
	var box: Variant = observation.get("map_bounds")
	if box is Dictionary and AiProtocolScript.array_to_vec2(box.get("min")) != null and AiProtocolScript.array_to_vec2(box.get("max")) != null:
		var minimum: Vector2 = AiProtocolScript.array_to_vec2(box.min)
		map_bounds = Rect2(minimum, AiProtocolScript.array_to_vec2(box.max) - minimum)


func apply_to_blackboard(blackboard: AiBlackboard, team: Enums.Team, enemy_team: Enums.Team) -> void:
	if blackboard == null:
		return
	blackboard.match_time = float(derived.get("match_time_sec", 0.0))
	blackboard.ai_team = team
	blackboard.map_bounds = map_bounds
	blackboard.enemy_team = enemy_team
	blackboard.food = int(economy.get("food", 0))
	blackboard.wood = int(economy.get("wood", 0))
	blackboard.gold = int(economy.get("gold", 0))
	blackboard.stone = int(economy.get("stone", 0))
	blackboard.pop_used = int(economy.get("pop_used", 0))
	blackboard.pop_cap = int(economy.get("pop_cap", 0))
	blackboard.villager_count = int(derived.get("villager_count", 0))
	blackboard.military_count = int(derived.get("military_count", 0))
	blackboard.incomplete_buildings = int(derived.get("incomplete_buildings", 0))
	blackboard.threat_near_base = bool(derived.get("threat_near_base", false))
	blackboard.own_tc_pos = _vec2_from_json(derived.get("own_tc_pos"))
	blackboard.enemy_tc_pos = _vec2_from_json(derived.get("enemy_tc_pos"))
	blackboard.team_units.clear()
	blackboard.team_villagers.clear()
	blackboard.team_buildings.clear()
	blackboard.resource_nodes.clear()
	for snapshot in entities:
		if not (snapshot is Dictionary):
			continue
		var entity := EntityRegistryScript.resolve(int(snapshot.get("id", -1)))
		if entity == null:
			continue
		var kind := String(snapshot.get("kind", ""))
		match kind:
			"resource":
				blackboard.resource_nodes.append(entity)
			"building":
				if int(entity.get("team")) == int(team):
					blackboard.team_buildings.append(entity)
				if snapshot.get("def_id") == "farm" and snapshot.get("is_complete",false) and float(snapshot.get("amount",0)) > 0:
					blackboard.resource_nodes.append(entity)
			"unit":
				if int(entity.get("team")) != int(team):
					continue
				blackboard.team_units.append(entity)
				if String(snapshot.get("def_id", "")) == "villager":
					blackboard.team_villagers.append(entity)


static func _vec2_from_json(value: Variant) -> Vector2:
	var parsed: Variant = AiProtocolScript.array_to_vec2(value)
	if parsed is Vector2:
		return parsed as Vector2
	return Vector2.ZERO
