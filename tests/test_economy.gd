extends RefCounted

const RESOURCE_NODE_SCRIPT := preload("res://scripts/entities/resource_node.gd")
const BUILDING_AGENT_SCRIPT := preload("res://scripts/entities/building_agent.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF: BuildingDef = preload("res://data/buildings/town_center.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_resource_extraction(failures)
	_test_gather_and_drop_off(failures)
	_test_gather_switch_drops_off_first(failures)
	return failures

func _test_resource_extraction(failures: Array[String]) -> void:
	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.amount = 6.0
	resource.gather_rate = 4.0
	if not is_equal_approx(resource.extract(1.0), 4.0):
		failures.append("resource should extract at its gather rate")
	if not is_equal_approx(resource.extract(1.0), 2.0):
		failures.append("resource extraction should be capped by remaining amount")
	if not is_zero_approx(resource.amount):
		failures.append("resource should become empty after final extraction")
	resource.free()

func _test_gather_and_drop_off(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var state := MatchState.new()
	state.setup_defaults()
	var initial_food := state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD)

	# Layout keeps resource outside TC hard-block (4x4 footprint + radius),
	# while drop-off still requires approaching the blocked building edge.
	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.resource_type = Enums.ResourceType.FOOD
	resource.amount = 100.0
	resource.gather_rate = 10.0
	resource.sim_pos = Vector2(1.0, 0.0)
	root.add_child(resource)

	var town_center := BUILDING_AGENT_SCRIPT.new()
	town_center.def = TOWN_CENTER_DEF
	town_center.team = Enums.Team.PLAYER
	town_center.accepts_all_resources = true
	town_center.sim_pos = Vector2(6.0, 0.0)
	root.add_child(town_center)

	var villager := UNIT_VIEW.instantiate()
	villager.def = VILLAGER_DEF
	villager.team = Enums.Team.PLAYER
	villager.match_state = state
	villager.sim_pos = Vector2.ZERO
	root.add_child(villager)
	villager.command_gather(resource)

	for _step in 40:
		villager._physics_process(0.25)

	if state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) <= initial_food:
		failures.append("villager should deposit gathered resources at a friendly drop-off")
	if villager.carry_amount > villager.carry_capacity:
		failures.append("villager carry amount should never exceed capacity")
	if villager.order != Enums.OrderType.GATHER:
		failures.append("villager should return to gathering while the node has resources")

	root.free()

func _test_gather_switch_drops_off_first(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var state := MatchState.new()
	state.setup_defaults()
	var initial_food := state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD)
	var initial_wood := state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.WOOD)

	var food := RESOURCE_NODE_SCRIPT.new()
	food.resource_type = Enums.ResourceType.FOOD
	food.amount = 100.0
	food.gather_rate = 10.0
	food.sim_pos = Vector2(1.0, 0.0)
	root.add_child(food)

	var wood := RESOURCE_NODE_SCRIPT.new()
	wood.resource_type = Enums.ResourceType.WOOD
	wood.amount = 100.0
	wood.gather_rate = 10.0
	wood.sim_pos = Vector2(10.0, 0.0)
	root.add_child(wood)

	var town_center := BUILDING_AGENT_SCRIPT.new()
	town_center.def = TOWN_CENTER_DEF
	town_center.team = Enums.Team.PLAYER
	town_center.accepts_all_resources = true
	town_center.sim_pos = Vector2(6.0, 0.0)
	root.add_child(town_center)

	var villager := UNIT_VIEW.instantiate()
	villager.def = VILLAGER_DEF
	villager.team = Enums.Team.PLAYER
	villager.match_state = state
	villager.sim_pos = Vector2.ZERO
	root.add_child(villager)
	villager.carry_type = Enums.ResourceType.FOOD
	villager.carry_amount = 5.0
	villager.command_gather(wood)

	if villager.get("_gather_state") != "to_drop_off":
		failures.append("gather type switch with carry should begin drop-off first")
	if villager.carry_type != Enums.ResourceType.FOOD:
		failures.append("gather type switch should keep current carry until drop-off")

	for _step in 40:
		villager._physics_process(0.25)

	if state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) <= initial_food:
		failures.append("type-switch gather should deposit the previous carry first")
	if villager.carry_type != -1 and villager.carry_type != Enums.ResourceType.WOOD:
		failures.append("after drop-off, villager should gather the new resource type")
	if (
		state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.WOOD) <= initial_wood
		and villager.carry_type != Enums.ResourceType.WOOD
		and villager.carry_amount <= 0.0
	):
		failures.append("after drop-off, villager should start gathering the new node")

	root.free()
