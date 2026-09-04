class_name ObservationBuilder
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")

const DEFAULT_DEFEND_RADIUS := 20.0


static func build(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy_team: Enums.Team,
	time_sec: float,
	defend_radius: float = DEFAULT_DEFEND_RADIUS
) -> Dictionary:
	var observation := {
		"economy": _build_economy(match_state, team),
		"derived": {},
		"entities": [] as Array,
	}
	if match_state == null or entities == null:
		return observation

	var derived := {
		"own_tc_id": -1,
		"own_tc_pos": [0.0, 0.0],
		"enemy_tc_id": -1,
		"enemy_tc_pos": [0.0, 0.0],
		"threat_near_base": false,
		"villager_count": 0,
		"military_count": 0,
		"incomplete_buildings": 0,
		"match_time_sec": float(time_sec),
	}

	var entity_snapshots: Array = []
	var own_tc_pos := Vector2.ZERO

	for node in entities.get_children():
		var entity := node as Node2D
		if entity == null:
			continue
		if entity.has_method("extract"):
			var resource_id := EntityRegistryScript.register(entity)
			entity_snapshots.append(serialize_entity(entity, resource_id))
			continue
		if entity.get("def") is BuildingDef:
			var building := entity
			var building_def := building.get("def") as BuildingDef
			var building_team: Enums.Team = building.get("team")
			var building_id := EntityRegistryScript.register(building)
			if building_def != null and building_def.id == &"town_center":
				if building_team == team:
					derived["own_tc_id"] = building_id
					own_tc_pos = building.get("sim_pos")
					derived["own_tc_pos"] = AiProtocolScript.vec2_to_array(own_tc_pos)
				elif building_team == enemy_team:
					derived["enemy_tc_id"] = building_id
					derived["enemy_tc_pos"] = AiProtocolScript.vec2_to_array(
						building.get("sim_pos")
					)
			if building_team != team:
				continue
			entity_snapshots.append(serialize_entity(building, building_id))
			if not bool(building.get("is_complete")):
				derived["incomplete_buildings"] = int(derived["incomplete_buildings"]) + 1
			continue
		if entity.get("def") is UnitDef:
			var unit := entity
			var unit_id := EntityRegistryScript.register(unit)
			entity_snapshots.append(serialize_entity(unit, unit_id))
			if unit.get("team") != team:
				if float(unit.get("hp")) > 0.0 and own_tc_pos != Vector2.ZERO:
					var dist: float = own_tc_pos.distance_to(unit.get("sim_pos"))
					if dist <= defend_radius:
						derived["threat_near_base"] = true
				continue
			var unit_def := unit.get("def") as UnitDef
			if unit_def != null and unit_def.id == &"villager":
				derived["villager_count"] = int(derived["villager_count"]) + 1
			else:
				derived["military_count"] = int(derived["military_count"]) + 1

	observation["derived"] = derived
	observation["entities"] = entity_snapshots
	return observation


static func build_json_safe(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy_team: Enums.Team,
	time_sec: float,
	defend_radius: float = DEFAULT_DEFEND_RADIUS
) -> Dictionary:
	return AiProtocolScript.json_safe(
		build(match_state, entities, team, enemy_team, time_sec, defend_radius)
	) as Dictionary


static func serialize_entity(entity: Node2D, entity_id: int = -1) -> Dictionary:
	if entity_id < 0:
		entity_id = EntityRegistryScript.id_of(entity)
	var kind := AiProtocolScript.entity_kind(entity)
	var pos: Vector2 = entity.get("sim_pos")
	var snapshot := {
		"id": entity_id,
		"kind": kind,
		"pos": AiProtocolScript.vec2_to_array(pos),
	}
	match kind:
		"resource":
			_fill_resource(snapshot, entity)
		"building":
			_fill_building(snapshot, entity)
		"unit":
			_fill_unit(snapshot, entity)
	return snapshot


