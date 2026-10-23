extends SceneTree
## Exercise actual local/captured AI orders, including production and wall legality.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Combat := preload("res://scripts/systems/ai/ai_combat_manager.gd")
const Army := preload("res://scripts/systems/ai/ai_army_manager.gd")
const Production := preload("res://scripts/systems/ai/ai_production_manager.gd")
const Build := preload("res://scripts/systems/ai/ai_build_manager.gd")
const Defense := preload("res://scripts/systems/ai/ai_defense_manager.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Unit := preload("res://scenes/entities/unit_view.tscn")
const Building := preload("res://scenes/entities/building_view.tscn")
var world: Node2D
var ctx: AiRunContext
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func fixture(age := 2) -> void:
	if is_instance_valid(world):
		world.free()
	world = Node2D.new()
	root.add_child(world)
	world.process_mode = Node.PROCESS_MODE_DISABLED
	ctx = AiRunContext.new()
	ctx.match_state = MatchState.new()
	ctx.match_state.setup_defaults()
	ctx.match_state.progression_enabled = true
	ctx.match_state.fog_enabled = false
	ctx.match_state.set_age(Enums.Team.AI, age)
	ctx.match_state.map_bounds = Rect2(-160, -160, 320, 320)
	ctx.match_state.population_cap[Enums.Team.AI] = 100
	ctx.match_state.unit_catalog.assign(Catalog.units().values())
	ctx.match_state.team_civilizations = {Enums.Team.AI: &"teutons"}
	ctx.entities = world
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.phase = 2
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.profile = CivAiProfile.for_civ(ctx.civ)
	ctx.blackboard = AiBlackboard.new()
	for type in 4:
		ctx.match_state.resources[ctx.team][type] = 2000

func unit(id: String, pos: Vector2, enemy := false) -> UnitAgent:
	var actor := Unit.instantiate() as UnitAgent
	actor.def = Catalog.get_unit(id)
	actor.civ = ctx.civ
	actor.match_state = ctx.match_state
	actor.team = ctx.enemy_team if enemy else ctx.team
	actor.sim_pos = pos
	world.add_child(actor)
	return actor

func building(id: String, pos: Vector2, enemy := false) -> BuildingAgent:
	var actor := Building.instantiate() as BuildingAgent
	actor.def = Catalog.get_building(id)
	actor.civ = ctx.civ
	actor.match_state = ctx.match_state
	actor.team = ctx.enemy_team if enemy else ctx.team
	actor.sim_pos = pos
	world.add_child(actor)
	return actor

func capture(match_time := 240.0) -> void:
	ctx.blackboard.refresh(ctx.match_state, world, ctx.team, ctx.enemy_team, match_time, ctx.profile.defend_radius)
	ctx.begin_capture(checks)

func attacks(actor: Node2D, target: Node2D) -> bool:
	return ctx.pending_commands.any(func(c): return c.op == "attack" and int(c.unit_id) == Registry.id_of(actor) and int(c.target_id) == Registry.id_of(target))

func execute() -> void:
	var execution := CommandExecutionContext.new()
	execution.match_state = ctx.match_state
	execution.entities = world
	execution.team = ctx.team
	execution.civ = ctx.civ
	for command in ctx.pending_commands:
		var result := Executor.execute(command, execution)
		check(result.ok, "captured %s executes legally: %s" % [command.op, result.reason])

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	fixture()
	var tc := building("town_center", Vector2(80, 0), true)
	var wall := building("stone_wall", Vector2(40, 0), true)
	building("stone_wall", Vector2(10, 25), true)
	var ram := unit("battering_ram", Vector2.ZERO)
	var soldier := unit("militia", Vector2(0, 2))
	var worker := unit("villager", Vector2(6, 4), true)
	var fighter := unit("militia", Vector2(8, 0), true)
	ram.command_attack(worker)
	soldier.command_attack(tc)
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(ram, wall), "ram breaches a wall on its TC route instead of chasing nearby villagers")
	check(attacks(soldier, fighter), "escort intercepts enemy soldiers instead of attacking TC or nearby workers")
	execute()
	capture()
	Combat.new().tick_army(ctx)
	check(ctx.pending_commands.is_empty(), "valid breach and escort orders remain stable")
	fighter.free()
	wall.free()
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(ram, tc), "ram switches to enemy TC when its breach is cleared")
	check(attacks(soldier, worker), "soldier raids villagers once nearby enemy soldiers are gone")
	wall = building("gate", Vector2(40, 0), true)
	wall.wall_orientation = 2
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(ram, wall), "enemy gate on the route is a demolition target")
	ram.command_attack(wall)
	check(wall.set_gate_state("open") and wall.gate_open, "enemy gate opens through the real gate mechanism")
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(ram, tc), "ram leaves an opened enemy gate and continues toward TC")
	var trebuchet := unit("trebuchet", Vector2(20, 0))
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(trebuchet, tc), "in-range trebuchet shoots over the wall to destroy TC")
	worker.free()
	wall.free()
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(soldier, tc), "soldiers still finish buildings when no enemy manpower is visible")

	fixture()
	tc = building("town_center", Vector2(18, 0), true)
	var mangonel := unit("mangonel", Vector2.ZERO)
	var escort := unit("militia", Vector2(15, 0))
	mangonel.command_attack(tc)
	capture()
	var unsafe_engaged := Combat.new().tick_army(ctx)
	Army.new().rally(ctx, unsafe_engaged)
	check(not attacks(mangonel, tc) and ctx.pending_commands.any(func(c): return c.op == "move" and int(c.unit_id) == Registry.id_of(mangonel)), "artillery cancels a previous attack when an escort enters the blast area")
	execute()
	check(mangonel.order != Enums.OrderType.ATTACK, "unsafe artillery order is actually canceled before projectile release")
	escort.sim_pos = Vector2(15, 20)
	capture()
	Combat.new().tick_army(ctx)
	check(attacks(mangonel, tc), "artillery resumes demolition after escorts clear the impact area")

	fixture()
	var own_tc := building("town_center", Vector2(-80, 0))
	tc = building("town_center", Vector2(80, 0), true)
	ram = unit("battering_ram", Vector2(40, 0))
	var guards: Array[UnitAgent] = []
	for index in 4:
		guards.append(unit("militia", Vector2(-76 + index, 0)))
	var raider := unit("militia", Vector2(-78, 4), true)
	var victim := unit("villager", Vector2(60, 0), true)
	ctx.phase = 3
	capture()
	var combat := Combat.new()
	var engaged := combat.tick_army(ctx)
	Army.new().rally_to_base(ctx, engaged)
	check(attacks(guards[0], raider) and attacks(guards[1], raider), "nearby guards answer a small raid")
	check(attacks(ram, tc), "adequate guards let demolition continue instead of recalling the entire army")
	check(attacks(guards[2], victim) and attacks(guards[3], victim), "surplus soldiers keep pressure on the enemy economy")
	own_tc.hp = own_tc.def.max_hp * 0.2
	capture()
	engaged = combat.tick_army(ctx)
	Army.new().rally_to_base(ctx, engaged)
	check(guards.all(func(g): return attacks(g, raider)), "critical TC health calls every soldier back to intercept")
	check(ctx.pending_commands.any(func(c): return c.op == "move" and int(c.unit_id) == Registry.id_of(ram)), "critical TC health recalls demolition units to the protected base")

	fixture()
	building("siege_workshop", Vector2(-40, 30))
	building("archery_range", Vector2(-60, 30))
	for index in 6:
		unit("militia", Vector2(-30 + index, 0))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 0
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 160
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 75
	capture()
	Production.new().tick(ctx, Build.new())
	check(ctx.pending_commands.any(func(c): return c.op == "train" and c.unit_def_id == "battering_ram"), "first ram receives wood/gold before ordinary ranged troops")
	execute()
	unit("battering_ram", Vector2(-20, 0))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 2000
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 2000
	capture()
	Production.new().tick(ctx, Build.new())
	check(not ctx.pending_commands.any(func(c): return c.op == "train" and Combat.is_demolition(Catalog.get_unit(c.unit_def_id))), "queued and living siege both count toward the escort-based limit")

	fixture()
	building("siege_workshop", Vector2(-40, 30))
	building("archery_range", Vector2(-60, 30))
	for index in 6:
		unit("militia", Vector2(-30 + index, 0))
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 0
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 160
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 45
	capture()
	Production.new().tick(ctx, Build.new())
	check(not ctx.pending_commands.any(func(c): return c.op == "train"), "partial ram savings are preserved instead of becoming another archer")
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 75
	capture()
	Production.new().tick(ctx, Build.new())
	check(ctx.pending_commands.any(func(c): return c.op == "train" and c.unit_def_id == "battering_ram"), "next gold delivery completes the saved ram budget")
	building("town_center", Vector2(-80, -80))
	unit("militia", Vector2(-75, -80), true)
	ctx.match_state.resources[ctx.team][Enums.ResourceType.FOOD] = 200
	ctx.match_state.resources[ctx.team][Enums.ResourceType.GOLD] = 45
	capture()
	Production.new().tick(ctx, Build.new())
	check(ctx.pending_commands.any(func(c): return c.op == "train" and c.unit_def_id == "archer"), "a base raid releases siege savings for emergency soldiers")

	fixture(3)
	building("castle", Vector2(-40, 30))
	building("siege_workshop", Vector2(-60, 30))
	for index in 6:
		unit("militia", Vector2(-30 + index, 0))
	capture()
	Production.new().tick(ctx, Build.new())
	check(ctx.pending_commands.any(func(c): return c.op == "train" and c.unit_def_id == "trebuchet"), "Imperial army adds long-range trebuchets from an idle castle")
	execute()

	fixture()
	building("town_center", Vector2(-70, -70))
	building("blacksmith", Vector2(-100, -70))
	building("barracks", Vector2(-70, -100))
	for index in 8:
		unit("villager", Vector2(-60 + index, -70))
	for index in 3:
		unit("militia", Vector2(-80 + index, -60))
	ctx.phase = 1
	capture()
	Build.new().tick(ctx)
	check(ctx.pending_commands.any(func(c): return c.op == "place_building" and c.building_def_id == "siege_workshop"), "Castle-age army builds a workshop before optional extra producers")
	execute()

	fixture(1)
	building("town_center", Vector2(-70, -70))
	building("barracks", Vector2(-100, -100))
	for index in 8:
		unit("villager", Vector2(-60 + index, -70))
	for index in 3:
		unit("militia", Vector2(-80 + index, -60))
	capture()
	check(not ctx.blackboard.threat_near_base, "defense fixture has no current raid")
	Defense.new().tick(ctx)
	var rows := ctx.pending_commands.filter(func(c): return c.op == "place_wall")
	check(rows.size() == 1, "established AI proactively starts a legal base perimeter")
	execute()
	check(ctx.match_state.get_resource(ctx.team, Enums.ResourceType.FOOD) >= 100 and ctx.match_state.get_resource(ctx.team, Enums.ResourceType.WOOD) >= 150, "wall purchase preserves production reserves")
	var first_center := (Vector2(rows[0].start[0], rows[0].start[1]) + Vector2(rows[0].end[0], rows[0].end[1])) * 0.5
	for actor in world.get_children():
		if actor is BuildingAgent and not actor.is_complete:
			actor._complete_construction()
		elif actor is UnitAgent and actor.def.id == &"villager":
			actor.command_stop()
	capture()
	Defense.new().tick(ctx)
	rows = ctx.pending_commands.filter(func(c): return c.op == "place_wall")
	check(rows.size() == 1, "completed batch permits the next connected perimeter batch")
	if rows.size() == 1:
		var next_center := (Vector2(rows[0].start[0], rows[0].start[1]) + Vector2(rows[0].end[0], rows[0].end[1])) * 0.5
		check(first_center.distance_to(next_center) <= 16, "next batch extends the same perimeter rather than scattering short screens")
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 100
	capture()
	Defense.new().tick(ctx)
	check(ctx.pending_commands.is_empty(), "wall expansion yields to scarce production resources")
	_test_perimeter_progress()
	_test_abandoned_foundation()
	_test_perimeter_scout()
	_test_perimeter_scout_monitor()
	world.free()
	print("AI SIEGE STRATEGY: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _defense_fixture() -> void:
	fixture(1)
	building("town_center", Vector2(-40, -40))
	building("barracks", Vector2(-54, -54))
	for index in 8:
		unit("villager", Vector2(-38 + index, -40))
	for index in 3:
		unit("militia", Vector2(-42 + index, -35))
	for type in 4:
		ctx.match_state.resources[ctx.team][type] = 20000


func _complete_batch() -> void:
	for actor in world.get_children():
		if actor is BuildingAgent and not actor.is_complete:
			actor._complete_construction()
		elif actor is UnitAgent and actor.def.id == &"villager":
			actor.command_stop()


func _test_perimeter_progress() -> void:
	_defense_fixture()
	var defense := Defense.new()
	var batches := 0
	for index in 90:
		capture(240.0 + index * 11.0)
		defense.tick(ctx)
		var rows := ctx.pending_commands.filter(func(c): return c.op == "place_wall")
		if rows.is_empty(): break
		batches += 1
		execute()
		_complete_batch()
	var snapshot := preload("res://scripts/ai_gateway/observation_builder.gd").build_json_safe(ctx.match_state, world, ctx.team, ctx.enemy_team, 1300.0)
	var plan: Dictionary = snapshot.decision_context.get("defense_plan", {})
	check(batches > 5, "local AI continues construction after its former 30-piece wall limit")
	check(int(plan.get("complete_segments", 0)) > 30, "completed defense encloses a larger base instead of ending with a short screen")
	check(bool(plan.get("closed", false)) and int(plan.get("missing_segments", -1)) == 0, "repeated local AI ticks complete the entire planned perimeter")
	var gates := world.get_children().filter(func(node): return node is BuildingAgent and node.def.id == &"gate")
	check(not gates.is_empty() and gates.all(func(gate): return gate.is_complete and gate.gate_state == "auto"), "completed perimeter preserves access through automatic gates")
	var walls := world.get_children().filter(func(node): return node is BuildingAgent and Walls.is_wall(node.def.id))
	check(not walls.is_empty(), "perimeter contains actual wall pieces to exercise destruction and repair")
	if not walls.is_empty():
		walls[0].free()
		capture(1400.0)
		defense.tick(ctx)
		check(ctx.pending_commands.any(func(c): return c.op == "place_wall"), "destroyed wall reopens the same perimeter for local repair")
		execute()
		_complete_batch()
		snapshot = preload("res://scripts/ai_gateway/observation_builder.gd").build_json_safe(ctx.match_state, world, ctx.team, ctx.enemy_team, 1411.0)
		check(bool(snapshot.decision_context.defense_plan.closed), "repair closes the destroyed perimeter gap")


func _test_abandoned_foundation() -> void:
	_defense_fixture()
	var foundation := building("stone_wall", Vector2(-12, -40))
	foundation.start_construction()
	# No new wall budget remains, but paid foundations can still be completed.
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 0
	capture()
	Defense.new().tick(ctx)
	check(ctx.pending_commands.any(func(c): return c.op == "build" and int(c.building_id) == Registry.id_of(foundation)), "orphaned wall foundation receives a worker even without another purchase budget")
	execute()
	capture(251.0)
	Defense.new().tick(ctx)
	check(ctx.pending_commands.is_empty(), "active foundation builder is retained rather than repeatedly reassigned")
	for actor in ctx.blackboard.team_villagers:
		actor.command_stop()
		actor.set_meta("manual_control_until_sim_time", 1000.0)
	capture(262.0)
	Defense.new().tick(ctx)
	check(ctx.pending_commands.is_empty(), "wall recovery preserves human worker control leases")


func _test_perimeter_scout() -> void:
	_defense_fixture()
	capture()
	var first := ctx.blackboard.team_villagers[0]
	var second := ctx.blackboard.team_villagers[1]
	var first_id := Registry.id_of(first)
	var second_id := Registry.id_of(second)
	var observation := {"entities": [], "decision_context": {"defense_scout_options": [
		{"unit_id": first_id, "pos": [-10, -40]},
		{"unit_id": second_id, "pos": [-40, -10]},
	]}}
	var defense := Defense.new()
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.size() == 1 and int(ctx.pending_commands[0].unit_id) == first_id, "one empty-handed worker reveals the next perimeter construction area")
	execute()
	capture(251.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.is_empty(), "an active perimeter scout prevents sending a second worker")
	first.command_stop()
	first.carry_amount = 5.0
	capture(262.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.size() == 1 and int(ctx.pending_commands[0].unit_id) == second_id, "perimeter scouting preserves carried resource deliveries")
	first.carry_amount = 0.0
	for worker in [first, second]:
		worker.set_meta("manual_control_until_sim_time", 1000.0)
	capture(273.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.is_empty(), "perimeter scouting respects manual worker control leases")
	for worker in [first, second]:
		worker.remove_meta("manual_control_until_sim_time")
	var enemy := unit("militia", Vector2(-11, -40), true)
	observation.entities = [{"kind": "unit", "team": ctx.enemy_team, "def_id": "militia", "pos": [enemy.sim_pos.x, enemy.sim_pos.y]}]
	capture(284.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.size() == 1 and int(ctx.pending_commands[0].unit_id) == second_id, "perimeter scout avoids an observed enemy along its approach")


