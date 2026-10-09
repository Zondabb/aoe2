extends SceneTree

## Actual UnitAgent state-machine regression cases. Units are stepped manually
## so depletion, carrying, orders and navigation stay deterministic.
const FarmScript := preload("res://scripts/entities/farm_agent.gd")
const FogService := preload("res://scripts/systems/fog_of_war_service.gd")

var checks := 0
var failures: Array[String] = []

class Fixture extends RefCounted:
	var world: Node2D
	var state: MatchState
	var workers: Array[UnitAgent] = []
	var nav: NavServiceHolder

class VisionSource extends Node2D:
	var sim_pos := Vector2.ZERO
	var team := Enums.Team.PLAYER
	var hp := 1.0
	var radius := 2.0
	func resolved_vision_radius() -> float: return radius

class HiddenResource extends Node2D:
	var sim_pos := Vector2.ZERO
	var resource_type := Enums.ResourceType.WOOD
	var gather_rate := 4.0
	var block_size := Vector2.ZERO
	var stock := 100.0
	var stock_reads := 0
	var amount: float:
		get:
			stock_reads += 1
			return stock
	func _ready() -> void: add_to_group("resource_nodes")
	func extract(delta: float) -> float:
		var value := minf(stock, delta * gather_rate)
		stock -= value
		return value

class Wall extends Node2D:
	var sim_pos := Vector2.ZERO
	var block_size := Vector2.ZERO
	func _ready() -> void: add_to_group("path_blockers")

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func fixture() -> Fixture:
	var result := Fixture.new()
	result.world = Node2D.new()
	root.add_child(result.world)
	result.state = MatchState.new()
	result.state.setup_defaults()
	result.state.fog_enabled = false
	return result

func worker(f: Fixture, pos: Vector2, capacity := 10.0) -> UnitAgent:
	var unit: UnitAgent = load("res://scenes/entities/unit_view.tscn").instantiate()
	unit.def = GameCatalog.get_unit(&"villager")
	unit.match_state = f.state
	unit.sim_pos = pos
	unit.carry_capacity = capacity
	f.world.add_child(unit)
	unit.set_physics_process(false)
	f.workers.append(unit)
	return unit

func resource(f: Fixture, type: Enums.ResourceType, pos: Vector2, amount := 100.0) -> ResourceNode:
	var node := ResourceNode.new()
	node.resource_type = type
	node.sim_pos = pos
	node.amount = amount
	f.world.add_child(node)
	return node

func town_center(f: Fixture, pos: Vector2) -> BuildingAgent:
	var building := BuildingAgent.new()
	building.def = GameCatalog.get_building(&"town_center")
	building.match_state = f.state
	building.sim_pos = pos
	building.accepts_all_resources = true
	f.world.add_child(building)
	building.set_physics_process(false)
	return building

func farm(f: Fixture, pos: Vector2, team := Enums.Team.PLAYER, complete := true, ghost := false) -> BuildingAgent:
	var building: BuildingAgent = FarmScript.new()
	building.def = GameCatalog.get_building(&"farm")
	building.match_state = f.state
	building.sim_pos = pos
	building.team = team
	building.is_complete = complete
	building.is_placement_ghost = ghost
	f.world.add_child(building)
	building.set_physics_process(false)
	# Force invalid fixtures into the shared candidate group as a defensive test.
	building.add_to_group("resource_nodes")
	return building

func enable_nav(f: Fixture) -> void:
	f.nav = NavServiceHolder.new()
	f.nav.setup(-80, 80)
	f.world.add_child(f.nav)
	f.nav.set_process(false)
	f.nav.rebuild_from_scene()

func step(f: Fixture, count := 1, delta := 0.1) -> void:
	for frame in count:
		if f.nav != null: f.nav._process(delta)
		for unit in f.workers:
			if is_instance_valid(unit): unit._physics_process(delta)

func dispose(f: Fixture) -> void:
	f.world.free()
	CollisionResolver.clear_map_bounds()

