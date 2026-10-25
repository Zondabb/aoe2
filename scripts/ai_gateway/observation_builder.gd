class_name ObservationBuilder
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")
const DecisionContext := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")

const DEFAULT_DEFEND_RADIUS := 20.0


static func build(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy_team: Enums.Team,
	time_sec: float,
	defend_radius: float = DEFAULT_DEFEND_RADIUS,
	defense_only: bool = false
) -> Dictionary:
	# Godot marks every function containing await as a coroutine, even when an
	# optional branch does not run. Dynamic dispatch keeps this established
	# synchronous API usable without changing its callers.
	return Callable(ObservationBuilder, &"_build_impl").call(match_state, entities, team, enemy_team, time_sec, defend_radius, defense_only)


static func build_budgeted(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy_team: Enums.Team,
	time_sec: float,
	defend_radius: float = DEFAULT_DEFEND_RADIUS,
	defense_only: bool = false,
	yield_frame: Callable = Callable(),
	budget_usec: int = 4000
) -> Dictionary:
	return await _build_impl(match_state, entities, team, enemy_team, time_sec, defend_radius, defense_only, yield_frame, budget_usec)


static func _build_impl(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy_team: Enums.Team,
	time_sec: float,
	defend_radius: float = DEFAULT_DEFEND_RADIUS,
	defense_only: bool = false,
	yield_frame: Callable = Callable(),
	budget_usec: int = 4000
) -> Dictionary:
	var budgeted := yield_frame.is_valid() and budget_usec > 0
	var deadline := Time.get_ticks_usec() + budget_usec
	var observation := {
		"team": int(team),
		"economy": _build_economy(match_state, team),
		"derived": {},
		"entities": [] as Array,
	}
	if match_state == null or not is_instance_valid(entities):
		if budgeted: return {}
		return observation
	if budgeted and (not entities.is_inside_tree() or entities.is_queued_for_deletion()): return {}
	if match_state.map_bounds.has_area():
		observation["map_bounds"] = {"min": AiProtocolScript.vec2_to_array(match_state.map_bounds.position), "max": AiProtocolScript.vec2_to_array(match_state.map_bounds.end)}
	observation["capabilities"] = {"schema_version": 3, "zoned_construction": true,
		"production_status": true, "farm_depletion_frees_plot": true,
		"ram_building_class_damage": true, "wall_segments": true,
		"gate_control": true, "trebuchet_pack_unpack": false}
	observation["victory_conditions"] = {"type": "destroy_any_enemy_town_center",
		"target_def_id": "town_center", "winner": match_state.winner,
		"match_over": match_state.winner >= 0}

	if match_state.progression_enabled:
		observation["progression"] = {"age":match_state.age_of(team),"researched_technologies":match_state.researched_technologies.get(team,{}),"age_research":match_state.age_progression.progress_for(team) if match_state.age_progression != null else {}}
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
	# One uninterrupted slice has a single age/civilization/catalog state.
	# Reuse unlock lists across identical walls; checkpoints clear this cache.
	var serialization_cache := {}
	var fog_holder := FogAccess.holder_for_snapshot(match_state, entities)
	var own_tc_pos := Vector2.ZERO
	var vision := _vision_service(entities)
	var observers := _team_observers(entities, team)
	for observer in observers:
		if observer.get("def") is BuildingDef and observer.get("def").id == &"town_center":
			own_tc_pos = observer.get("sim_pos")
			derived["own_tc_id"] = EntityRegistryScript.register(observer)
			derived["own_tc_pos"] = AiProtocolScript.vec2_to_array(own_tc_pos)
			break
	if match_state.fog_enabled and match_state.fog != null:
		# Own sight circles let external planners use the same fog grid without
		# exposing any hidden enemy, terrain or resource information.
		var fog: RefCounted = match_state.fog
		var sources: Array = []
		for observer in observers:
			var radius: float = FogOfWarService.radius_of(observer)
			if radius > 0 and observer.get("is_placement_ghost") != true:
				var pos: Vector2 = observer.get("sim_pos")
				sources.append([pos.x, pos.y, radius])
		observation["placement_visibility"] = {"origin": AiProtocolScript.vec2_to_array(fog.get("map_origin")), "cell_size": fog.get("cell_size"), "grid_size": [fog.get("grid_size").x, fog.get("grid_size").y], "sources": sources}

	for node in entities.get_children():
		# The default path never awaits, preserving direct Dictionary results for
		# native AI and existing callers. Gateways can instead share this work
		# across main-thread frames; no Node is handed to a worker thread.
		if budgeted and Time.get_ticks_usec() >= deadline:
			if not await yield_frame.call(): return {}
			if not is_instance_valid(entities) or not entities.is_inside_tree() or entities.is_queued_for_deletion(): return {}
			deadline = Time.get_ticks_usec() + budget_usec
			fog_holder = FogAccess.holder_for_snapshot(match_state, entities)
			# An age, technology or resource change can occur during the wait.
			serialization_cache.clear()
		# An earlier checkpoint may have freed a node retained in get_children's
		# original list. Validate the raw reference before a typed cast.
		if not is_instance_valid(node): continue
		var entity := node as Node2D
		if entity == null or entity.is_queued_for_deletion() or entity.get("is_placement_ghost") == true:
			continue
		if entity.get("hp") != null and float(entity.get("hp")) <= 0.0:
			continue
		if not FogAccess.snapshot_can_see(match_state, team, entity, fog_holder):
			continue
		if entity.has_method("extract") and not entity.get("def") is BuildingDef:
			if not match_state.fog_enabled and vision != null and not _resource_visible(entity, observers, vision):
				continue
			var resource_id := EntityRegistryScript.register(entity)
			entity_snapshots.append(_defense_snapshot(entity, resource_id) if defense_only else serialize_entity(entity, resource_id, serialization_cache))
			continue
		if entity.get("def") is BuildingDef:
			var building := entity
			var building_def := building.get("def") as BuildingDef
			var building_team: Enums.Team = building.get("team")
			if building_team != team and not match_state.fog_enabled and vision != null and not _is_entity_visible(entity, observers, vision):
				continue
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
				if not match_state.fog_enabled and vision != null and not _is_entity_visible(entity, observers, vision):
					continue
				var visible_building := _defense_snapshot(building, building_id) if defense_only else serialize_entity(building, building_id, serialization_cache)
				visible_building.erase("gate_state")
				# Queue contents and research are private orders, not visible enemy art.
				for key in ["train_queue_empty", "train_queue", "train_progress", "trainable", "train_blocked_reasons", "is_researching", "technologies", "age_upgrade_reason", "production", "research"]:
					visible_building.erase(key)
				entity_snapshots.append(visible_building)
				continue
			entity_snapshots.append(_defense_snapshot(building, building_id) if defense_only else serialize_entity(building, building_id, serialization_cache))
			if not bool(building.get("is_complete")):
				derived["incomplete_buildings"] = int(derived["incomplete_buildings"]) + 1
			continue
		if entity.get("def") is UnitDef:
			var unit := entity
			var unit_team: Enums.Team = unit.get("team")
			var unit_id := EntityRegistryScript.register(unit)
			if unit_team != team:
				if not match_state.fog_enabled and vision != null and not _is_entity_visible(entity, observers, vision):
					continue
				var visible_unit := _defense_snapshot(unit, unit_id) if defense_only else serialize_entity(unit, unit_id)
				visible_unit.erase("move_goal")
				visible_unit.erase("gather_resource_type")
				visible_unit.erase("movement")
				visible_unit.erase("combat_action")
				visible_unit.erase("build_queue_ids")
				visible_unit["target_id"] = null
				visible_unit["last_resource_id"] = null
				entity_snapshots.append(visible_unit)
				if float(unit.get("hp")) > 0.0 and int(derived["own_tc_id"]) >= 0:
					var dist: float = own_tc_pos.distance_to(unit.get("sim_pos"))
					if dist <= defend_radius:
						derived["threat_near_base"] = true
				continue
			entity_snapshots.append(_defense_snapshot(unit, unit_id) if defense_only else serialize_entity(unit, unit_id))
			var unit_def := unit.get("def") as UnitDef
			if unit_def != null and unit_def.id == &"villager":
				derived["villager_count"] = int(derived["villager_count"]) + 1
			else:
				derived["military_count"] = int(derived["military_count"]) + 1

	observation["derived"] = derived
	observation["entities"] = entity_snapshots
	var observed_ids := {}
	for snapshot: Dictionary in entity_snapshots: observed_ids[snapshot.id] = true
	for snapshot: Dictionary in entity_snapshots:
		for key in ["target_id", "last_resource_id"]:
			if snapshot.get(key) != null and not observed_ids.has(snapshot[key]): snapshot[key] = null
	if budgeted:
		if Time.get_ticks_usec() >= deadline:
			if not await yield_frame.call(): return {}
			if not is_instance_valid(entities) or not entities.is_inside_tree() or entities.is_queued_for_deletion(): return {}
		var context: Dictionary = await DecisionContext.build_budgeted(match_state, entities, team, entity_snapshots, derived, defend_radius, defense_only, yield_frame, budget_usec)
		if context.is_empty(): return {}
		observation["decision_context"] = context
	else:
		observation["decision_context"] = DecisionContext.build(match_state, entities, team, entity_snapshots, derived, defend_radius, defense_only)
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


