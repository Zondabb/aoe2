extends SceneTree

const Queries := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const BuildRules := preload("res://scripts/systems/build_system.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Manager := preload("res://scripts/systems/ai/ai_build_manager.gd")

class PlannedBuilding extends Node2D:
	var def: BuildingDef
	var sim_pos := Vector2.ZERO
	var is_placement_ghost := false
	var match_state: MatchState
	var team := Enums.Team.AI
	var hp := 1000.0
	var is_complete := true

class PlannedBootstrap extends Node:
	var map_bounds := Rect2(-10, -10, 20, 20)

class PlannedUnit extends Node2D:
	var def: UnitDef
	var order := Enums.OrderType.NONE
	var carry_amount := 0.0

class PlannedResource extends Node2D:
	var resource_type := Enums.ResourceType.WOOD
	var amount := 100.0
	var sim_pos := Vector2.ZERO
	func extract(_delta: float) -> float:
		return 0.0
	func selection_footprint(type: Enums.ResourceType) -> Vector2:
		return ResourceNode.selection_footprint(type)

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _building(id: String, pos: Vector2) -> PlannedBuilding:
	var building := PlannedBuilding.new()
	building.def = Catalog.get_building(id)
	building.sim_pos = pos
	return building

func _run() -> void:
	var entities := Node2D.new()
	root.add_child(entities)
	var tc := _building("town_center", Vector2.ZERO)
	entities.add_child(tc)
	var house := Catalog.get_building("house")
	check(BuildRules.can_place(house.footprint, Vector2(6, 0), [tc]), "player legality still allows a nearby house")
	check(not Queries.can_plan_settlement(house.footprint, Vector2(6, 0), [tc]), "AI rejects overlapping visual grounds")
	check(Queries.can_plan_settlement(house.footprint, Vector2(16, 0), [tc]), "AI reserves one original tile lane")
	check(not Queries.can_plan_settlement(house.footprint, Vector2(15.99, 0), [tc]), "a narrow lane is rejected")
	check(Queries.next_build_position(house, tc, entities, 0) == Vector2(16, 0), "first deterministic inward slot matches Python")
	var gold := PlannedResource.new()
	gold.resource_type = Enums.ResourceType.GOLD
	gold.sim_pos = Vector2(16, 0)
	entities.add_child(gold)
	check(Queries.next_build_position(house, tc, entities, 0) == Vector2(0, 16), "a mine occupies the first slot and keeps its gather route")
	check(not Queries.can_plan_settlement(house.footprint, Vector2(24, 0), [], [gold]), "mining space beside deposits is protected")
	gold.amount = 0
	check(Queries.next_build_position(house, tc, entities, 0) == Vector2(16, 0), "depleted nodes release their planned space")
	gold.queue_free()
	await process_frame
	var bootstrap := PlannedBootstrap.new()
	bootstrap.name = "Bootstrap"
	entities.add_child(bootstrap)
	check(Queries.next_build_position(house, tc, entities, 0) == null, "a tiny custom map cannot force settlement outside its edges")
	bootstrap.map_bounds = Rect2(-240, -180, 480, 360)
	check(Queries.next_build_position(house, tc, entities, 0) == Vector2(16, 0), "the planner reads actual rectangular map bounds")
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = true
	state.fog = Fog.new()
	state.fog.setup_rect(Vector2(-240, -180), Vector2(240, 180))
	tc.match_state = state
	state.fog.rebuild([tc])
	var hidden_gold := PlannedResource.new()
	hidden_gold.resource_type = Enums.ResourceType.GOLD
	hidden_gold.sim_pos = Vector2(34, 0)
	entities.add_child(hidden_gold)
	check(not state.fog.can_see(tc.team, hidden_gold), "resource outside team vision is hidden")
	check(Queries.next_build_position(house, tc, entities, 5) == Vector2(24, 0), "AI does not use hidden resource positions for planning")
	hidden_gold.sim_pos = Vector2(24, 0)
	check(state.fog.can_see(tc.team, hidden_gold), "resource inside team vision is observed")
	check(Queries.next_build_position(house, tc, entities, 5) == Vector2(0, 24), "the observed deposit preserves gathering space")
	hidden_gold.queue_free()
	tc.match_state = null
	await process_frame
	tc.sim_pos = Vector2(-100, -80)
	var bounds := Rect2(-240, -180, 480, 360)
	var buildings: Array = [tc]
	var names := ["house", "barracks", "house", "castle", "house"]
	for slot in 25:
		var definition := Catalog.get_building(names[slot % names.size()])
		var pos: Variant = Queries.next_build_position(definition, tc, entities, slot)
		check(pos is Vector2, "mixed settlement can place building %d" % slot)
		if not pos is Vector2:
			continue
		check(Queries.can_plan_settlement(definition.footprint, pos, buildings, [], bounds), "visual footprint, road and rectangular edge clearance for building %d" % slot)
		check(Queries.next_build_position(definition, tc, entities, slot) == pos, "planning is deterministic for building %d" % slot)
		var building := _building(names[slot % names.size()], pos)
		buildings.append(building)
		entities.add_child(building)
	check(Queries.can_plan_settlement(house.footprint, Vector2(232, 172), [], [], bounds), "edge margin can exactly fit")
	check(not Queries.can_plan_settlement(house.footprint, Vector2(232.01, 172), [], [], bounds), "visual ground must remain inside right edge")
	check(not Queries.can_plan_settlement(house.footprint, Vector2(232, 172.01), [], [], bounds), "visual ground must remain inside bottom edge")
	var ghost := _building("town_center", Vector2(200, 100))
	ghost.is_placement_ghost = true
	entities.add_child(ghost)
	check(Queries.can_plan_settlement(house.footprint, ghost.sim_pos, [ghost]), "temporary ghosts do not consume settlement slots")
	entities.queue_free()
	await process_frame
	await _test_batch_capture()
	print("SETTLEMENT SPACING: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_batch_capture() -> void:
	var entities := Node2D.new()
	root.add_child(entities)
	var tc := _building("town_center", Vector2(-100, -80))
	entities.add_child(tc)
	var villager := PlannedUnit.new()
	villager.def = Catalog.get_unit("villager")
	entities.add_child(villager)
	var ctx := AiRunContext.new()
	ctx.match_state = MatchState.new()
	ctx.match_state.setup_defaults()
	ctx.match_state.population_cap[Enums.Team.AI] = 5  # The stub TC does not register housing.
	for resource in Enums.ResourceType.values():
		ctx.match_state.resources[Enums.Team.AI][resource] = 10000
	ctx.entities = entities
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.team = Enums.Team.AI
	ctx.blackboard = AiBlackboard.new()
	ctx.blackboard.team_villagers.append(villager)
	ctx.blackboard.team_buildings.append(tc)
	ctx.begin_capture(1)
	ctx.issue_train(tc, villager.def)
	var manager := Manager.new()
	check(manager.ensure_building(ctx, Catalog.get_building("barracks")), "a batch can plan its first foundation alongside training")
	check(not manager.ensure_building(ctx, Catalog.get_building("stable")), "a second captured foundation waits for the next observation")
	check(ctx.pending_commands.size() == 2 and ctx.pending_commands[0].op == "train", "the placement limit retains unrelated commands")
	var first: Dictionary = ctx.pending_commands[1]
	var barracks := _building("barracks", Vector2(first.pos[0], first.pos[1]))
	entities.add_child(barracks)
	ctx.blackboard.team_buildings.append(barracks)
	ctx.begin_capture(2)
	check(manager.ensure_building(ctx, Catalog.get_building("stable")), "new observed foundations permit the next decision's construction")
	var second: Dictionary = ctx.pending_commands[0]
	check(Queries.can_plan_settlement(Catalog.get_building("stable").footprint, Vector2(second.pos[0], second.pos[1]), [tc, barracks]), "the second batch leaves a lane around its observed predecessor")
	entities.queue_free()
	await process_frame