static func _build_economy(match_state: MatchState, team: Enums.Team) -> Dictionary:
	if match_state == null:
		return {
			"food": 0,
			"wood": 0,
			"gold": 0,
			"pop_used": 0,
			"pop_cap": 0,
		}
	return {
		"food": match_state.get_resource(team, Enums.ResourceType.FOOD),
		"wood": match_state.get_resource(team, Enums.ResourceType.WOOD),
		"gold": match_state.get_resource(team, Enums.ResourceType.GOLD),
		"pop_used": int(match_state.population.get(team, 0)),
		"pop_cap": int(match_state.population_cap.get(team, 0)),
	}


static func _fill_resource(snapshot: Dictionary, entity: Node2D) -> void:
	snapshot["resource_type"] = AiProtocolScript.resource_type_name(
		int(entity.get("resource_type")) as Enums.ResourceType
	)
	snapshot["amount"] = float(entity.get("amount"))


static func _fill_building(snapshot: Dictionary, entity: Node2D) -> void:
	snapshot["def_id"] = AiProtocolScript.def_id_string(entity)
	snapshot["team"] = int(entity.get("team"))
	snapshot["hp"] = float(entity.get("hp"))
	snapshot["max_hp"] = _building_max_hp(entity)
	snapshot["is_complete"] = bool(entity.get("is_complete"))
	snapshot["build_progress"] = float(entity.get("build_progress"))
	var train_queue: Array = entity.get("train_queue") as Array
	snapshot["train_queue_empty"] = train_queue.is_empty()


static func _fill_unit(snapshot: Dictionary, entity: Node2D) -> void:
	snapshot["def_id"] = AiProtocolScript.def_id_string(entity)
	snapshot["team"] = int(entity.get("team"))
	snapshot["hp"] = float(entity.get("hp"))
	snapshot["max_hp"] = _unit_max_hp(entity)
	var order: Enums.OrderType = entity.get("order")
	snapshot["order"] = AiProtocolScript.order_name(order)
	snapshot["gather_state"] = String(entity.get("_gather_state"))
	var carry_type: int = int(entity.get("carry_type"))
	if carry_type >= 0:
		snapshot["carry_type"] = AiProtocolScript.resource_type_name(
			carry_type as Enums.ResourceType
		)
	else:
		snapshot["carry_type"] = null
	snapshot["carry_amount"] = float(entity.get("carry_amount"))
	snapshot["stuck_frames"] = int(entity.get("_no_progress_frames"))
	snapshot["last_resource_id"] = _entity_id_or_null(entity.get("_last_resource"))
	snapshot["target_id"] = _resolve_unit_target_id(entity, order)


static func _resolve_unit_target_id(entity: Node2D, order: Enums.OrderType) -> Variant:
	match order:
		Enums.OrderType.GATHER:
			var gather_state := String(entity.get("_gather_state"))
			if gather_state == "to_drop_off":
				return _entity_id_or_null(entity.get("_drop_off_target"))
			return _entity_id_or_null(entity.get("_gather_target"))
		Enums.OrderType.BUILD:
			return _entity_id_or_null(entity.get("_build_target"))
		Enums.OrderType.ATTACK:
			return _entity_id_or_null(entity.get("_attack_target"))
		_:
			return null


static func _entity_id_or_null(target: Variant) -> Variant:
	if target == null or not is_instance_valid(target):
		return null
	return EntityRegistryScript.id_of(target as Node2D)


static func _unit_max_hp(entity: Node2D) -> float:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return float(unit_def.max_hp)
	return maxf(float(entity.get("hp")), 1.0)


static func _building_max_hp(entity: Node2D) -> float:
	var building_def := entity.get("def") as BuildingDef
	if building_def == null:
		return maxf(float(entity.get("hp")), 1.0)
	var entity_civ := entity.get("civ") as CivDef
	var hp_multiplier := entity_civ.building_hp_mul if entity_civ != null else 1.0
	return float(building_def.max_hp) * hp_multiplier