func _run() -> void:
	for type in [Enums.ResourceType.FOOD, Enums.ResourceType.WOOD, Enums.ResourceType.GOLD, Enums.ResourceType.STONE]:
		_test_partial_continuation(type)
	_test_deleted_targets()
	_test_shared_depletion()
	_test_full_load_and_area()
	_test_no_candidates()
	_test_only_distant_candidate()
	_test_resource_switch()
	_test_hidden_candidates()
	_test_hidden_original_target()
	_test_hidden_automatic_target_return()
	_test_full_depletion_hidden_return()
	_test_farm_filters()
	_test_unreachable_nearest()
	_test_dense_forest_continuation()
	_test_explicit_orders()
	_test_replica()
	print("GATHER CONTINUATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_partial_continuation(type: Enums.ResourceType) -> void:
	var f := fixture()
	var first := resource(f, type, Vector2(20, 0), 2.0)
	var nearest := resource(f, type, Vector2(24, 4), 8.0)
	var further := resource(f, type, Vector2(32, 0), 100.0)
	var wrong_type: Enums.ResourceType = Enums.ResourceType.FOOD if type != Enums.ResourceType.FOOD else Enums.ResourceType.WOOD
	var wrong := resource(f, wrong_type, Vector2(20, 3), 100.0)
	var empty := resource(f, type, Vector2(21, 1), 0.0)
	var queued := resource(f, type, Vector2(21, 2), 100.0)
	queued.queue_free()
	var unit := worker(f, Vector2(17, 0))
	unit.command_gather(first)
	for frame in 80:
		step(f)
		if first.amount == 0.0: break
	step(f)
	check(first.amount == 0.0, "type %d: original node really depletes" % type)
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == nearest, "type %d: worker chooses nearest positive node of the same type" % type)
	check(unit._gather_state != "to_drop_off" and is_equal_approx(unit.carry_amount, 2.0), "type %d: a partial load continues without an early delivery" % type)
	check(wrong.amount == 100.0 and further.amount == 100.0 and empty.amount == 0.0, "type %d: wrong, farther and exhausted nodes stay untouched" % type)
	for frame in 160:
		step(f)
		if nearest.amount < 8.0: break
	check(nearest.amount < 8.0 and unit.carry_amount > 2.0, "type %d: worker walks to the next node and actually extracts" % type)
	check(is_equal_approx(unit.carry_amount + first.amount + nearest.amount, 10.0), "type %d: continuation conserves extracted stock and carried resources" % type)
	dispose(f)

func _test_deleted_targets() -> void:
	for deletion in ["free", "queued"]:
		var f := fixture()
		var first := resource(f, Enums.ResourceType.WOOD, Vector2(10, 0))
		var next := resource(f, Enums.ResourceType.WOOD, Vector2(14, 0))
		var unit := worker(f, Vector2(7, 0))
		unit.command_gather(first)
		if deletion == "free": first.free()
		else: first.queue_free()
		step(f)
		check(unit.order == Enums.OrderType.GATHER and unit._gather_target == next, "%s target: stale references safely retarget using remembered type and location" % deletion)
		dispose(f)

func _test_shared_depletion() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO, 1.0)
	var next := resource(f, Enums.ResourceType.WOOD, Vector2(5, 0), 100.0)
	var a := worker(f, Vector2(-2, -1), 100.0)
	var b := worker(f, Vector2(-2, 1), 100.0)
	a.command_gather(first)
	b.command_gather(first)
	for frame in 60:
		step(f)
		if first.amount == 0.0 and a._gather_target == next and b._gather_target == next: break
	check(first.amount == 0.0 and a._gather_target == next and b._gather_target == next, "both workers continue when one depletes their shared tree")
	check(a.order == Enums.OrderType.GATHER and b.order == Enums.OrderType.GATHER, "the worker that received no final stock remains a gatherer")
	for frame in 100:
		step(f)
		if a.carry_amount > 1.0 and b.carry_amount > 1.0: break
	check(a.carry_amount > 1.0 and b.carry_amount > 1.0, "both crowded workers reach and harvest their replacement tree")
	check(is_equal_approx(a.carry_amount + b.carry_amount + next.amount, 101.0), "shared depletion neither duplicates nor loses the last extraction")
	dispose(f)

