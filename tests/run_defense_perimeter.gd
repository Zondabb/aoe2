extends SceneTree
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Decision := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Nav := preload("res://scripts/systems/nav_grid_service.gd")
const Generator := preload("res://scripts/world/default_map_generator.gd")
const MapCatalog := preload("res://scripts/world/map_catalog.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
var checks := 0
var failures := 0
var world: Node2D
var state: MatchState
var builder: UnitAgent
var tc: BuildingAgent
var ctx: CommandExecutionContext

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _building(id: StringName, point: Vector2, team := 0) -> BuildingAgent:
	var actor := BUILDING.instantiate() as BuildingAgent
	actor.def = Catalog.get_building(id)
	actor.team = team
	actor.sim_pos = point
	actor.match_state = state
	world.add_child(actor)
	actor.set_process(false)
	return actor

func _fixture() -> void:
	if is_instance_valid(world): world.free()
	Registry.clear()
	Collision.clear_map_bounds()
	world = Node2D.new()
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-80, -80, 160, 160)
	state.progression_enabled = true
	state.set_age(0, 2)
	for resource in 4: state.resources[0][resource] = 10000
	tc = _building(&"town_center", Vector2.ZERO)
	builder = UNIT.instantiate() as UnitAgent
	builder.def = Catalog.get_unit(&"villager")
	builder.match_state = state
	builder.sim_pos = Vector2(6, 0)
	world.add_child(builder)
	builder.set_physics_process(false)
	ctx = Context.new()
	ctx.match_state = state
	ctx.entities = world
	ctx.team = 0
	ctx.civ = load("res://data/civs/chinese.tres")

func _decision() -> Dictionary:
	return Observation.build_json_safe(state, world, 0, 1, 0).decision_context

