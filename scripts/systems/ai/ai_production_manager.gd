class_name AiProductionManager
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Progression := preload("res://scripts/systems/ai/ai_progression_manager.gd")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")
const Combat := preload("res://scripts/systems/ai/ai_combat_manager.gd")

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
	if ctx.match_state.progression_enabled:
		_train_villagers(ctx, build_manager)
		ensure_house(ctx, build_manager, VILLAGER)
		_train_siege(ctx)
		_train_available_army(ctx)
		return
	if ctx.phase <= 0:  # ECO
		_train_villagers(ctx, build_manager)
		ensure_house(ctx, build_manager, VILLAGER)
	elif ctx.phase == 1:  # BOOM
		_train_siege(ctx)
		_train_military(ctx, build_manager)
		ensure_house(ctx, build_manager, _preferred_military_unit(ctx))
	elif ctx.phase >= 2:  # ATTACK, DEFEND
		_train_siege(ctx)
		_train_military(ctx, build_manager)
		ensure_house(ctx, build_manager, _preferred_military_unit(ctx))


func _train_villagers(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
	var target := Progression.villager_target(ctx)
	if ctx.blackboard.villager_count >= target:
		return
	var town_center := AiEntityQueriesScript.find_town_center(ctx.blackboard.team_buildings)
	if town_center == null:
		return
	if _try_enqueue(ctx, town_center, VILLAGER):
		ctx.log_decision("PROD", "训练村民 (%d/%d)" % [
			ctx.blackboard.villager_count, target
		])


func _train_military(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
	if ctx.profile.unique_unit_priority and ctx.civ != null and ctx.civ.unique_unit != null:
		var unique := ctx.civ.unique_unit
		var unique_building := _find_building_for_unit(ctx, unique)
		if unique_building != null and _try_enqueue(ctx, unique_building, unique):
			ctx.log_decision("PROD", "训练特色单位 %s" % unique.id)
			return
	for unit_id in ctx.profile.army_composition.keys():
		var unit_def := _unit_def_for_id(unit_id)
		if unit_def == null:
			continue
		var current := _count_unit_id(ctx, unit_id)
		var target := int(ctx.profile.army_composition[unit_id])
		if current >= target:
			continue
		var building := _find_building_for_unit(ctx, unit_def)
		if building != null and _try_enqueue(ctx, building, unit_def):
			ctx.log_decision("PROD", "训练 %s (%d/%d)" % [unit_id, current + 1, target])
			return
	var barracks := AiEntityQueriesScript.find_complete_building(
		ctx.blackboard.team_buildings, &"barracks"
	)
	if barracks != null and _try_enqueue(ctx, barracks, SWORDSMAN):
		ctx.log_decision("PROD", "训练 swordsman (fallback)")
		return
	var archery := AiEntityQueriesScript.find_complete_building(
		ctx.blackboard.team_buildings, &"archery_range"
	)
	if archery != null:
		_try_enqueue(ctx, archery, ARCHER)


func ensure_house(ctx: AiRunContext, build_manager: AiBuildManager, unit_def: UnitDef) -> void:
	build_manager.ensure_house_if_pop_blocked(ctx, unit_def)


func _try_enqueue(ctx: AiRunContext, building: Node2D, unit_def: UnitDef, save_for_age := true) -> bool:
	if building == null or unit_def == null:
		return false
	unit_def = building.call("trainable_definition", unit_def.id)
	if unit_def == null: return false
	if not bool(building.get("is_complete")):
		return false
	if not (building.get("train_queue") as Array).is_empty():
		return false
	if ctx.building_busy(building):
		return false
	if bool(building.call("is_age_researching")) or bool(building.call("is_technology_researching")):
		return false
	if unit_def not in building.call("get_trainable_units") or not ctx.match_state.can_train(ctx.team, unit_def) or not ctx.can_afford(unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone) or (save_for_age and Progression.reserves_for_age(ctx, unit_def)):
		return false
	if save_for_age and _reserves_for_siege(ctx, unit_def):
		return false
	return ctx.issue_train(building, unit_def)


func _find_building_for_unit(ctx: AiRunContext, unit_def: UnitDef) -> Node2D:
	if unit_def == null:
		return null
	for building in ctx.blackboard.team_buildings:
		if bool(building.get("is_complete")) and building.call("trainable_definition", unit_def.id) != null:
			return building
	return null


func _preferred_military_unit(ctx: AiRunContext) -> UnitDef:
	if ctx.civ != null and ctx.civ.unique_unit != null:
		return ctx.civ.unique_unit
	return SWORDSMAN


func _count_unit_id(ctx: AiRunContext, unit_id: StringName) -> int:
	var count := 0
	for unit in ctx.blackboard.team_units:
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == unit_id:
			count += 1
	for building in ctx.blackboard.team_buildings:
		for definition: UnitDef in building.get("train_queue"):
			if definition.id == unit_id:
				count += 1
	if ctx.capture_commands:
		for command in ctx.pending_commands:
			if command.get("op") == "train" and command.get("unit_def_id") == String(unit_id):
				count += 1
	return count


func _unit_def_for_id(unit_id: StringName) -> UnitDef:
	return Catalog.get_unit(String(unit_id))


func _train_available_army(ctx: AiRunContext) -> void:
	# get_trainable_units applies civilization, age, and researched upgrade lines.
	for building in ctx.blackboard.team_buildings:
		var available: Array = building.call("get_trainable_units")
		var candidates: Array[UnitDef] = []
		for definition: UnitDef in available:
			if definition.id in [&"villager", &"petard"] or definition.attack <= 0 or Combat.is_demolition(definition):
				continue
			candidates.append(definition)
		candidates.sort_custom(func(a: UnitDef, b: UnitDef) -> bool:
			var a_priority := _unit_priority(ctx, a)
			var b_priority := _unit_priority(ctx, b)
			if a_priority != b_priority:
				return a_priority > b_priority
			return _count_unit_id(ctx, a.id) < _count_unit_id(ctx, b.id)
		)
		for definition in candidates:
			# Try an affordable alternative when the preferred gold unit is blocked.
			if _try_enqueue(ctx, building, definition):
				ctx.log_decision("PROD", "训练 %s" % definition.id)
				break


func _train_siege(ctx: AiRunContext) -> void:
	# Maintain a small demolition group with enough soldiers to escort it. Reserve
	# its wood/gold before ordinary troops so a productive army cannot starve siege.
	if ctx.blackboard.threat_near_base:
		return
	var needed := _siege_need(ctx)
	if needed.is_empty():
		return
	var producers := ctx.blackboard.team_buildings.duplicate()
	# Imperial-age castles can provide long-range demolition before more rams.
	producers.sort_custom(func(a: Node2D, b: Node2D): return a.get("def").id == &"castle" and b.get("def").id != &"castle")
	for building in producers:
		var candidates: Array[UnitDef] = []
		for definition: UnitDef in building.call("get_trainable_units"):
			if Combat.is_demolition(definition):
				candidates.append(definition)
		candidates.sort_custom(func(a: UnitDef, b: UnitDef): return _demolition_priority(a) > _demolition_priority(b))
		for definition in candidates:
			if _try_enqueue(ctx, building, definition, false):
				ctx.log_decision("PROD", "训练攻城单位 %s (%d/%d)" % [definition.id, needed.count + 1, needed.target])
				return


func _siege_need(ctx: AiRunContext) -> Dictionary:
	if ctx.blackboard.threat_near_base:
		return {}
	var count := 0
	for id in Combat.DEMOLITION_UNITS:
		count += _count_unit_id(ctx, id)
	var living_siege := ctx.blackboard.team_units.filter(func(unit): return Combat.is_demolition(unit.get("def")) and float(unit.get("hp")) > 0.0).size()
	var escorts := ctx.blackboard.military_count - living_siege
	var target := clampi(1 + floori(escorts / 6.0), 1, 4)
	return {"count": count, "target": target} if escorts >= 3 and count < target else {}


func _reserves_for_siege(ctx: AiRunContext, definition: UnitDef) -> bool:
	if Combat.is_demolition(definition) or _siege_need(ctx).is_empty():
		return false
	# Save toward the least expensive legal demolition unit, even while its
	# producer is busy. Otherwise every small gold delivery becomes an archer
	# and the first ram never becomes affordable. Food-only recruits continue.
	var reserve: UnitDef
	for building in ctx.blackboard.team_buildings:
		if not bool(building.get("is_complete")):
			continue
		for candidate: UnitDef in building.call("get_trainable_units"):
			if not Combat.is_demolition(candidate) or not ctx.match_state.unit_unlocked(ctx.team, candidate):
				continue
			if reserve == null or candidate.cost_wood + candidate.cost_gold < reserve.cost_wood + reserve.cost_gold:
				reserve = candidate
	if reserve == null:
		return false
	return (definition.cost_wood > 0 and ctx.available_resource(Enums.ResourceType.WOOD) - definition.cost_wood < reserve.cost_wood) or (definition.cost_gold > 0 and ctx.available_resource(Enums.ResourceType.GOLD) - definition.cost_gold < reserve.cost_gold)


func _demolition_priority(definition: UnitDef) -> int:
	if definition.id in [&"trebuchet", &"bombard_cannon"]:
		return 40
	if definition.id in [&"battering_ram", &"capped_ram", &"siege_ram"]:
		return 30 + definition.required_age
	return 20 + definition.required_age


func _unit_priority(ctx: AiRunContext, definition: UnitDef) -> int:
	if ctx.profile.unique_unit_priority and definition.id in [&"chu_ko_nu", &"elite_chu_ko_nu", &"teutonic_knight", &"elite_teutonic_knight"]:
		return 30
	var record := Catalog.unit_record(definition.id)
	var id := String(definition.id)
	# Favor main fighting units over support counters, without locking out counters.
	if id in ["militia", "man_at_arms", "long_swordsman", "two_handed_swordsman", "champion", "archer", "crossbowman", "arbalester", "scout_cavalry", "light_cavalry", "hussar", "knight", "cavalier", "paladin", "battering_ram", "capped_ram", "siege_ram"]:
		return 20 + int(record.get("required_age", 0))
	return 10 + definition.required_age