func _test_full_load_and_area() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2(50, 0), 10.0)
	var original_area := resource(f, Enums.ResourceType.WOOD, Vector2(55, 3), 100.0)
	# Their distance order reverses after the villager reaches its storage.
	var by_drop_off := resource(f, Enums.ResourceType.WOOD, Vector2(5, 14), 100.0)
	var unit := worker(f, Vector2(47, 0))
	town_center(f, Vector2.ZERO)
	var initial := f.state.get_resource(unit.team, Enums.ResourceType.WOOD)
	unit.command_gather(first)
	for frame in 120:
		step(f)
		if unit._gather_state == "to_drop_off": break
	check(first.amount == 0.0 and is_equal_approx(unit.carry_amount, 10.0) and unit._gather_state == "to_drop_off", "a full load returns to storage before choosing the replacement resource")
	check(original_area.amount == 100.0, "a full villager extracts nothing from the next tree before depositing")
	first.free()
	for frame in 500:
		step(f)
		if f.state.get_resource(unit.team, Enums.ResourceType.WOOD) > initial: break
	check(f.state.get_resource(unit.team, Enums.ResourceType.WOOD) == initial + 10 and unit.carry_amount == 0.0, "full-load continuation deposits exactly once and clears the carried load")
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == original_area, "replacement selection stays anchored at the original forest even when its node is freed during delivery")
	check(by_drop_off.amount == 100.0, "a tree beside storage cannot steal a villager from its original work area")
	dispose(f)

func _test_no_candidates() -> void:
	for initial_carry in [0.0, 3.0]:
		var f := fixture()
		var first := resource(f, Enums.ResourceType.STONE, Vector2(16, 0))
		var unrelated := resource(f, Enums.ResourceType.WOOD, Vector2(70, 0))
		var unit := worker(f, Vector2(13, 0))
		town_center(f, Vector2.ZERO)
		var initial := f.state.get_resource(unit.team, Enums.ResourceType.STONE)
		unit.command_gather(first)
		unit.carry_type = Enums.ResourceType.STONE if initial_carry > 0.0 else -1
		unit.carry_amount = initial_carry
		first.amount = 0.0
		step(f, 200)
		check(unit.order == Enums.OrderType.NONE, "no same-type candidate: carry %.0f eventually becomes idle" % initial_carry)
		check(f.state.get_resource(unit.team, Enums.ResourceType.STONE) == initial + int(initial_carry) and unit.carry_amount == 0.0, "no same-type candidate: carry %.0f is delivered without loss" % initial_carry)
		check(unrelated.amount == 100.0, "no same-type candidate: the worker does not switch to another resource type")
		dispose(f)
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2(10, 0))
	var unit := worker(f, Vector2(7, 0))
	unit.command_gather(first)
	unit.carry_amount = 3.0
	unit.carry_type = Enums.ResourceType.WOOD
	first.amount = 0.0
	step(f, 3)
	check(unit.order == Enums.OrderType.NONE and unit.carry_amount == 3.0, "no resource or storage: the villager keeps its carried stock")
	dispose(f)

func _test_only_distant_candidate() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.STONE, Vector2(16, 0))
	var distant := resource(f, Enums.ResourceType.STONE, Vector2(70, 0))
	var unit := worker(f, Vector2(13, 0))
	unit.command_gather(first)
	first.amount = 0.0
	step(f)
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == distant, "the only remaining visible same-type resource is selectable beyond the original work area")
	for frame in 250:
		step(f)
		if distant.amount < 100.0: break
	check(distant.amount < 100.0 and unit.carry_type == Enums.ResourceType.STONE, "the villager travels to and harvests a distant visible replacement when no nearer candidate exists")
	dispose(f)

