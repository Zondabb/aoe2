# scripts/core/match_state.gd
class_name MatchState
extends RefCounted

signal winner_decided(team: Enums.Team)
signal team_color_changed(team: int)
signal age_changed(team: int, age: int)
signal age_progress_changed(team: int, progress: Dictionary)
signal technology_changed(team: int, technology_id: StringName)

const TeamColorCatalogScript := preload("res://scripts/presentation/team_color_catalog.gd")

var resources: Dictionary = {}
var population: Dictionary = {}
var population_cap: Dictionary = {}
var population_reserved: Dictionary = {}
## Formal matches opt into the original four-age land technology tree.
var progression_enabled := false
var team_ages: Dictionary = {}
var team_civilizations: Dictionary = {}
var researched_technologies: Dictionary = {}
var unit_catalog: Array[UnitDef] = []
var age_progression: Node
var technology_progression: Node
## Visual palette selection only; combat ownership still uses Enums.Team.
var team_color_ids: Dictionary = {}
## Enabled explicitly by 2D match bootstraps; legacy fixtures opt out.
var fog_enabled := false
var fog: RefCounted
## Public geometry for AI placement/scouting; an empty rect denotes a legacy arena.
var map_bounds := Rect2()
var winner := -1
## When true, unit/building simulation should early-return (match ended).
var frozen := false

func setup_defaults() -> void:
	if fog != null:
		fog.reset()
	winner = -1
	frozen = false
	team_color_ids.clear()
	for team in Enums.Team.values():
		team_color_ids[team] = TeamColorCatalogScript.default_color_id(team)
		team_ages[team] = Enums.Age.DARK
		researched_technologies[team] = {}
		resources[team] = {
			Enums.ResourceType.FOOD: 200,
			Enums.ResourceType.WOOD: 200,
			Enums.ResourceType.GOLD: 100,
			Enums.ResourceType.STONE: 200,
		}
		population[team] = 0
		population_cap[team] = 0
		population_reserved[team] = 0
		team_color_changed.emit(team)

func get_team_color_id(team: int) -> int:
	var color_id := int(team_color_ids.get(team, TeamColorCatalogScript.default_color_id(team)))
	return color_id if TeamColorCatalogScript.is_valid_color_id(color_id) else TeamColorCatalogScript.default_color_id(team)

func set_team_color_id(team: int, color_id: int) -> bool:
	if team not in Enums.Team.values() or not TeamColorCatalogScript.is_valid_color_id(color_id):
		return false
	if get_team_color_id(team) == color_id:
		return true
	team_color_ids[team] = color_id
	team_color_changed.emit(team)
	return true

func get_resource(team: Enums.Team, type: Enums.ResourceType) -> int:
	return int(resources.get(team, {}).get(type, 0))

func can_afford(team: Enums.Team, cost_f: int, cost_w: int, cost_g: int, cost_s: int = 0) -> bool:
	return get_resource(team, Enums.ResourceType.FOOD) >= cost_f \
		and get_resource(team, Enums.ResourceType.WOOD) >= cost_w \
		and get_resource(team, Enums.ResourceType.GOLD) >= cost_g \
		and get_resource(team, Enums.ResourceType.STONE) >= cost_s

func spend(team: Enums.Team, cost_f: int, cost_w: int, cost_g: int, cost_s: int = 0) -> bool:
	if not can_afford(team, cost_f, cost_w, cost_g, cost_s):
		return false
	var stock: Dictionary = resources[team]
	stock[Enums.ResourceType.FOOD] -= cost_f
	stock[Enums.ResourceType.WOOD] -= cost_w
	stock[Enums.ResourceType.GOLD] -= cost_g
	stock[Enums.ResourceType.STONE] = int(stock.get(Enums.ResourceType.STONE, 0)) - cost_s
	return true

func add_resource(team: Enums.Team, type: Enums.ResourceType, amount: int) -> void:
	resources[team][type] = get_resource(team, type) + amount

func age_of(team: int) -> int:
	return int(team_ages.get(team, Enums.Age.DARK))

func get_age(team: int) -> int:
	return age_of(team)

func set_age(team: int, age: int) -> void:
	if team not in Enums.Team.values() or age < Enums.Age.DARK or age > Enums.Age.IMPERIAL:
		return
	if age_of(team) == age:
		return
	team_ages[team] = age
	if fog != null:
		fog.dirty = true
	age_changed.emit(team, age)

func has_technology(team: int, technology_id: StringName) -> bool:
	return technology_id == &"" or bool(researched_technologies.get(team, {}).get(technology_id, false))

func unit_unlocked(team: int, unit_def: UnitDef, civilization_id: StringName = &"") -> bool:
	if unit_def == null:
		return false
	if not progression_enabled:
		return true
	if civilization_id == &"":
		civilization_id = StringName(team_civilizations.get(team, &""))
	return unit_def.required_age <= age_of(team) \
		and (unit_def.civilizations.is_empty() or civilization_id in unit_def.civilizations) \
		and has_technology(team, unit_def.required_technology)

func can_train(team: Enums.Team, def: UnitDef, civilization_id: StringName = &"") -> bool:
	if not unit_unlocked(team, def, civilization_id) or not can_afford(team, def.cost_food, def.cost_wood, def.cost_gold, def.cost_stone):
		return false
	return (
		population[team]
		+ population_reserved[team]
		+ def.population
		<= population_cap[team]
	)

func register_pop(team: Enums.Team, used_delta: int, cap_delta: int) -> void:
	population[team] += used_delta
	population_cap[team] += cap_delta

func reserve_pop(team: Enums.Team, amount: int) -> void:
	population_reserved[team] += amount

func set_winner(team: Enums.Team) -> void:
	if winner != -1:
		return
	winner = team
	frozen = true
	winner_decided.emit(team)
