extends SceneTree
## Trained units leave from the drawn building and attackers stand along its
## drawn edge, as in the original game. Footprints stay in original tiles for
## placement and pathing; BuildingAgent.get_interaction_half() is the drawn size.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const CIV := preload("res://data/civs/chinese.tres")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture() -> void:
	if is_instance_valid(world): world.free()
	Registry.clear()
	Events.clear()
	Collision.clear_map_bounds()
	world = Node2D.new()
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-80, -80, 160, 160)
	for team in 2:
		state.population_cap[team] = 100
		for resource in 4: state.resources[team][resource] = 10000

func _building(id: StringName, at: Vector2, team := 0) -> BuildingAgent:
	var entity := BUILDING.instantiate() as BuildingAgent
	entity.def = Catalog.get_building(id)
	entity.team = team
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	world.add_child(entity)
	entity.set_physics_process(false)
	return entity

func _unit(id: StringName, at: Vector2, team := 0) -> UnitAgent:
	var entity := UNIT.instantiate() as UnitAgent
	entity.def = Catalog.get_unit(id)
	entity.team = team
	entity.civ = CIV
	entity.match_state = state
	entity.sim_pos = at
	world.add_child(entity)
	entity.set_physics_process(false)
	return entity

## How far a point lies outside an axis-aligned half extent (negative inside).
func _outside(point: Vector2, center: Vector2, half: Vector2) -> float:
	var delta := point - center
	return maxf(absf(delta.x) - half.x, absf(delta.y) - half.y)

func _test_drawn_size() -> void:
	_fixture()
	var tc := _building(&"town_center", Vector2.ZERO)
	var tile := BuildingAgent.art_tile_world()
	check(tile > 2.5 and tile < 2.7, "one original tile is drawn about 2.6 world units wide (got %.3f)" % tile)
	check(tc.get_interaction_half().is_equal_approx(tc.get_placement_footprint() * 0.5 * tile), "a town center is drawn at its footprint times the art tile size")
	var gate := _building(&"gate", Vector2(30, 30))
	check(gate.get_interaction_half() == gate.get_placement_footprint() * 0.5, "gates keep their logical footprint")
	var wall := _building(&"stone_wall", Vector2(-30, 30))
	check(wall.get_interaction_half() == wall.get_placement_footprint() * 0.5, "walls keep their logical footprint")

func _train(producer: BuildingAgent, unit_id: StringName) -> UnitAgent:
	var unit_def := Catalog.get_unit(unit_id)
	producer.def = producer.def.duplicate()
	producer.def.trainable.assign([unit_def])
	check(producer.enqueue_train(unit_def), "%s admits a %s" % [producer.def.id, unit_id])
	for step in 3:
		producer._physics_process(100)
	for entity in world.get_children():
		if entity is UnitAgent and entity.def == unit_def: return entity
	return null

func _test_trained_units_leave_the_drawn_building() -> void:
	for id in [&"town_center", &"barracks"]:
		_fixture()
		var producer := _building(id, Vector2(5, -7))
		var born := _train(producer, &"villager" if id == &"town_center" else &"militia")
		check(born != null, "%s spawned its unit" % id)
		if born == null: continue
		var gap := _outside(born.sim_pos, producer.sim_pos, producer.get_interaction_half())
		check(gap >= 0.0, "%s spawns outside the drawn building, not inside its art (gap %.2f)" % [id, gap])
		check(gap <= 2.0, "%s spawns right beside the drawn building (gap %.2f)" % [id, gap])

func _attacker(at: Vector2, target: BuildingAgent) -> UnitAgent:
	var soldier := _unit(&"militia", at)
	soldier._attack_target = target
	return soldier

