extends SceneTree
## Exercise actual local/captured AI orders, including production and wall legality.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Combat := preload("res://scripts/systems/ai/ai_combat_manager.gd")
const Army := preload("res://scripts/systems/ai/ai_army_manager.gd")
const Production := preload("res://scripts/systems/ai/ai_production_manager.gd")
const Build := preload("res://scripts/systems/ai/ai_build_manager.gd")
const Defense := preload("res://scripts/systems/ai/ai_defense_manager.gd")
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

func capture() -> void:
	ctx.blackboard.refresh(ctx.match_state, world, ctx.team, ctx.enemy_team, 240.0, ctx.profile.defend_radius)
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
	check(rows.size() == 1 and bool(rows[0].include_gate), "established AI proactively protects TC with a legal gated wall screen")
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
	check(rows.size() == 1, "completed first wall permits another defensive side")
	if rows.size() == 1:
		var next_center := (Vector2(rows[0].start[0], rows[0].start[1]) + Vector2(rows[0].end[0], rows[0].end[1])) * 0.5
		check(first_center.distance_to(next_center) > 16, "second screen covers an unprotected flank rather than duplicating the front")
	ctx.match_state.resources[ctx.team][Enums.ResourceType.WOOD] = 100
	capture()
	Defense.new().tick(ctx)
	check(ctx.pending_commands.is_empty(), "wall expansion yields to scarce production resources")
	world.free()
	print("AI SIEGE STRATEGY: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