func _test_resource_switch() -> void:
	var f := fixture()
	var gold := resource(f, Enums.ResourceType.GOLD, Vector2(20, 0), 1.0)
	var more_gold := resource(f, Enums.ResourceType.GOLD, Vector2(25, 0), 100.0)
	var wood := resource(f, Enums.ResourceType.WOOD, Vector2(19, 3), 100.0)
	var unit := worker(f, Vector2(17, 0))
	town_center(f, Vector2.ZERO)
	var wood_initial := f.state.get_resource(unit.team, Enums.ResourceType.WOOD)
	var gold_initial := f.state.get_resource(unit.team, Enums.ResourceType.GOLD)
	unit.carry_type = Enums.ResourceType.WOOD
	unit.carry_amount = 4.0
	unit.command_gather(gold)
	gold.amount = 0.0
	check(unit._gather_state == "to_drop_off", "changing resource type first schedules delivery of the old carried type")
	for frame in 200:
		step(f)
		if unit.carry_type == Enums.ResourceType.GOLD: break
	check(f.state.get_resource(unit.team, Enums.ResourceType.WOOD) == wood_initial + 4, "switching to gold credits existing wood to the wood ledger")
	check(unit._gather_target == more_gold and unit.carry_type == Enums.ResourceType.GOLD and unit.carry_amount > 0.0, "depleted new command target continues with gold after the old wood is delivered")
	check(wood.amount == 100.0 and f.state.get_resource(unit.team, Enums.ResourceType.GOLD) == gold_initial, "a type switch cannot retarget old-type wood or credit it as gold")
	dispose(f)

func _test_hidden_candidates() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO)
	var visible := resource(f, Enums.ResourceType.WOOD, Vector2(8, 0))
	var hidden := HiddenResource.new()
	hidden.sim_pos = Vector2(3, 0)
	f.world.add_child(hidden)
	var unit := worker(f, Vector2(-3, 0))
	unit.set_vision_radius(4.0)
	var source := VisionSource.new()
	source.sim_pos = visible.sim_pos
	f.world.add_child(source)
	f.state.fog = FogService.new()
	f.state.fog.setup(-80, 80)
	f.state.fog_enabled = true
	f.state.fog.rebuild([unit, source])
	check(f.state.fog.can_see(unit.team, first) and not f.state.fog.can_see(unit.team, hidden) and f.state.fog.can_see(unit.team, visible), "fog fixture exposes the old node and farther replacement, hiding the nearest node")
	enable_nav(f)
	unit.command_gather(first)
	first.amount = 0.0
	f.nav.rebuild_from_scene()
	hidden.stock_reads = 0
	step(f)
	check(unit._gather_target == visible, "automatic continuation only chooses currently visible resource candidates")
	check(hidden.stock_reads == 0, "candidate filtering never reads hidden resource stock")
	dispose(f)

func _test_hidden_original_target() -> void:
	var f := fixture()
	var known := HiddenResource.new()
	known.sim_pos = Vector2.ZERO
	f.world.add_child(known)
	var next := resource(f, Enums.ResourceType.WOOD, Vector2(4, 0))
	var unit := worker(f, Vector2(-3, 0))
	unit.set_vision_radius(6.0)
	f.state.fog = FogService.new()
	f.state.fog.setup(-80, 80)
	f.state.fog_enabled = true
	f.state.fog.rebuild([unit])
	unit.command_gather(known)
	check(unit._gather_target == known, "the original hidden-stock probe is initially observed and commanded")
	# The real holder keeps collision queries local. The standalone fallback
	# intentionally reads all blocker stock independently of gathering decisions.
	enable_nav(f)
	unit.sim_pos = Vector2(-30, 0)
	f.state.fog.rebuild([unit])
	known.stock = 0.0
	known.stock_reads = 0
	step(f, 3)
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == known and unit._gather_state == "to_resource", "losing vision preserves the observed gather target until the villager revisits it")
	check(known.stock_reads == 0 and next.amount == 100.0, "a hidden original node's depletion is not read or used for early retargeting")
	check(unit.sim_pos.x > -30.0, "a worker returns toward its remembered original work position through fog")
	dispose(f)