static func _defense_snapshot(entity: Node2D, entity_id: int) -> Dictionary:
	var position: Vector2 = entity.get("sim_pos")
	return {"id": entity_id, "kind": AiProtocolScript.entity_kind(entity), "team": entity.get("team"),
		"def_id": AiProtocolScript.def_id_string(entity), "pos": AiProtocolScript.vec2_to_array(position)}


static func serialize_entity(entity: Node2D, entity_id: int = -1, cache: Variant = null) -> Dictionary:
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
			_fill_building(snapshot, entity, cache if cache is Dictionary else {})
			if entity.has_method("extract"):
				_fill_resource(snapshot, entity)
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
		"stone": match_state.get_resource(team, Enums.ResourceType.STONE),
		"pop_used": int(match_state.population.get(team, 0)),
		"pop_reserved": int(match_state.population_reserved.get(team, 0)),
		"pop_cap": int(match_state.population_cap.get(team, 0)),
	}


static func _fill_resource(snapshot: Dictionary, entity: Node2D) -> void:
	snapshot["resource_type"] = AiProtocolScript.resource_type_name(
		int(entity.get("resource_type")) as Enums.ResourceType
	)
	snapshot["amount"] = float(entity.get("amount"))


static func _fill_building(snapshot: Dictionary, entity: Node2D, cache: Dictionary) -> void:
	snapshot["def_id"] = AiProtocolScript.def_id_string(entity)
	snapshot["team"] = int(entity.get("team"))
	snapshot["hp"] = float(entity.get("hp"))
	snapshot["max_hp"] = _building_max_hp(entity)
	var weapon := Catalog.building_weapon(entity.get("def").id)
	if weapon != null:
		snapshot["combat"] = {"attack": weapon.attack, "range": weapon.attack_range,
			"minimum_range": weapon.minimum_attack_range, "cooldown": weapon.attack_cooldown,
			"is_ranged": weapon.is_ranged, "attack_class_bonuses": weapon.attack_class_bonuses,
			"melee_armor": entity.get("melee_armor"), "pierce_armor": entity.get("pierce_armor")}
	snapshot["is_complete"] = bool(entity.get("is_complete"))
	snapshot["build_progress"] = float(entity.get("build_progress"))
	snapshot["build_time"] = float(entity.get("def").build_time)
	snapshot["footprint"] = AiProtocolScript.vec2_to_array(entity.get_placement_footprint())
	snapshot["orientation"] = entity.wall_orientation
	snapshot["gate_state"] = entity.gate_state
	snapshot["gate_open"] = entity.gate_open
	snapshot["planning_footprint"] = AiProtocolScript.vec2_to_array(DecisionContext.planning_footprint(entity.get("def")))
	snapshot["blocks_movement"] = entity.get_movement_half() != Vector2.ZERO
	snapshot["drop_off_resources"] = []
	if entity.get("def").has_drop_off:
		for resource_type in Enums.ResourceType.values():
			if entity.accepts_resource(resource_type): snapshot.drop_off_resources.append(AiProtocolScript.resource_type_name(resource_type))
	var train_queue: Array = entity.get("train_queue") as Array
	snapshot["train_queue_empty"] = train_queue.is_empty()
	snapshot["train_queue"] = train_queue.map(func(definition): return String(definition.id))
	snapshot["train_progress"] = float(entity.get("train_progress"))
	snapshot["production"] = entity.production_status()
	snapshot["research"] = {}
	snapshot["is_researching"] = entity.is_age_researching() or entity.is_technology_researching()
	# get_trainable_units scans the full unit catalog even for walls. Cache only
	# this building-independent unlock list; queue/resource blocked reasons remain
	# live per building. The cache lives for this build() call only.
	var building_state: MatchState = entity.get("match_state")
	var building_civ: CivDef = entity.get("civ")
	var definition: BuildingDef = entity.get("def")
	var unlock_key := [definition, building_state, building_civ, int(entity.get("team"))]
	var trainable: Array
	if cache.has(unlock_key): trainable = cache[unlock_key]
	else:
		trainable = entity.get_trainable_units()
		cache[unlock_key] = trainable
	snapshot["trainable"] = trainable.map(func(u): return String(u.id))
	var blocked_reasons := {}
	for unit_definition in trainable: blocked_reasons[String(unit_definition.id)] = entity.train_blocked_reason(unit_definition)
	snapshot["train_blocked_reasons"] = blocked_reasons
	var state: MatchState = entity.get("match_state")
	if state != null and state.progression_enabled:
		if state.age_progression != null and entity.get("def").id == &"town_center":
			snapshot["age_upgrade_reason"] = state.age_progression.blocked_reason(entity)
			if entity.is_age_researching(): snapshot["research"] = state.age_progression.progress_for(entity.team)
		if state.technology_progression != null:
			snapshot["technologies"] = state.technology_progression.available(entity).map(func(id): return {"id":id,"reason":state.technology_progression.blocked_reason(entity,id)})
			if entity.is_technology_researching():
				snapshot["research"] = state.technology_progression.progress_for(entity)
				snapshot.research["building_id"] = EntityRegistryScript.id_of(entity)


