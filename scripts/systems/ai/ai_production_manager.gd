class_name AiProductionManager
extends RefCounted

const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")

const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


func tick(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
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
	if ctx.blackboard.villager_count >= ctx.profile.villager_target:
		return
	var town_center := AiEntityQueriesScript.find_town_center(ctx.blackboard.team_buildings)
	if town_center == null:
		return
	if _try_enqueue(ctx, town_center, VILLAGER):
		ctx.log_decision("PROD", "训练村民 (%d/%d)" % [
			ctx.blackboard.villager_count, ctx.profile.villager_target
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
	if not bool(building.get("is_complete")):
		return false
	if not (building.get("train_queue") as Array).is_empty():
		return false
	return bool(building.call("enqueue_train", unit_def))


func _find_building_for_unit(ctx: AiRunContext, unit_def: UnitDef) -> Node2D:
	if unit_def == null:
		return null
	if unit_def.id == &"teutonic_knight":
		return AiEntityQueriesScript.find_complete_building(
			ctx.blackboard.team_buildings, &"stable"
		)
	if unit_def.id == &"chu_ko_nu" or unit_def.id == &"archer":
		return AiEntityQueriesScript.find_complete_building(
			ctx.blackboard.team_buildings, &"archery_range"
		)
	if unit_def.id == &"swordsman":
		return AiEntityQueriesScript.find_complete_building(
			ctx.blackboard.team_buildings, &"barracks"
		)
	if unit_def.id == &"villager":
		return AiEntityQueriesScript.find_town_center(ctx.blackboard.team_buildings)
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
	return count


func _unit_def_for_id(unit_id: StringName) -> UnitDef:
	match unit_id:
		&"villager":
			return VILLAGER
		&"swordsman":
			return SWORDSMAN
		&"archer":
			return ARCHER
		&"chu_ko_nu":
			return load("res://data/units/chu_ko_nu.tres") as UnitDef
		&"teutonic_knight":
			return load("res://data/units/teutonic_knight.tres") as UnitDef
		_:
			return null
