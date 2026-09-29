class_name AiProgressionManager
extends RefCounted

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Queries := preload("res://scripts/systems/ai/ai_entity_queries.gd")

# Favor affordable economic prerequisites, then reserve resources for the age button.
const PREREQUISITES := [["mill", "lumber_camp"], ["blacksmith", "market"], ["monastery", "university"]]
const FOOD_COST := [500, 800, 1000]
const GOLD_COST := [0, 200, 800]


func tick(ctx: AiRunContext, build_manager: AiBuildManager) -> void:
	if not ctx.match_state.progression_enabled or ctx.match_state.age_progression == null:
		return
	var age := ctx.match_state.age_of(ctx.team)
	var tc := Queries.find_town_center(ctx.blackboard.team_buildings)
	if tc == null:
		return
	if age < 3 and not ctx.match_state.age_progression.is_researching(ctx.team):
		if ctx.match_state.age_progression.can_advance(tc):
			ctx.issue_age_upgrade(tc)
			ctx.log_decision("RESEARCH", "升级时代 %d → %d" % [age, age + 1])
			return
		if ctx.blackboard.incomplete_buildings == 0:
			for building_id in PREREQUISITES[age]:
				if not Queries.has_building(ctx.blackboard.team_buildings, StringName(building_id)):
					build_manager.ensure_building(ctx, Catalog.get_building(building_id))
					return
	# Upgrade available army lines while an age is being researched or at Imperial.
	if age >= 1 and (age == 3 or ctx.match_state.age_progression.is_researching(ctx.team)):
		var technologies: Node = ctx.match_state.technology_progression
		if technologies == null:
			return
		for building in ctx.blackboard.team_buildings:
			for technology in technologies.available(building):
				var technology_id := String(technology.get("id", "")) if technology is Dictionary else String(technology)
				if not technology_id.is_empty() and String(technologies.blocked_reason(building, technology_id)).is_empty():
					ctx.issue_technology(building, technology_id)
					return


static func reserves_for_age(ctx: AiRunContext, unit_def: UnitDef) -> bool:
	if not ctx.match_state.progression_enabled or ctx.match_state.age_progression == null:
		return false
	var age := ctx.match_state.age_of(ctx.team)
	if age >= 3 or ctx.match_state.age_progression.is_researching(ctx.team):
		return false
	# Build an initial economy before accumulating the age-up cost.
	if unit_def.id == &"villager" and ctx.blackboard.villager_count < 8:
		return false
	return ctx.blackboard.food - unit_def.cost_food < FOOD_COST[age] or ctx.blackboard.gold - unit_def.cost_gold < GOLD_COST[age]
