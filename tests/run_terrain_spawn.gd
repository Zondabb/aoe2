extends SceneTree

const BUILDING := preload("res://scenes/entities/building_view.tscn")
const TC := preload("res://data/buildings/town_center.tres")
const VILLAGER := preload("res://data/units/villager.tres")
const BARRACKS := preload("res://data/buildings/barracks.tres")
const HOUSE := preload("res://data/buildings/house.tres")
const TERRAIN := preload("res://scripts/entities/path_blocker.gd")
const HOLDER := preload("res://scripts/systems/nav_service_holder.gd")
const COLLISION := preload("res://scripts/systems/collision_resolver.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture(with_nav := true, definition: BuildingDef = TC) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-30, -30, 60, 60)
	state.population_cap[0] = 100
	state.resources[0][0] = 10000
	var building := BUILDING.instantiate() as BuildingAgent
	building.def = definition
	building.match_state = state
	entities.add_child(building)
	building.set_physics_process(false)
	var holder: Node
	if with_nav:
		holder = HOLDER.new()
		holder.setup_rect(Vector2i(-30, -30), Vector2i(30, 30))
		world.add_child(holder)
		holder.set_process(false)
		holder.rebuild_from_scene()
	return {"world":world, "entities":entities, "state":state, "building":building, "holder":holder}

func _terrain(fixture: Dictionary, position: Vector2, size: Vector2, kind := &"water") -> PathBlocker:
	var region := TERRAIN.new() as PathBlocker
	region.kind = kind
	region.sim_pos = position
	region.block_size = size
	region.auto_block_size = false
	fixture.entities.add_child(region)
	if fixture.holder != null: fixture.holder.rebuild_from_scene()
	return region

func _trained(fixture: Dictionary) -> Array[Node2D]:
	var result: Array[Node2D] = []
	for node in fixture.entities.get_children():
		if node.get("def") is UnitDef:
			node.set_physics_process(false)
			result.append(node)
	return result

func _complete(fixture: Dictionary) -> void:
	check(fixture.building.enqueue_train(VILLAGER), "villager enters the production queue")
	fixture.building.set_physics_process(false)
	fixture.building._physics_process(VILLAGER.train_time)

func _run() -> void:
	var fixture := _fixture()
	_complete(fixture)
	var trained := _trained(fixture)
	check(trained.size() == 1, "ordinary open terrain produces one unit")
	if not trained.is_empty():
		check(trained[0].sim_pos.is_equal_approx(Vector2(2.8, 0)), "unobstructed town center keeps its original exit")
	check(fixture.state.population[0] == 1 and fixture.state.population_reserved[0] == 0, "successful spawn transfers the population reservation once")
	fixture.world.free()
	for with_nav in [true, false]:
		for kind in [&"water", &"cliff"]:
			fixture = _fixture(with_nav)
			var region := _terrain(fixture, Vector2(4.1, 0), Vector2(4, 20), kind)
			_complete(fixture)
			trained = _trained(fixture)
			check(trained.size() == 1, "%s shore still offers a land exit (nav=%s)" % [kind, with_nav])
			if not trained.is_empty():
				var worker := trained[0]
				var radius := COLLISION.unit_radius(worker)
				check(not COLLISION._hits_building(worker.sim_pos, radius, region), "trained land unit never starts inside %s" % kind)
				check(COLLISION.static_step_safe(fixture.building.sim_pos, worker.sim_pos, radius, [region]), "shore exit stays connected to the producing building")
				if with_nav: check(fixture.holder.nav.is_world_walkable_with_radius(worker.sim_pos, radius), "shore exit is walkable on the actual clearance grid")
			fixture.world.free()
	fixture = _fixture()
	var strips: Array[Node2D] = []
	strips.append(_terrain(fixture, Vector2(3, 0), Vector2(0.2, 12)))
	strips.append(_terrain(fixture, Vector2(-3, 0), Vector2(0.2, 12)))
	strips.append(_terrain(fixture, Vector2(0, 3), Vector2(12, 0.2), &"cliff"))
	strips.append(_terrain(fixture, Vector2(0, -3), Vector2(12, 0.2), &"cliff"))
	check(fixture.holder.nav.is_world_walkable_with_radius(Vector2(5.5, 0), VILLAGER.resolved_footprint_radius()), "disconnected land exists just beyond the water strip")
	var starting_food: int = fixture.state.resources[0][0]
	_complete(fixture)
	check(_trained(fixture).is_empty(), "training cannot jump surrounding terrain into a disconnected land pocket")
	check(fixture.building.train_queue.size() == 1 and fixture.building.training_progress_ratio() == 1.0, "no land exit retains the completed queue item")
	check(fixture.state.population[0] == 0 and fixture.state.population_reserved[0] == 1, "waiting spawn retains its paid population reservation")
	var retry_value: float = fixture.building._spawn_retry_remaining
	fixture.building._physics_process(0.01)
	check(fixture.building._spawn_retry_remaining < retry_value and fixture.building._spawn_retry_remaining > 0.0, "blocked production waits between bounded local exit searches")
	check(fixture.state.resources[0][0] == starting_food - VILLAGER.cost_food, "waiting does not charge a completed unit again")
	strips[0].free()
	fixture.holder.rebuild_from_scene()
	fixture.building._physics_process(0.25)
	trained = _trained(fixture)
	check(trained.size() == 1 and fixture.building.train_queue.is_empty(), "opening one shore exit resumes the completed production item")
	check(fixture.state.population[0] == 1 and fixture.state.population_reserved[0] == 0, "resumed spawn transfers its reservation exactly once")
	if not trained.is_empty():
		check(trained[0].sim_pos.x > 0 and trained[0].sim_pos.y == 0, "resumed unit uses the connected opening")
	fixture.world.free()
	fixture = _fixture()
	for position in [Vector2(3, 0), Vector2(-3, 0)]: _terrain(fixture, position, Vector2(0.2, 12))
	for position in [Vector2(0, 3), Vector2(0, -3)]: _terrain(fixture, position, Vector2(12, 0.2))
	_complete(fixture)
	var queued_id: int = fixture.building.train_queue_ids[0]
	check(fixture.building.cancel_train(queued_id), "a completed unit waiting for land can be cancelled")
	check(fixture.state.population_reserved[0] == 0 and fixture.building.train_queue.is_empty(), "cancelling a blocked exit releases only its reservation")
	fixture.world.free()
	fixture = _fixture()
	_complete(fixture)
	_complete(fixture)
	trained = _trained(fixture)
	check(trained.size() == 2, "sequential completed units both spawn")
	if trained.size() == 2:
		var minimum := COLLISION.unit_radius(trained[0]) + COLLISION.unit_radius(trained[1])
		check(trained[0].sim_pos.distance_to(trained[1].sim_pos) >= minimum, "consecutive units use distinct unoccupied exits")
	fixture.world.free()
	fixture = _fixture()
	var ore := ResourceNode.new()
	ore.resource_type = Enums.ResourceType.GOLD
	ore.sim_pos = Vector2(4.5, 0)
	ore.block_size_override = Vector2(4, 4)
	fixture.entities.add_child(ore)
	fixture.holder.rebuild_from_scene()
	_complete(fixture)
	trained = _trained(fixture)
	check(trained.size() == 1, "a nearby resource leaves alternate production exits")
	if not trained.is_empty():
		check(not COLLISION._hits_building(trained[0].sim_pos, COLLISION.unit_radius(trained[0]), ore), "training never places a unit in a resource body")
	fixture.world.free()
	fixture = _fixture()
	var neighbor := BUILDING.instantiate() as BuildingAgent
	neighbor.def = HOUSE
	neighbor.match_state = fixture.state
	neighbor.sim_pos = Vector2(4.5, 0)
	fixture.entities.add_child(neighbor)
	fixture.holder.rebuild_from_scene()
	_complete(fixture)
	trained = _trained(fixture)
	check(trained.size() == 1, "a nearby building leaves alternate production exits")
	if not trained.is_empty():
		check(not COLLISION._hits_building(trained[0].sim_pos, COLLISION.unit_radius(trained[0]), neighbor), "training never places a unit in another building")
	fixture.world.free()
	fixture = _fixture(true, BARRACKS)
	var soldier: UnitDef = fixture.building.get_trainable_units()[0]
	check(fixture.building.enqueue_train(soldier), "a movement-blocking military building can train")
	fixture.building.set_physics_process(false)
	fixture.building._physics_process(soldier.train_time)
	trained = _trained(fixture)
	check(trained.size() == 1, "a blocking producer has a nearby legal exit")
	if not trained.is_empty():
		check(not COLLISION._hits_building(trained[0].sim_pos, COLLISION.unit_radius(trained[0]), fixture.building), "a trained body's full radius clears its own producer")
	fixture.world.free()
	fixture = _fixture()
	fixture.building.sim_pos = Vector2(27.9, 0)
	_complete(fixture)
	trained = _trained(fixture)
	check(trained.size() == 1, "a town center near the map boundary uses an inward exit")
	if not trained.is_empty():
		var radius := COLLISION.unit_radius(trained[0])
		check(fixture.state.map_bounds.encloses(Rect2(trained[0].sim_pos - Vector2.ONE * radius, Vector2.ONE * radius * 2)), "the full trained unit remains inside map bounds")
	fixture.world.free()
	COLLISION.clear_map_bounds()
	print("Terrain training spawn: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