func _test_perimeter_scout_monitor() -> void:
	_defense_fixture()
	capture()
	var worker := ctx.blackboard.team_villagers[0]
	var worker_id := Registry.id_of(worker)
	var observation := {"entities": [], "decision_context": {"defense_scout_options": [
		{"unit_id": worker_id, "pos": [-10, -40]},
	]}}
	var defense := Defense.new()
	defense.next_check = 1000.0
	defense._scout_perimeter(ctx, observation)
	execute()
	capture(245.0)
	defense.tick(ctx)
	check(ctx.pending_commands.is_empty(), "progress monitor does not interrupt a new safe perimeter survey")
	capture(249.0)
	defense.tick(ctx)
	check(ctx.pending_commands.size() == 1 and ctx.pending_commands[0].op == "move" and Vector2(ctx.pending_commands[0].pos[0], ctx.pending_commands[0].pos[1]) == worker.sim_pos, "stalled perimeter survey is canceled between normal defense checks")
	execute()
	worker.command_stop()
	capture(250.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.is_empty(), "stalled survey cools down before borrowing another economy worker")
	capture(270.0)
	defense._scout_perimeter(ctx, observation)
	check(ctx.pending_commands.size() == 1, "bounded survey cooldown permits later exploration")
	execute()
	worker.sim_pos += Vector2.RIGHT
	capture(291.0)
	defense.tick(ctx)
	check(ctx.pending_commands.size() == 1 and Vector2(ctx.pending_commands[0].pos[0], ctx.pending_commands[0].pos[1]) == worker.sim_pos, "survey deadline releases even a slowly progressing worker after twenty seconds")
	execute()
	worker.command_stop()
	capture(312.0)
	defense._scout_perimeter(ctx, observation)
	execute()
	var enemy := unit("militia", Vector2(-11, -40), true)
	capture(313.0)
	defense.tick(ctx)
	check(ctx.pending_commands.size() == 1 and Vector2(ctx.pending_commands[0].pos[0], ctx.pending_commands[0].pos[1]) == ctx.blackboard.own_tc_pos, "newly visible enemies trigger immediate scout retreat to own TC")
	execute()
	worker.command_stop()
	enemy.free()
	capture(334.0)
	defense._scout_perimeter(ctx, observation)
	execute()
	unit("militia", Vector2(-11, -40), true)
	ctx.match_state.fog_enabled = true
	ctx.match_state.fog = null
	capture(335.0)
	defense.tick(ctx)
	check(ctx.pending_commands.is_empty(), "hidden enemies do not influence perimeter survey retreat")
	ctx.match_state.fog_enabled = false
	worker.set_meta("manual_control_until_sim_time", 1000.0)
	worker.command_move(Vector2(-40, -10))
	capture(336.0)
	defense.tick(ctx)
	check(ctx.pending_commands.is_empty() and defense.perimeter_scout_id == -1, "human takeover ends the survey lease without overriding the new move")