func _test_hidden_automatic_target_return() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2(20, 0), 1.0)
	first.block_size_override = Vector2(4, 4)
	var next := resource(f, Enums.ResourceType.WOOD, Vector2(28, 0), 100.0)
	next.block_size_override = Vector2(4, 4)
	var unit := worker(f, Vector2(17, 0), 5.0)
	unit.set_vision_radius(4.0)
	town_center(f, Vector2(0, -10))
	var source := VisionSource.new()
	source.sim_pos = next.sim_pos
	source.radius = 4.0
	f.world.add_child(source)
	f.state.fog = FogService.new()
	f.state.fog.setup(-80, 80)
	f.state.fog_enabled = true
	f.state.fog.rebuild([unit, source])
	enable_nav(f)
	unit.command_gather(first)
	for frame in 140:
		step(f)
		if unit._gather_state == "to_drop_off": break
	check(first.amount == 0.0 and next.amount < 100.0 and unit._automatic_gather_target and unit._gather_state == "to_drop_off", "a real 4x4 replacement tree supplies a full load before the fog-return test")
	var work_goal: Vector2 = unit._automatic_gather_goal
	check(work_goal.distance_to(next.sim_pos) > UnitAgent.GATHER_RANGE, "the automatic work goal is outside the tree's blocked center")
	source.free()
	# Deliver at storage after its vision source no longer sees the work site.
	# The trip is skipped here to isolate the retained goal from fog refresh timing.
	unit.sim_pos = Vector2(0, -10)
	f.state.fog.rebuild([unit])
	check(not f.state.fog.can_see(unit.team, next), "the automatically chosen tree is hidden when the worker deposits")
	var center_path: PackedVector2Array = f.nav.nav.find_path(unit.sim_pos, next.sim_pos, unit._pathfinding_radius())
	check(not center_path.is_empty() and center_path[-1].distance_to(work_goal) > UnitAgent.GATHER_RANGE, "the hidden-return fixture would reject navigation toward the blocked tree center")
	var stock := next.amount
	step(f, 3)
	check(unit._gather_target == next and unit._gather_state == "to_resource" and unit._automatic_gather_goal == work_goal, "returning through fog preserves the automatic resource and validated work goal")
	check(not unit._path.is_empty() and unit._path[-1].distance_to(work_goal) <= UnitAgent.GATHER_RANGE, "the real return path reaches the remembered work point instead of a projected tree center")
	check(next.amount == stock and unit.carry_amount == 0.0 and unit.sim_pos.y > -10.0, "the worker deposits once and starts returning without extracting hidden stock")
	dispose(f)