func _test_melee_attackers_stand_on_the_drawn_edge() -> void:
	_fixture()
	var barracks := _building(&"barracks", Vector2.ZERO, 1)
	var half := barracks.get_interaction_half()
	var near_side := barracks._attack_spot_counts().y
	check(near_side >= 6, "a barracks side holds about one attacker per unit width (%d)" % near_side)
	var spots := {}
	var on_near_side := 0
	var crowd: Array[UnitAgent] = []
	for i in near_side + 3:
		var member := _attacker(Vector2(half.x + 20.0, 0.1 * float(i)), barracks)
		crowd.append(member)
		var point := member._attack_approach_point(barracks)
		var gap := _outside(point, barracks.sim_pos, half)
		check(gap >= 0.0 and gap <= 1.5, "attacker %d heads for the drawn edge (gap %.2f)" % [i, gap])
		check(point.x > half.x - 0.01, "attacker %d never walks across the building" % i)
		if barracks.attack_spot(member._attack_spot)[1] == Vector2i(Fixed.SCALE, 0): on_near_side += 1
		spots[member._attack_spot] = true
	check(spots.size() == crowd.size() and not spots.has(-1), "each attacker gets its own spot instead of queueing behind another")
	check(on_near_side == near_side, "the near side fills first, then the crowd wraps around (%d)" % on_near_side)
	var first := crowd[0]
	var held := first._attack_spot
	first.sim_pos = Vector2(half.x + 5.0, -6.0)
	first._attack_approach_point(barracks)
	check(first._attack_spot == held, "an attacker keeps its spot while it walks there")
	first._attack_target = null
	var late := _attacker(Vector2(half.x + 20.0, 0.0), barracks)
	late._attack_approach_point(barracks)
	check(late._attack_spot == held, "a spot frees when its attacker turns elsewhere")
	var lost := crowd[1]._attack_spot
	crowd[1].hp = 0.0
	var replacement := _attacker(Vector2(half.x + 20.0, 0.1), barracks)
	replacement._attack_approach_point(barracks)
	check(replacement._attack_spot == lost, "a spot frees when its attacker dies")

	# From behind, walk round the drawn corners to a spot on the far side.
	var walker := _unit(&"militia", Vector2(-half.x - 5.0, 1.0))
	walker._attack_spot = late._attack_spot
	var far_spot: Array = barracks.attack_spot(walker._attack_spot)
	var spot_point := Fixed.to_vector(far_spot[0] + UnitAgent._direction_q(far_spot[1], walker._attack_spot_standoff_q(barracks)))
	var corner := Fixed.to_vector(walker._attack_spot_waypoint_q(barracks))
	check(corner.x < -half.x and corner.y > half.y, "a walker behind the building first heads for its own near corner (%s)" % corner)
	walker.sim_pos = corner
	var next_corner := Fixed.to_vector(walker._attack_spot_waypoint_q(barracks))
	check(next_corner.x > half.x and next_corner.y > half.y, "then along the side to the corner by its spot (%s)" % next_corner)
	walker.sim_pos = next_corner
	check(Fixed.to_vector(walker._attack_spot_waypoint_q(barracks)) == spot_point, "then straight to its spot")
	walker.sim_pos = Vector2(half.x + 0.6, -half.y + 0.5)
	walker._attack_target = barracks
	walker._attack_spot_patience_units = Fixed.time_from_seconds(UnitAgent.ATTACK_SPOT_PATIENCE)
	check(not walker._needs_attack_chase(barracks), "the walker is already within reach of the building")
	check(walker._seeks_attack_spot(barracks, 1.0), "but keeps walking to its own spot instead of blocking another")
	for second in 5: walker._seeks_attack_spot(barracks, 1.0)
	check(not walker._seeks_attack_spot(barracks, 1.0), "and strikes from where it stands once its patience runs out")
	walker._attack_spot_patience_units = Fixed.time_from_seconds(UnitAgent.ATTACK_SPOT_PATIENCE)
	walker.sim_pos = spot_point
	check(not walker._seeks_attack_spot(barracks, 1.0), "an attacker at its spot strikes at once")

	# Units standing on a spot: give it up for another, or strike if in reach.
	var blocked := _attacker(Vector2(half.x + 2.0, 0.0), barracks)
	blocked._attack_approach_point(barracks)
	var first_try := blocked._attack_spot
	blocked._check_attack_spot_progress(barracks, 1.0)
	check(blocked._attack_spot == first_try, "an attacker is not judged stuck at once")
	blocked._check_attack_spot_progress(barracks, 1.0)
	check(blocked._attack_spot == -1 and blocked._attack_spot_skipped.has(first_try), "an attacker that cannot reach its spot gives it up")
	blocked._attack_approach_point(barracks)
	check(blocked._attack_spot >= 0 and blocked._attack_spot != first_try, "and heads for another spot")
	var reaching := _attacker(Vector2(half.x + 0.5, -half.y + 0.3), barracks)
	reaching._attack_approach_point(barracks)
	var reaching_spot := reaching._attack_spot
	reaching._attack_spot_patience_units = Fixed.time_from_seconds(UnitAgent.ATTACK_SPOT_PATIENCE)
	for second in 2: reaching._check_attack_spot_progress(barracks, 1.0)
	check(reaching._attack_spot == reaching_spot and not reaching._seeks_attack_spot(barracks, 1.0), "a blocked attacker within reach strikes from where it stands")
	var queued_far := _attacker(Vector2(half.x + 10.0, 5.0), barracks)
	queued_far._attack_approach_point(barracks)
	var far_try := queued_far._attack_spot
	for second in 4: queued_far._check_attack_spot_progress(barracks, 1.0)
	check(queued_far._attack_spot == far_try, "a crowd on the way is not taken for a blocked spot")

	var house := _building(&"house", Vector2(40, 0), 1)
	var house_half := house.get_interaction_half()
	var counts := house._attack_spot_counts()
	var total := 2 * (counts.x + counts.y)
	var last_point := Vector2.ZERO
	for i in total + 2:
		var queued := _attacker(house.sim_pos + Vector2(house_half.x + 6.0, 0.1 * float(i)), house)
		last_point = queued._attack_approach_point(house)
		if i >= total: check(queued._attack_spot == -1, "attackers beyond a full ring queue at the edge")
	check(_outside(last_point, house.sim_pos, house_half) <= 1.5, "a queued attacker still heads for the drawn edge")
	var soldier := _unit(&"militia", Vector2(half.x + 3.0, 0.0))
	check(not soldier._in_attack_range(barracks), "a melee unit away from the drawn edge must still close in")
	soldier.sim_pos = Vector2(half.x + 0.2, 0.0)
	check(soldier._in_attack_range(barracks), "a melee unit at the drawn edge can strike")
	var gate := _building(&"gate", Vector2(-40, 0), 1)
	var gate_half := gate.get_placement_footprint() * 0.5
	soldier.sim_pos = gate.sim_pos + Vector2(0.0, gate_half.y + 10.0)
	var gate_point := soldier._attack_approach_point(gate)
	check(_outside(gate_point, gate.sim_pos, gate_half) <= 1.5, "gates are still attacked at their logical edge")

func _test_ranged_range_counts_from_the_drawn_edge() -> void:
	_fixture()
	var barracks := _building(&"barracks", Vector2.ZERO, 1)
	var half := barracks.get_interaction_half()
	var archer := _unit(&"archer", Vector2.ZERO)
	var reach := archer.def.attack_range
	archer.sim_pos = Vector2(half.x + reach - 0.1, 0.0)
	check(archer._in_attack_range(barracks), "archer range is measured to the drawn edge")
	archer.sim_pos = Vector2(half.x + reach + 0.5, 0.0)
	check(not archer._in_attack_range(barracks), "archer beyond range of the drawn edge closes in")

func _run() -> void:
	_test_drawn_size()
	_test_trained_units_leave_the_drawn_building()
	_test_melee_attackers_stand_on_the_drawn_edge()
	_test_ranged_range_counts_from_the_drawn_edge()
	if is_instance_valid(world): world.free()
	print("BUILDING EDGE INTERACTION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