static func _fill_unit(snapshot: Dictionary, entity: Node2D) -> void:
	snapshot["def_id"] = AiProtocolScript.def_id_string(entity)
	snapshot["team"] = int(entity.get("team"))
	snapshot["hp"] = float(entity.get("hp"))
	snapshot["max_hp"] = _unit_max_hp(entity)
	var definition: UnitDef = entity.get("def")
	snapshot["combat"] = {"attack": definition.attack, "range": definition.attack_range,
		"minimum_range": definition.minimum_attack_range, "cooldown": definition.attack_cooldown,
		"is_ranged": definition.is_ranged, "attack_class_bonuses": definition.attack_class_bonuses,
		"projectile_splash_radius": definition.projectile_splash_radius if definition.is_ranged else 0.0,
		"projectile_friendly_fire": definition.is_ranged and definition.projectile_friendly_fire,
		"melee_armor": entity.get("melee_armor"), "pierce_armor": entity.get("pierce_armor")}
	snapshot["footprint_radius"] = definition.resolved_footprint_radius()
	var order: Enums.OrderType = entity.get("order")
	snapshot["order"] = AiProtocolScript.order_name(order)
	snapshot["build_queue_ids"] = entity.get_build_queue_ids()
	snapshot["gather_state"] = String(entity.get("_gather_state"))
	var gather_type: int = int(entity.get("_gather_resource_type"))
	snapshot["gather_resource_type"] = AiProtocolScript.resource_type_name(gather_type as Enums.ResourceType) if order == Enums.OrderType.GATHER and gather_type >= 0 else null
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
	snapshot["move_goal"] = AiProtocolScript.vec2_to_array(entity.get("_requested_move_target")) if order == Enums.OrderType.MOVE else null
	snapshot["movement"] = {"path_pending": bool(entity.get("_path_pending")),
		"stuck_seconds": float(entity.get("_stuck_seconds")),
		"repath_attempts": int(entity.get("_stuck_repath_attempts")),
		"distance_to_goal": entity.get("sim_pos").distance_to(entity.get("_requested_move_target")) if order == Enums.OrderType.MOVE else null}
	snapshot["combat_action"] = String(entity.get("_combat_action"))


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
	return entity._max_hp() if entity.has_method("_max_hp") else float(building_def.max_hp) * hp_multiplier