func _test_full_depletion_hidden_return() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2(20, 0), 5.0)
	first.block_size_override = Vector2(4, 4)
	var next := HiddenResource.new()
	next.sim_pos = Vector2(28, 0)
	f.world.add_child(next)
	var unit := worker(f, Vector2(17, 0), 5.0)
	unit.set_vision_radius(4.0)
	town_center(f, Vector2(0, -10))
	var source := VisionSource.new()
	source.sim_pos = next.sim_pos
	source.radius = 4.0
	f.world.add_child(source)
	f.state.fog = FogService.new()
	f.state.fog.setup(-80, 80)
	f.state.fog_enabled = true
	f.state.fog.rebuild([unit, source])
	enable_nav(f)
	unit.command_gather(first)
	for frame in 140:
		step(f)
		if unit._gather_state == "to_drop_off": break
	check(first.amount == 0.0 and unit.carry_amount == 5.0 and unit._gather_state == "to_drop_off", "full depletion begins delivery after the original tree supplies its final five wood")
	check(unit._gather_target == next and unit._automatic_gather_target and next.stock == 100.0, "full depletion remembers a reachable visible replacement before departing without extracting from it")
	source.free()
	unit.sim_pos = Vector2(0, -10)
	f.state.fog.rebuild([unit])
	check(not f.state.fog.can_see(unit.team, next), "the next tree is hidden after the full-depletion villager reaches storage")
	# Another worker can deplete it while hidden; the returning worker cannot
	# discover that fact until it sees the remembered site again.
	next.stock = 0.0
	next.stock_reads = 0
	var initial := f.state.get_resource(unit.team, Enums.ResourceType.WOOD)
	step(f, 3)
	check(f.state.get_resource(unit.team, Enums.ResourceType.WOOD) == initial + 5 and unit.carry_amount == 0.0, "full depletion deposits its last load once before resuming the remembered job")
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == next and unit._gather_state == "to_resource" and unit.sim_pos.y > -10.0, "full depletion resumes toward its remembered replacement even when no forest is currently visible")
	check(next.stock_reads == 0, "the full-depletion return never inspects its hidden replacement's changed stock")
	dispose(f)


func _test_farm_filters() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.FOOD, Vector2.ZERO)
	var unfinished := farm(f, Vector2(3, 0), Enums.Team.PLAYER, false)
	var ghost := farm(f, Vector2(4, 0), Enums.Team.PLAYER, true, true)
	var enemy := farm(f, Vector2(5, 0), Enums.Team.AI)
	var depleted := farm(f, Vector2(6, 0))
	depleted.amount = 0.0
	var dead := farm(f, Vector2(7, 0))
	dead.hp = 0.0
	var valid := farm(f, Vector2(10, 0))
	var fallback := resource(f, Enums.ResourceType.FOOD, Vector2(14, 0))
	var unit := worker(f, Vector2(-3, 0))
	unit.command_gather(first)
	first.amount = 0.0
	step(f)
	check(unit._gather_target == valid and unit.order == Enums.OrderType.GATHER, "food continuation permits a completed own farm and rejects invalid nearer plots")
	check(unfinished.amount == 175.0 and ghost.amount == 175.0 and enemy.amount == 175.0 and depleted.amount == 0.0 and dead.amount == 175.0 and fallback.amount == 100.0, "enemy, ghost, unfinished, dead and exhausted farm candidates are never harvested")
	unit.sim_pos = valid.sim_pos
	step(f, 2)
	check(valid.amount < 175.0 and unit.carry_type == Enums.ResourceType.FOOD and unit.carry_amount > 0.0, "replacement farm provides food through its real extract method")
	dispose(f)

func wall(f: Fixture, pos: Vector2, size: Vector2) -> void:
	var obstacle := Wall.new()
	obstacle.sim_pos = pos
	obstacle.block_size = size
	f.world.add_child(obstacle)

func _test_unreachable_nearest() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO)
	var sealed := resource(f, Enums.ResourceType.WOOD, Vector2(8, 0))
	var accessible := resource(f, Enums.ResourceType.WOOD, Vector2(0, 12))
	wall(f, Vector2(8, -4), Vector2(12, 2))
	wall(f, Vector2(8, 4), Vector2(12, 2))
	wall(f, Vector2(3, 0), Vector2(2, 10))
	wall(f, Vector2(13, 0), Vector2(2, 10))
	var unit := worker(f, Vector2(-3, 0))
	enable_nav(f)
	unit.command_gather(first)
	first.amount = 0.0
	f.nav.rebuild_from_scene()
	for frame in 60:
		step(f)
		if unit._gather_state == "to_resource" and unit._gather_target == accessible: break
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == accessible, "real navigation skips a nearer resource inside a closed wall enclosure")
	for frame in 180:
		step(f)
		if accessible.amount < 100.0: break
	check(accessible.amount < 100.0 and sealed.amount == 100.0, "the replacement path reaches the farther open tree without crossing the enclosure")
	dispose(f)