func _run() -> void:
	_fixture()
	var boundary_preview := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	var blocked_edge: float = boundary_preview.rect.end.x
	var preview_obstacle := _building(&"house", Vector2(28, 12), 1)
	boundary_preview = Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(boundary_preview.rect.end.x != blocked_edge, "unpaid preview shifts a wall edge away from a visible obstacle")
	check(boundary_preview.rect.has_point(tc.sim_pos), "obstacle-aware preview continues enclosing the town center")
	for chunk: Dictionary in Perimeter.batches(boundary_preview):
		check(Walls.validate_plan(chunk.pieces, ctx).is_empty(), "visible obstacle detour yields legal connected batches")
	preview_obstacle.free()
	_fixture()
	var preview := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	var initial_bounds: Rect2 = preview.rect
	_building(&"barracks", Vector2(32, 0))
	preview = Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(preview.rect.end.x > initial_bounds.end.x, "unpaid preview expands to enclose the developed base")
	var first: Dictionary = Perimeter.batches(preview)[0]
	var paid := Walls.place_plan(first.pieces, ctx, builder)
	check(not paid.is_empty(), "first perimeter batch is a real paid construction purchase")
	var fixed_bounds: Rect2 = preview.rect
	_building(&"siege_workshop", Vector2(39, 0))
	preview = Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(preview.frozen and preview.rect == fixed_bounds, "first paid foundation freezes the perimeter before later building expansion")
	_fixture()
	var workshop := _building(&"siege_workshop", Vector2(32, 0))
	var plan := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(plan.rect.end.x >= workshop.sim_pos.x + workshop.def.footprint.x * 0.5 + 5, "initial perimeter encloses nearby production buildings and exits")
	var before: Rect2 = plan.rect
	_building(&"house", Vector2(50, 0))
	var again := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "stone_wall")
	check(again.rect == before and again.material == "palisade_wall", "new buildings and material preferences do not create parallel perimeter rings")
	check(not Perimeter.keeps_wall_strip_clear(plan, Vector2(before.end.x, 10), Vector2(3, 3)), "future buildings reserve the unbuilt perimeter strip")
	check(Perimeter.keeps_wall_strip_clear(plan, Vector2(10, 10), Vector2(3, 3)), "reserved perimeter still permits interior economy")
	var chunks := Perimeter.batches(plan)
	var gates := 0
	var placements := 0
	for chunk: Dictionary in chunks:
		check(chunk.pieces.size() <= 8 and not chunk.pieces.is_empty(), "perimeter batch fits a small affordable primitive command")
		check(Walls.validate_plan(chunk.pieces, ctx).is_empty(), "all connected wall batches and gate corners pass real placement")
		if chunk.include_gate: gates += 1
		var foundations := Walls.place_plan(chunk.pieces, ctx, builder)
		placements += foundations.size()
		for foundation in foundations: foundation.add_build_progress(foundation.def.build_time)
		builder.command_stop()
	check(gates == 4 and placements > 180, "four connected full sides contain four gates instead of three short screens")
	var decision := _decision()
	check(decision.defense_plan.closed and decision.defense_plan.complete_segments == placements, "progress reports closed only when every distinct perimeter piece is complete")
	check(decision.defense_options.is_empty(), "completed perimeter does not offer extra parallel walls")
	var resources: Dictionary = state.resources[0].duplicate()
	for chunk: Dictionary in chunks: check(Walls.place_plan(chunk.pieces, ctx, builder).is_empty(), "retrying a complete perimeter reuses its existing segments")
	check(state.resources[0] == resources, "retrying a closed perimeter charges no resources")
	builder.command_stop()
	builder.sim_pos = Vector2(6, 0)
	var solids := world.get_children().filter(func(node): return node is BuildingAgent)
	# Check swept movement at EVERY cell along each side, including gate seams
	# and shared corners. Auto doors have no allied trigger at the perimeter.
	for side: Dictionary in Perimeter.sides(plan.rect):
		var blocked := true
		var tangent: Vector2 = (side.end - side.start).normalized()
		for step in roundi(side.start.distance_to(side.end)) + 1:
			var point: Vector2 = side.start + tangent * step
			if Collision.static_step_safe(point + side.normal * 2, point - side.normal * 2, 0.35, solids): blocked = false
		check(blocked, "hostile infantry cannot physically enter across any point of the %s side" % side.side)
	var gate: BuildingAgent
	for node in solids:
		if node.def.id == &"gate":
			gate = node
			break
	var gate_normal := Vector2.UP if gate.wall_orientation == 0 else Vector2.RIGHT
	builder.sim_pos = gate.sim_pos - gate_normal * 3
	gate._update_gate()
	check(gate.gate_open, "friendly builder approaching its gate opens the physical door")
	check(Collision.static_step_safe(gate.sim_pos - gate_normal * 2, gate.sim_pos + gate_normal * 2, 0.35, solids), "friendly traffic can cross a completed perimeter gate")
	builder.sim_pos = Vector2(6, 0)
	gate._update_gate()
	var victim: BuildingAgent
	for node in solids:
		if node.def.id == &"palisade_wall" and node.sim_pos.distance_to(plan.rect.position) > 5:
			victim = node
			break
	var gap := victim.sim_pos
	victim.free()
	decision = _decision()
	check(not decision.defense_plan.closed and decision.defense_plan.missing_segments == 1, "destroyed wall immediately reopens the same perimeter plan")
	check(decision.defense_options.any(func(option): return option.repair and Geometry2D.get_closest_point_to_segment(gap, Vector2(option.start[0], option.start[1]), Vector2(option.end[0], option.end[1])).distance_to(gap) < 0.1), "destroyed segment produces a prioritized repair on the original wall line")
	_fixture()
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(state.map_bounds.position, state.map_bounds.end, 1)
	state.fog.rebuild(world.get_children())
	decision = _decision()
	check(decision.defense_plan.unseen_segments > 0 and not decision.defense_scout_options.is_empty(), "unseen perimeter produces bounded survey tasks instead of hidden placement hints")
	check(decision.defense_plan.unseen_segments <= decision.defense_plan.missing_segments, "shared unseen corner pieces count once across adjacent batches")
	for option: Dictionary in decision.defense_scout_options:
		check(Vector2(option.pos[0], option.pos[1]).distance_to(builder.sim_pos) <= 14.01, "survey step is close enough for the bounded builder lease")
	for option: Dictionary in decision.defense_options:
		for piece: Dictionary in Walls.plan(option.building_def_id, Vector2(option.start[0], option.start[1]), Vector2(option.end[0], option.end[1]), option.include_gate):
			check(state.fog.footprint_visible(0, piece.pos, Walls.footprint_for(Catalog.get_building(piece.building_def_id), piece.orientation), true), "all offered foundation footprints use current own sight")
	var known: Dictionary = decision.defense_plan.duplicate()
	var enemy := _building(&"house", Vector2(28, 28), 1)
	state.fog.rebuild(world.get_children())
	check(_decision().defense_plan == known, "hidden enemy building does not change perimeter progress or blocked-segment hints")
	enemy.free()
	_fixture()
	state.set_age(0, 0)
	decision = _decision()
	check(not decision.defense_options.is_empty() and decision.defense_options.all(func(option): return not option.include_gate), "before gates unlock the four entrances remain open instead of trapping the economy")
	state.set_age(0, 2)
	decision = _decision()
	check(decision.defense_options.filter(func(option): return option.include_gate).size() == 4, "gate unlock provides the exact four deferred entrance batches")
	var purchase: Dictionary = decision.defense_options[0]
	var purchased := Walls.place_plan(Walls.plan(purchase.building_def_id, Vector2(purchase.start[0], purchase.start[1]), Vector2(purchase.end[0], purchase.end[1]), purchase.include_gate), ctx, builder)
	for foundation in purchased: foundation.add_build_progress(foundation.def.build_time)
	builder.command_stop()
	var obstacle := _building(&"house", Vector2(28, 12), 1)
	decision = _decision()
	check(decision.defense_plan.blocked_segments > 0 and not decision.defense_plan.closed, "visible blocking geometry is reported as an unresolved opening")
	obstacle.free()
	check(_decision().defense_plan.blocked_segments == 0, "clearing a blocked segment resumes the same planned wall line")
	_fixture()
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(state.map_bounds.position, state.map_bounds.end, 1)
	var finished := false
	var surveys := 0
	for iteration in 160:
		state.fog.rebuild(world.get_children())
		decision = _decision()
		if decision.defense_plan.closed:
			finished = true
			break
		if not decision.defense_options.is_empty():
			var option: Dictionary = decision.defense_options[0]
			var row := Walls.plan(option.building_def_id, Vector2(option.start[0], option.start[1]), Vector2(option.end[0], option.end[1]), option.include_gate)
			var foundations := Walls.place_plan(row, ctx, builder)
			if foundations.is_empty(): break
			for foundation in foundations: foundation.add_build_progress(foundation.def.build_time)
			builder.command_stop()
		elif not decision.defense_scout_options.is_empty():
			var option: Dictionary = decision.defense_scout_options[0]
			builder.sim_pos = Vector2(option.pos[0], option.pos[1])
			surveys += 1
		else: break
	check(finished and surveys > 0, "bounded survey moves and visible primitive batches progressively close a real fog-of-war perimeter")
	_fixture()
	var food_plan := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	food_plan.frozen = true
	# A developed base can fill the inner mill sites while the wall band covers
	# both historical fallback rings. Food recovery still needs an outer plot.
	for point in [Vector2(22, 14), Vector2(14, 22), Vector2(-14, 22), Vector2(-22, 14), Vector2(-22, -14), Vector2(-14, -22), Vector2(14, -22), Vector2(22, -14)]:
		_building(&"house", point)
	var mill_options: Array = _decision().construction_options.filter(func(option): return option.building_def_id == "mill")
	check(not mill_options.is_empty(), "completed food sources do not leave a developed walled base without any legal mill site")
	check(mill_options.any(func(option): return Vector2(option.pos[0], option.pos[1]).distance_to(tc.sim_pos) > 40), "mill recovery can use visible plots beyond a crowded reserved wall band")
	for option: Dictionary in mill_options:
		check(Perimeter.keeps_wall_strip_clear(food_plan, Vector2(option.pos[0], option.pos[1]), Catalog.get_building(&"mill").footprint + Vector2.ONE * 4), "fallback food infrastructure preserves the paid wall footprint")
	_test_generated_map_boundaries()
	world.free()
	print("Defense perimeter: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _test_generated_map_boundaries() -> void:
	for seed_value in [Generator.DEFAULT_SEED, 1, 7654321]:
		_fixture()
		state.map_bounds = Rect2(-240, -240, 480, 480)
		tc.sim_pos = Generator.BASE_POSITION
		builder.sim_pos = tc.sim_pos + Vector2(6, 0)
		var map := Generator.generate(seed_value)
		for record: Dictionary in map.entities:
			if record.type != "resource": continue
			var point := Vector2(record.pos[0], record.pos[1])
			if point.distance_to(tc.sim_pos) > 100: continue
			var resource := ResourceNode.new()
			resource.sim_pos = point
			resource.resource_type = MapCatalog.RESOURCES[record.resource_type]
			resource.amount = record.amount
			if record.has("block_size"): resource.block_size_override = Vector2(record.block_size[0], record.block_size[1])
			world.add_child(resource)
		var barracks := _building(&"barracks", tc.sim_pos + Vector2(0, -36))
		var plan := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
		var rectangle: Rect2 = plan.rect
		check(rectangle.encloses(Rect2(barracks.sim_pos - barracks.def.footprint * 0.5, barracks.def.footprint).grow(2)), "generated-map perimeter retains developed core access for seed %d" % seed_value)
		var legal := true
		for chunk: Dictionary in Perimeter.batches(plan):
			if not Walls.validate_plan(chunk.pieces, ctx).is_empty(): legal = false
		check(legal, "generated forests and ore allow the complete planned perimeter for seed %d" % seed_value)
