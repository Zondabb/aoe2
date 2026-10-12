extends SceneTree

const Director := preload("res://scripts/systems/ai/ai_director.gd")
const Combat := preload("res://scripts/systems/ai/ai_combat_manager.gd")
const Army := preload("res://scripts/systems/ai/ai_army_manager.gd")
const Context := preload("res://scripts/systems/ai/ai_run_context.gd")
const Blackboard := preload("res://scripts/systems/ai/ai_blackboard.gd")
const Profile := preload("res://scripts/data/civ_ai_profile.gd")
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const BuildingView := preload("res://scenes/entities/building_view.tscn")
const Catalog := preload("res://scripts/data/game_catalog.gd")
var checks := 0
var failures: Array[String] = []
var entities: Node2D
var state: MatchState


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)


func _run() -> void:
	entities = Node2D.new()
	root.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.fog_enabled = false
	state.progression_enabled = false
	state.map_bounds = Rect2(-240, -240, 480, 480)
	var own_tc := _building(Enums.Team.AI, Vector2(120, 120))
	var enemy_tc := _building(Enums.Team.PLAYER, Vector2(-120, -120))
	var soldier := _unit(Enums.Team.AI, Vector2(118, 120), "swordsman")
	var director := Director.new()
	root.add_child(director)
	director.setup(state, entities, load("res://data/civs/teutons.tres"), 1, 0, "AI", null, false)
	director.director_phase = Director.Phase.ATTACK
	director.match_time = 200
	var first := director.evaluate_capture(1)
	var soldier_commands := _commands(first, soldier)
	check(soldier_commands.size() == 1 and soldier_commands[0].op == "attack", "initial attack has exactly one effective order, with no rally MOVE")
	soldier.command_attack(enemy_tc)
	for tick in range(2, 12):
		var following := director.evaluate_capture(tick)
		check(_commands(following, soldier).is_empty(), "following attack tick %d preserves the same live target" % tick)
	var raider := _unit(Enums.Team.PLAYER, Vector2(130, 125), "swordsman")
	soldier.sim_pos = Vector2(-60, -60)
	director.director_phase = Director.Phase.ECO
	var defense := director.evaluate_capture(20)
	var defense_commands := _commands(defense, soldier)
	check(director.director_phase == Director.Phase.DEFEND, "opening phase responds immediately to a base raid")
	check(defense_commands.size() == 1 and defense_commands[0].op == "attack" and defense_commands[0].target_id == EntityRegistry.id_of(raider), "distant soldiers intercept a base raider instead of attacking the enemy TC")
	soldier.command_attack(raider)
	check(_commands(director.evaluate_capture(21), soldier).is_empty(), "defense keeps a valid interception attack instead of recalling the soldier")
	# With only the threat flag and no currently visible raider, pull troops
	# home; a visible distant town center must not override this MOVE.
	raider.free()
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.phase = Director.Phase.DEFEND
	ctx.profile = director.profile
	ctx.blackboard = Blackboard.new()
	ctx.blackboard.team_units.append(soldier)
	ctx.blackboard.team_buildings.append(own_tc)
	ctx.blackboard.own_tc_pos = own_tc.sim_pos
	ctx.begin_capture(22)
	var combat := Combat.new()
	var army := Army.new()
	army.rally_to_base(ctx, combat.tick_army(ctx))
	var recall := ctx.end_capture()
	check(_commands(recall, soldier).size() == 1 and _commands(recall, soldier)[0].op == "move", "no visible base target recalls troops without an enemy TC attack")
	# Army search itself reads only public map geometry, leaves dedicated
	# scouts free, suppresses duplicate moves, and advances a stuck waypoint.
	soldier.order = Enums.OrderType.NONE
	ctx.phase = Director.Phase.ATTACK
	ctx.blackboard.map_bounds = state.map_bounds
	ctx.blackboard.match_time = 0
	var scout := _unit(Enums.Team.AI, Vector2(106, 128), "scout_cavalry")
	ctx.blackboard.team_units.append(scout)
	army.reset()
	ctx.begin_capture(30)
	army.rally(ctx)
	var search := ctx.end_capture()
	var search_commands := _commands(search, soldier)
	check(search_commands.size() == 1 and search_commands[0].pos == [0.0, 0.0], "idle army probes the public map center when enemy position is unknown")
	check(_commands(search, scout).is_empty(), "army search preserves the dedicated scout")
	soldier.order = Enums.OrderType.MOVE
	ctx.blackboard.match_time = 1
	ctx.begin_capture(31)
	army.rally(ctx)
	check(ctx.end_capture().commands.is_empty(), "live search route does not spam MOVE commands")
	ctx.blackboard.match_time = 9
	ctx.begin_capture(32)
	army.rally(ctx)
	var advanced := _commands(ctx.end_capture(), soldier)
	check(advanced.size() == 1 and advanced[0].pos == [-120.0, -120.0], "stalled army search moves on to the opposite public sector")
	state.frozen = true
	director.free()
	entities.free()
	print("AI COMBAT STRATEGY: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _commands(response: Dictionary, unit: Node2D) -> Array:
	var id := EntityRegistry.id_of(unit)
	return response.commands.filter(func(command): return command.get("unit_id", -1) == id)


func _unit(team: int, position: Vector2, definition: String) -> UnitAgent:
	var unit := UnitView.instantiate() as UnitAgent
	unit.team = team
	var definition_path := "res://data/units/%s.tres" % definition
	unit.def = load(definition_path) if ResourceLoader.exists(definition_path) else Catalog.get_unit(definition)
	unit.civ = load("res://data/civs/teutons.tres")
	unit.match_state = state
	unit.sim_pos = position
	entities.add_child(unit)
	unit.set_physics_process(false)
	return unit


func _building(team: int, position: Vector2) -> BuildingAgent:
	var building := BuildingView.instantiate() as BuildingAgent
	building.team = team
	building.def = load("res://data/buildings/town_center.tres")
	building.civ = load("res://data/civs/teutons.tres")
	building.match_state = state
	building.sim_pos = position
	entities.add_child(building)
	building.set_physics_process(false)
	return building