func _test_dense_forest_continuation() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO, 1.0)
	var next := resource(f, Enums.ResourceType.WOOD, Vector2(4, 0), 1.0)
	var third := resource(f, Enums.ResourceType.WOOD, Vector2(8, 0), 100.0)
	var forest: Array[ResourceNode] = [first, next, third]
	# One original terrain tile per tree, matching the generated dense forests.
	# The outside rows prevent going through a tree's north/south boundary.
	for x in [0.0, 4.0, 8.0]:
		for y in [-4.0, 4.0]:
			forest.append(resource(f, Enums.ResourceType.WOOD, Vector2(x, y), 100.0))
	for tree in forest:
		tree.block_size_override = Vector2(4, 4)
	var unit := worker(f, Vector2(-4, 0))
	enable_nav(f)
	unit.command_gather(first)
	var crossed_cleared_tile := false
	for frame in 240:
		step(f)
		if first.amount == 0.0 and unit.sim_pos.x > -2.0 and unit.sim_pos.x < 2.0:
			crossed_cleared_tile = true
		if next.amount == 0.0 and unit._gather_target == third: break
	check(first.amount == 0.0 and next.amount == 0.0, "real navigation and extraction exhaust two adjacent 4x4 forest trees in sequence")
	check(unit.order == Enums.OrderType.GATHER and unit._gather_target == third, "the forest worker continues onto the next nearest tree after the second depletion")
	check(crossed_cleared_tile, "depleted tree collision is released so the worker can enter the cleared forest tile")
	check(is_equal_approx(unit.carry_amount + third.amount, 102.0), "two forest depletions conserve the partial load while the next tree remains selected")
	for index in range(3, forest.size()):
		check(forest[index].amount == 100.0, "neighbor forest tree %d remains unharvested during nearest-tree continuation" % index)
	dispose(f)


func _test_explicit_orders() -> void:
	for command in ["stop", "move", "build", "attack"]:
		var f := fixture()
		var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO)
		var next := resource(f, Enums.ResourceType.WOOD, Vector2(5, 0))
		var unit := worker(f, Vector2(-3, 0))
		unit.command_gather(first)
		match command:
			"stop": unit.command_stop()
			"move": unit.command_move(Vector2(-20, 0))
			"build":
				var building := BuildingAgent.new()
				building.def = GameCatalog.get_building(&"house")
				building.match_state = f.state
				building.sim_pos = Vector2(-20, 0)
				building.is_complete = false
				f.world.add_child(building)
				unit.command_build(building)
			"attack":
				var enemy := worker(f, Vector2(-20, 0))
				enemy.team = Enums.Team.AI
				unit.command_attack(enemy)
		first.amount = 0.0
		step(f, 3)
		var expected: Enums.OrderType = {"stop": Enums.OrderType.NONE, "move": Enums.OrderType.MOVE, "build": Enums.OrderType.BUILD, "attack": Enums.OrderType.ATTACK}[command]
		check(unit.order == expected and unit._gather_target == null and next.amount == 100.0, "%s cancels the gather job and cannot silently resume at the next resource" % command)
		dispose(f)

func _test_replica() -> void:
	var f := fixture()
	var first := resource(f, Enums.ResourceType.WOOD, Vector2.ZERO)
	var next := resource(f, Enums.ResourceType.WOOD, Vector2(5, 0))
	var unit := worker(f, Vector2(-3, 0))
	unit.command_gather(first)
	unit.set_meta("network_replica", true)
	first.amount = 0.0
	var before := unit.sim_pos
	step(f, 20)
	check(unit._gather_target == first and unit.sim_pos == before and next.amount == 100.0, "network replicas never simulate local resource continuation or extraction")
	dispose(f)
