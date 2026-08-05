# scripts/core/match_state.gd
class_name MatchState
extends RefCounted

signal winner_decided(team: Enums.Team)

var resources: Dictionary = {}
var population: Dictionary = {}
var population_cap: Dictionary = {}
var population_reserved: Dictionary = {}
var winner := -1

func setup_defaults() -> void:
	winner = -1
	for team in Enums.Team.values():
		resources[team] = {
			Enums.ResourceType.FOOD: 200,
			Enums.ResourceType.WOOD: 200,
			Enums.ResourceType.GOLD: 100,
		}
		population[team] = 0
		population_cap[team] = 0
		population_reserved[team] = 0

func get_resource(team: Enums.Team, type: Enums.ResourceType) -> int:
	return resources[team][type]

func can_afford(team: Enums.Team, cost_f: int, cost_w: int, cost_g: int) -> bool:
	var stock: Dictionary = resources[team]
	return stock[Enums.ResourceType.FOOD] >= cost_f \
		and stock[Enums.ResourceType.WOOD] >= cost_w \
		and stock[Enums.ResourceType.GOLD] >= cost_g

func spend(team: Enums.Team, cost_f: int, cost_w: int, cost_g: int) -> bool:
	if not can_afford(team, cost_f, cost_w, cost_g):
		return false
	var stock: Dictionary = resources[team]
	stock[Enums.ResourceType.FOOD] -= cost_f
	stock[Enums.ResourceType.WOOD] -= cost_w
	stock[Enums.ResourceType.GOLD] -= cost_g
	return true

func add_resource(team: Enums.Team, type: Enums.ResourceType, amount: int) -> void:
	resources[team][type] += amount

func can_train(team: Enums.Team, def: UnitDef) -> bool:
	if not can_afford(team, def.cost_food, def.cost_wood, def.cost_gold):
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
	winner_decided.emit(team)
