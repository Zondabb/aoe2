extends "res://tests/run_defense_perimeter.gd"
## Use the production generator and real loader, including its full forests,
## mines, water contours and symmetric starting bases.
const Generator := preload("res://scripts/world/default_map_generator.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
const MapData := preload("res://scripts/world/map_data.gd")
const ResourceActor := preload("res://scripts/entities/resource_node.gd")
const TerrainActor := preload("res://scripts/entities/path_blocker.gd")

func _all_batches_legal(plan: Dictionary) -> bool:
	for batch: Dictionary in Perimeter.batches(plan):
		if not Walls.validate_plan(batch.pieces, ctx, false).is_empty(): return false
	return true

func _run() -> void:
	for seed_value in [Generator.DEFAULT_SEED, 1001, 8912]:
		_fixture()
		for node in world.get_children(): node.free()
		var data := Generator.generate(seed_value)
		state.map_bounds = MapData.bounds(data)
		Loader.spawn_entities(data, world, state)
		for team in 2:
			ctx.team = team
			state.set_age(team, 2)
			tc = world.get_children().filter(func(node): return node is BuildingAgent and node.team == team and node.def.id == &"town_center")[0]
			var direction := 1.0 if team == 0 else -1.0
			var producer := _building(&"barracks", tc.sim_pos + Vector2(32, -8) * direction, team)
			var plan := Perimeter.get_plan(state, world, team, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
			check(plan.rect.has_point(tc.sim_pos) and plan.rect.has_point(producer.sim_pos), "generated seed %d team %d perimeter includes its real established core" % [seed_value, team])
			check(_all_batches_legal(plan), "generated seed %d team %d complete perimeter avoids actual forests, mines and terrain" % [seed_value, team])
	_fixture()
	var tree := ResourceActor.new()
	tree.resource_type = Enums.ResourceType.WOOD
	tree.sim_pos = Vector2(28, 12)
	tree.block_size_override = Vector2(4, 4)
	world.add_child(tree)
	var plan := Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(plan.rect.end.x != 28 and _all_batches_legal(plan), "unpaid preview selects a nearby clear line around visible forest resources")
	_fixture()
	var mine := ResourceActor.new()
	mine.resource_type = Enums.ResourceType.GOLD
	mine.sim_pos = Vector2(-28, 10)
	world.add_child(mine)
	plan = Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(plan.rect.position.x != -28 and _all_batches_legal(plan), "unpaid preview avoids a visible mineral footprint without moving the core outside")
	_fixture()
	var water := TerrainActor.new()
	water.kind = &"water"
	water.auto_block_size = false
	water.block_size = Vector2(8, 12)
	water.sim_pos = Vector2(28, 10)
	world.add_child(water)
	plan = Perimeter.get_plan(state, world, 0, tc.sim_pos, Registry.id_of(tc), state.map_bounds, "palisade_wall")
	check(plan.rect.end.x != 28 and _all_batches_legal(plan), "unpaid preview checks real shore contours and chooses a dry wall line")
	world.free()
	print("Generated-map defense perimeter: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
