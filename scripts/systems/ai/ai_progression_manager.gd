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
		var army_ready := age == 0 or (not ctx.blackboard.threat_near_base and ctx.blackboard.military_count >= ctx.profile.military_attack_count)
		if army_ready and ctx.match_state.age_progression.can_advance(tc) and ctx.issue_age_upgrade(tc):
			ctx.log_decision("RESEARCH", "升级时代 %d → %d" % [age, age + 1])
			return
		# Establish a producer before spending wood on later-age prerequisites.
		if age >= 1 and not Queries.has_building(ctx.blackboard.team_buildings, &"barracks"):
			build_manager.ensure_building(ctx, Catalog.get_building("barracks"))
			return
		if ctx.blackboard.incomplete_buildings == 0 and not ctx.match_state.age_progression.has_prerequisites(ctx.team, age + 1):
			for building_id in PREREQUISITES[age]:
				if not Queries.has_building(ctx.blackboard.team_buildings, StringName(building_id)):
					build_manager.ensure_building(ctx, Catalog.get_building(building_id))
					return


func tick_technologies(ctx: AiRunContext) -> void:
	if not ctx.match_state.progression_enabled or ctx.match_state.age_progression == null or ctx.blackboard.threat_near_base or ctx.blackboard.military_count < ctx.profile.military_attack_count:
		return
	var age := ctx.match_state.age_of(ctx.team)
	# Troops get first use of the budget and idle production buildings.
	if age >= 1 and (age == 3 or ctx.match_state.age_progression.is_researching(ctx.team)):
		var technologies: Node = ctx.match_state.technology_progression
		if technologies == null:
			return
		for building in ctx.blackboard.team_buildings:
			if ctx.building_busy(building):
				continue
			for technology in technologies.available(building):
				var technology_id := String(technology.get("id", "")) if technology is Dictionary else String(technology)
				var record: Dictionary = Catalog.technologies().get(technology_id, {})
				if String(record.get("from", "")).is_empty() and technology_id != "chemistry":
					continue
				if not technology_id.is_empty() and String(technologies.blocked_reason(building, technology_id)).is_empty() and ctx.issue_technology(building, technology_id):
					return


static func villager_target(ctx: AiRunContext) -> int:
	return maxi(8, ctx.profile.villager_target) + ctx.match_state.age_of(ctx.team) * 4 if ctx.match_state.progression_enabled else ctx.profile.villager_target


static func reserves_for_age(ctx: AiRunContext, unit_def: UnitDef) -> bool:
	if not ctx.match_state.progression_enabled or ctx.match_state.age_progression == null:
		return false
	var age := ctx.match_state.age_of(ctx.team)
	if age >= 3 or ctx.match_state.age_progression.is_researching(ctx.team):
		return false
	if ctx.capture_commands:
		for command in ctx.pending_commands:
			if command.get("op") == "research_age":
				return false
	# An age fund must not starve the economy, initial army or emergency defense.
	if ctx.blackboard.threat_near_base or ctx.blackboard.villager_count < villager_target(ctx) or ctx.blackboard.military_count < ctx.profile.military_attack_count:
		return false
	if not ctx.match_state.age_progression.has_prerequisites(ctx.team, age + 1):
		return false
	return ctx.available_resource(Enums.ResourceType.FOOD) - unit_def.cost_food < FOOD_COST[age] or ctx.available_resource(Enums.ResourceType.GOLD) - unit_def.cost_gold < GOLD_COST[age]
