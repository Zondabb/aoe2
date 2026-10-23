extends SceneTree

const Walls := preload("res://scripts/systems/wall_system.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Network := preload("res://scripts/network/network_match.gd")
const Building := preload("res://scenes/entities/building_view.tscn")
const Unit := preload("res://scenes/entities/unit_view.tscn")
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState
var builder: UnitAgent
var ctx: CommandExecutionContext

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func clear() -> void:
	if is_instance_valid(entities): entities.free()
	entities = Node2D.new()
	root.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.set_age(0, 2)
	state.set_age(1, 2)
	state.map_bounds = Rect2(-80, -80, 160, 160)
	for team in 2:
		for type in 4: state.resources[team][type] = 2000
	builder = Unit.instantiate() as UnitAgent
	builder.def = Catalog.get_unit(&"villager")
	builder.match_state = state
	builder.sim_pos = Vector2(-8, -2)
	entities.add_child(builder)
	builder.set_physics_process(false)
	ctx = Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = Enums.Team.PLAYER
	ctx.civ = load("res://data/civs/chinese.tres")

func building(id: String, pos: Vector2, orientation := 0) -> BuildingAgent:
	var result := Building.instantiate() as BuildingAgent
	result.def = Catalog.get_building(StringName(id))
	result.sim_pos = pos
	result.match_state = state
	result.wall_orientation = orientation
	entities.add_child(result)
	return result

func _run() -> void:
	clear()
	for axis in 8:
		var step := Vector2(roundf(cos(axis * PI / 4)), roundf(sin(axis * PI / 4)))
		var row := Walls.plan("stone_wall", Vector2.ZERO, step * 10, true)
		check(row.size() == 8 and row[0].orientation == axis % 4, "eight directions include one aligned gate")
		check(Walls.validate_plan(row, ctx).is_empty(), "diagonal and axial gated rows do not overlap: %d" % axis)
	check(Walls.plan("stone_wall", Vector2.ZERO, Vector2(64, 0)).is_empty(), "bound command length")
	check(Walls.plan("stone_wall", Vector2(NAN, 0), Vector2.ZERO).is_empty(), "reject nonfinite endpoints")
	var cmd := {"op": "place_wall", "builder_id": Registry.id_of(builder), "building_def_id": "palisade_wall", "start": [-4, 0], "end": [4, 0], "include_gate": false}
	var before := state.get_resource(0, Enums.ResourceType.WOOD)
	var receipt := Executor.execute(cmd, ctx)
	check(receipt.ok and receipt.get("created_entity_ids", []).size() == 9, "atomic command reports every foundation")
	check(state.get_resource(0, Enums.ResourceType.WOOD) == before - 18, "aggregate cost charged once")
	check(builder.get_build_queue_ids().size() == 8, "one builder owns remaining row")
	var observed := Observation.build_json_safe(state, entities, Enums.Team.PLAYER, Enums.Team.AI, 0)
	check(observed.entities.filter(func(e): return e.id == Registry.id_of(builder))[0].build_queue_ids.size() == 8, "queue ownership reaches Python observation")
	for i in 9:
		var target: BuildingAgent = builder._build_target
		check(target != null, "queue advances to next section")
		if target != null:
			builder.sim_pos = target.sim_pos + Vector2(0, -1.5)
			builder._process_build(10)
	check(builder.order == Enums.OrderType.NONE and builder.get_build_queue_ids().is_empty(), "all sections finish without reissuing commands")
	check(entities.get_children().filter(func(n): return n is BuildingAgent and n.is_complete).size() == 9, "all nine wall segments completed")
	var duplicate := Executor.execute(cmd, ctx)
	check(duplicate.ok and duplicate.created_entity_ids.is_empty() and state.get_resource(0, Enums.ResourceType.WOOD) == before - 18, "reusing a row does not double charge")
	cmd.start = [4, 0]
	cmd.end = [4, 4]
	check(Executor.execute(cmd, ctx).created_entity_ids.size() == 4, "turning row reuses corner")
	builder.command_move(Vector2(-10, -10))
	check(builder.get_build_queue_ids().is_empty(), "manual move cancels future construction")
	clear()
	var older_wall := building("stone_wall", Vector2.ZERO)
	var connected_row := Walls.plan("palisade_wall", Vector2.ZERO, Vector2(2, 0))
	check(Walls.cost(connected_row, ctx).wood == 4 and Walls.cost(connected_row, ctx).stone == 0, "connecting materials charges only missing wall pieces")
	var joined := Walls.place_plan(connected_row, ctx, builder)
	check(joined.size() == 2 and older_wall.def.id == &"stone_wall", "perimeter connects to an existing other-material wall without replacing it")
	var after_join: Dictionary = state.resources[0].duplicate()
	check(Walls.place_plan(connected_row, ctx, builder).is_empty() and state.resources[0] == after_join, "mixed-material perimeter retries do not charge twice")
	clear()
	cmd.builder_id = Registry.id_of(builder)
	cmd.start = [-4, 0]
	cmd.end = [4, 0]
	state.resources[0][Enums.ResourceType.WOOD] = 2
	check(not Executor.execute(cmd, ctx).ok and entities.get_child_count() == 1 and state.resources[0][Enums.ResourceType.WOOD] == 2, "unaffordable row is atomic")
	state.resources[0][Enums.ResourceType.WOOD] = 100
	building("house", Vector2(2, 0))
	check(not Executor.execute(cmd, ctx).ok and state.resources[0][Enums.ResourceType.WOOD] == 100, "obstruction rejects entire row")
	clear()
	var gate := building("gate", Vector2.ZERO, 2)
	check(gate.get_placement_footprint() == Vector2(1, 4), "vertical gate footprint")
	builder.sim_pos = Vector2(20, 20)
	gate._update_gate()
	check(not gate.gate_open and Collision._hits_building(Vector2.ZERO, 0.3, gate), "closed gate is physically solid")
	check(preload("res://scripts/systems/nav_grid_service.gd").collect_blockers_from_tree(self).has(gate), "closed gate enters real scene collision index")
	var memory: Array = preload("res://scripts/presentation/fog_memory.gd").capture(gate)
	check(memory.any(func(part): return part.get("texture") is AtlasTexture), "original gate frame preserved in fog memory")
	check(gate.get_navigation_half() == Vector2.ZERO, "auto gate remains a possible approach route")
	var enemy := Unit.instantiate() as UnitAgent
	enemy.def = Catalog.get_unit(&"militia")
	enemy.team = Enums.Team.AI
	enemy.sim_pos = Vector2(2, 0)
	enemy.match_state = state
	entities.add_child(enemy)
	enemy.set_physics_process(false)
	gate._update_gate()
	check(not gate.gate_open, "enemy proximity cannot open auto gate")
	builder.sim_pos = Vector2(-3, 0)
	gate._update_gate()
	check(gate.gate_open and not Collision._hits_building(Vector2.ZERO, 0.3, gate), "friendly approach opens actual passage")
	builder.sim_pos = Vector2.ZERO
	gate.set_gate_state("locked")
	check(gate.gate_open, "locking waits for an occupied doorway to clear")
	builder.sim_pos = Vector2(-3, 0)
	gate._update_gate()
	check(not gate.gate_open and gate.get_navigation_half() != Vector2.ZERO, "locked gate closes and removes navigation route")
	check(not Executor.execute({"op":"set_gate_state", "building_id":Registry.id_of(gate), "gate_state":"bogus"}, ctx).ok, "invalid gate state rejected")
	ctx.team = Enums.Team.AI
	check(not Executor.execute({"op":"set_gate_state", "building_id":Registry.id_of(gate), "gate_state":"open"}, ctx).ok, "foreign gate control rejected")
	ctx.team = Enums.Team.PLAYER
	check(Executor.execute({"op":"set_gate_state", "building_id":Registry.id_of(gate), "gate_state":"open"}, ctx).ok and gate.gate_open, "owned gate mode command applied")
	clear()
	building("town_center", Vector2(-30, -30))
	builder.sim_pos = Vector2(-22, -30)
	observed = Observation.build_json_safe(state, entities, Enums.Team.PLAYER, Enums.Team.AI, 0)
	var options: Array = observed.decision_context.defense_options
	check(not options.is_empty(), "game exports executable defensive screens")
	for option: Dictionary in options:
		var row := Walls.plan(option.building_def_id, Vector2(option.start[0], option.start[1]), Vector2(option.end[0], option.end[1]), option.include_gate)
		check(option.preserves_access and option.cost == Walls.cost(row, ctx) and Walls.validate_plan(row, ctx).is_empty(), "defense hints match authoritative geometry and cost")
	var export_file := FileAccess.open("res://.godot/wall-observation.json", FileAccess.WRITE)
	export_file.store_string(JSON.stringify(observed))
	export_file.close()
	# Network authority validates sender ownership and carries rotation/state.
	var net := Network.new()
	root.add_child(net)
	net.entities = entities
	net.match_state = state
	net.map_bounds = state.map_bounds
	net.is_host = true
	net._playing = true
	net._civs = {0:ctx.civ, 1:ctx.civ}
	net._index_host_entities()
	cmd.builder_id = net.entity_id(builder)
	cmd.start = [0, 0]
	cmd.end = [10, 0]
	cmd.include_gate = true
	check(not net.execute_team_command(cmd, 1), "network peer cannot use opponent builder")
	check(net.execute_team_command(cmd, 0), "network accepts atomic wall command")
	var snapshot := net.capture_snapshot()
	var gates: Array = snapshot.entities.filter(func(e): return e.get("def") == "gate")
	check(gates.size() == 1 and gates[0].wall_orientation == 0 and gates[0].gate_state == "auto", "gate orientation/state in network snapshot")
	if not gates.is_empty():
		var replica := net._spawn_replica(gates[0]) as BuildingAgent
		check(replica.wall_orientation == 0 and not replica.is_complete, "replica preserves gated foundation")
		replica.free()
	net.free()
	clear()
	var holder := preload("res://scripts/systems/nav_service_holder.gd").new()
	root.add_child(holder)
	holder.setup(-80, 80)
	builder.sim_pos = Vector2(-10, -4)
	var live_row := Walls.place_plan(Walls.plan("palisade_wall", Vector2(-4, 0), Vector2(5, 0)), ctx, builder)
	holder.rebuild_from_scene()
	for step in 1500:
		holder._process(0.1)
		builder._physics_process(0.1)
		if builder.order == Enums.OrderType.NONE: break
		if step % 25 == 0: await process_frame
	check(live_row.size() == 10 and live_row.all(func(b): return b.is_complete), "builder walks and completes ten-wall row using real navigation and collision")
	holder.free()
	clear()
	building("town_center", Vector2(-30, -30))
	building("barracks", Vector2(-42, -42))
	builder.sim_pos = Vector2(-20, -30)
	for index in 7:
		var worker := Unit.instantiate() as UnitAgent
		worker.def = builder.def
		worker.match_state = state
		worker.sim_pos = Vector2(-20, -32 - index)
		entities.add_child(worker)
		worker.set_physics_process(false)
	var threat := Unit.instantiate() as UnitAgent
	threat.def = Catalog.get_unit(&"militia")
	threat.team = Enums.Team.AI
	threat.match_state = state
	threat.sim_pos = Vector2(-25, -5)
	entities.add_child(threat)
	threat.set_physics_process(false)
	var local_context := preload("res://scripts/systems/ai/ai_run_context.gd").new()
	local_context.match_state = state
	local_context.entities = entities
	local_context.civ = ctx.civ
	local_context.team = Enums.Team.PLAYER
	local_context.enemy_team = Enums.Team.AI
	local_context.blackboard = preload("res://scripts/systems/ai/ai_blackboard.gd").new()
	local_context.blackboard.refresh(state, entities, Enums.Team.PLAYER, Enums.Team.AI, 100, 40)
	local_context.begin_capture(1)
	preload("res://scripts/systems/ai/ai_defense_manager.gd").new().tick(local_context)
	var captured := local_context.end_capture()
	check(captured.commands.any(func(c): return c.op == "place_wall"), "local fallback defense emits the shared wall primitive after observing threat")
	if not captured.commands.is_empty(): check(Executor.execute(captured.commands[0], ctx).ok, "local fallback wall passes the same game validator")
	entities.free()
	print("WALL SYSTEM: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