static func _vision_service(from_node: Node = null) -> VisionServiceScript:
	var tree: SceneTree = null
	if from_node != null and is_instance_valid(from_node) and from_node.is_inside_tree():
		tree = from_node.get_tree()
	if tree == null:
		tree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var holders := tree.get_nodes_in_group("vision_service")
	if holders.is_empty():
		return null
	var holder: Node = holders[0]
	if holder.has_meta("vision"):
		return holder.get_meta("vision") as VisionServiceScript
	return holder.get("vision") as VisionServiceScript


static func _team_observers(entities: Node2D, team: Enums.Team) -> Array:
	var observers: Array = []
	if entities == null:
		return observers
	for node in entities.get_children():
		var entity := node as Node2D
		if entity == null or entity.is_queued_for_deletion():
			continue
		# Projectiles share team/sim_pos with actors, but have no health or sight.
		# Check observer capability before reading actor-only properties.
		if not (entity.get("def") is UnitDef or entity.get("def") is BuildingDef):
			continue
		if entity.get("team") != team:
			continue
		if float(entity.get("hp")) <= 0.0:
			continue
		if entity.get("is_placement_ghost") == true:
			continue
		observers.append(entity)
	return observers


static func _is_entity_visible(
	entity: Node2D,
	observers: Array,
	vision: VisionServiceScript
) -> bool:
	if observers.is_empty() or vision == null:
		return true
	for observer in observers:
		if observer == null or not is_instance_valid(observer):
			continue
		for visible in vision.others_in_radius(observer):
			if visible == entity:
				return true
	return false


static func _resource_visible(
	resource: Node2D,
	observers: Array,
	vision: VisionServiceScript
) -> bool:
	if observers.is_empty() or vision == null:
		return true
	var resource_pos: Vector2 = resource.get("sim_pos")
	for observer in observers:
		if observer == null or not is_instance_valid(observer):
			continue
		var radius := vision.vision_radius_of(observer)
		if observer.get("sim_pos").distance_to(resource_pos) <= radius:
			return true
	return false
