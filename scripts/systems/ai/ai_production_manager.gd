class_name AiProductionManager
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Progression := preload("res://scripts/systems/ai/ai_progression_manager.gd")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
	if ctx.match_state.progression_enabled:
		_train_villagers(ctx, build_manager)
		ensure_house(ctx, build_manager, VILLAGER)
		_train_available_army(ctx)
		return
	if ctx.phase <= 0:  # ECO
		_train_villagers(ctx, build_manager)
		ensure_house(ctx, build_manager, VILLAGER)
	elif ctx.phase == 1:  # BOOM
		_train_military(ctx, build_manager)
		ensure_house(ctx, build_manager, _preferred_military_unit(ctx))
	elif ctx.phase >= 2:  # ATTACK, DEFEND
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


func _try_enqueue(ctx: AiRunContext, building: Node2D, unit_def: UnitDef) -> bool:
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
	if unit_def not in building.call("get_trainable_units") or not ctx.match_state.can_train(ctx.team, unit_def) or not ctx.can_afford(unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone) or Progression.reserves_for_age(ctx, unit_def):
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
			if definition.id in [&"villager", &"petard"] or definition.attack <= 0:
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


func _unit_priority(ctx: AiRunContext, definition: UnitDef) -> int:
	if ctx.profile.unique_unit_priority and definition.id in [&"chu_ko_nu", &"elite_chu_ko_nu", &"teutonic_knight", &"elite_teutonic_knight"]:
		return 30
	var record := Catalog.unit_record(definition.id)
	var id := String(definition.id)
	# Favor main fighting units over support counters, without locking out counters.
	if id in ["militia", "man_at_arms", "long_swordsman", "two_handed_swordsman", "champion", "archer", "crossbowman", "arbalester", "scout_cavalry", "light_cavalry", "hussar", "knight", "cavalier", "paladin", "battering_ram", "capped_ram", "siege_ram"]:
		return 20 + int(record.get("required_age", 0))
	return 10 + definition.required_age
