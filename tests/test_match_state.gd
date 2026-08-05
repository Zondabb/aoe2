# tests/test_match_state.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var m := MatchState.new()
	m.setup_defaults()
	if not m.can_afford(Enums.Team.PLAYER, 50, 0, 0):
		failures.append("should afford villager")
	m.spend(Enums.Team.PLAYER, 50, 0, 0)
	if m.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) != 150:
		failures.append("food not spent")
	m.population[Enums.Team.PLAYER] = 5
	m.population_cap[Enums.Team.PLAYER] = 5
	var u := UnitDef.new()
	u.cost_food = 0
	u.cost_wood = 0
	u.cost_gold = 0
	u.population = 1
	if m.can_train(Enums.Team.PLAYER, u):
		failures.append("pop full should block")
	if bool(m.frozen):
		failures.append("defaults should not start frozen")
	m.set_winner(Enums.Team.PLAYER)
	if not bool(m.frozen) or m.winner != Enums.Team.PLAYER:
		failures.append("set_winner should freeze the match")
	return failures
