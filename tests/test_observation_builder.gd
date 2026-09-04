extends RefCounted

const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const AiBlackboardScript := preload("res://scripts/systems/ai/ai_blackboard.gd")
const RESOURCE_NODE_SCRIPT := preload("res://scripts/entities/resource_node.gd")
const BUILDING_AGENT_SCRIPT := preload("res://scripts/entities/building_agent.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const SWORDSMAN_DEF := preload("res://data/units/swordsman.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const HOUSE_DEF := preload("res://data/buildings/house.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	EntityRegistryScript.clear()
	AiEventBufferScript.clear()
	_test_observation_matches_blackboard(failures)
	EntityRegistryScript.clear()
	AiEventBufferScript.clear()
	_test_json_safe_snapshot(failures)
	return failures


func _test_observation_matches_blackboard(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var state := MatchState.new()
	state.setup_defaults()

	var player_tc := BUILDING_AGENT_SCRIPT.new()
	player_tc.def = TOWN_CENTER_DEF
	player_tc.team = Enums.Team.PLAYER
	player_tc.sim_pos = Vector2(-40.0, -40.0)
	player_tc.is_complete = true
	player_tc.hp = 2400.0
	root.add_child(player_tc)

	var ai_tc := BUILDING_AGENT_SCRIPT.new()
	ai_tc.def = TOWN_CENTER_DEF
	ai_tc.team = Enums.Team.AI
	ai_tc.sim_pos = Vector2(40.0, 40.0)
	ai_tc.is_complete = true
	ai_tc.hp = 2400.0
	root.add_child(ai_tc)

	var house := BUILDING_AGENT_SCRIPT.new()
	house.def = HOUSE_DEF
	house.team = Enums.Team.PLAYER
	house.sim_pos = Vector2(-34.0, -40.0)
	house.start_construction()
	root.add_child(house)

	var villager := UNIT_VIEW.instantiate()
	villager.def = VILLAGER_DEF
	villager.team = Enums.Team.PLAYER
	villager.match_state = state
	villager.sim_pos = Vector2(-38.0, -40.0)
	root.add_child(villager)

	var swordsman := UNIT_VIEW.instantiate()
	swordsman.def = SWORDSMAN_DEF
	swordsman.team = Enums.Team.PLAYER
	swordsman.match_state = state
	swordsman.sim_pos = Vector2(-36.0, -38.0)
	root.add_child(swordsman)

	var enemy := UNIT_VIEW.instantiate()
	enemy.def = SWORDSMAN_DEF
	enemy.team = Enums.Team.AI
	enemy.match_state = state
	enemy.sim_pos = Vector2(-25.0, -40.0)
	root.add_child(enemy)

	var food := RESOURCE_NODE_SCRIPT.new()
	food.resource_type = Enums.ResourceType.FOOD
	food.amount = 120.0
	food.sim_pos = Vector2(-25.0, -20.0)
	root.add_child(food)

	var blackboard := AiBlackboardScript.new()
	blackboard.refresh(state, root, Enums.Team.PLAYER, Enums.Team.AI, 12.5, 20.0)

	var observation := ObservationBuilderScript.build(
		state, root, Enums.Team.PLAYER, Enums.Team.AI, 12.5, 20.0
	)
	var economy: Dictionary = observation.get("economy", {})
	var derived: Dictionary = observation.get("derived", {})

	if int(economy.get("food")) != blackboard.food:
		failures.append("observation economy.food should match blackboard")
	if int(economy.get("wood")) != blackboard.wood:
		failures.append("observation economy.wood should match blackboard")
	if int(economy.get("gold")) != blackboard.gold:
		failures.append("observation economy.gold should match blackboard")
	if int(economy.get("pop_used")) != blackboard.pop_used:
		failures.append("observation economy.pop_used should match blackboard")
	if int(economy.get("pop_cap")) != blackboard.pop_cap:
		failures.append("observation economy.pop_cap should match blackboard")

	if int(derived.get("villager_count")) != blackboard.villager_count:
		failures.append("observation derived.villager_count should match blackboard")
	if int(derived.get("military_count")) != blackboard.military_count:
		failures.append("observation derived.military_count should match blackboard")
	if int(derived.get("incomplete_buildings")) != blackboard.incomplete_buildings:
		failures.append("observation derived.incomplete_buildings should match blackboard")
	if bool(derived.get("threat_near_base")) != blackboard.threat_near_base:
		failures.append("observation derived.threat_near_base should match blackboard")

	var own_tc_pos: Array = derived.get("own_tc_pos", [])
	if own_tc_pos.size() != 2:
		failures.append("derived.own_tc_pos should be [x, y]")
	elif not is_equal_approx(float(own_tc_pos[0]), blackboard.own_tc_pos.x):
		failures.append("derived.own_tc_pos.x should match blackboard")
	elif not is_equal_approx(float(own_tc_pos[1]), blackboard.own_tc_pos.y):
		failures.append("derived.own_tc_pos.y should match blackboard")

	var entities: Array = observation.get("entities", [])
	if entities.size() < 6:
		failures.append("observation should include units, buildings, and resources")

	var found_villager := false
	for entity in entities:
		var entity_dict: Dictionary = entity
		if entity_dict.get("kind") == "unit" and entity_dict.get("def_id") == "villager":
			found_villager = true
			if entity_dict.get("order") == null:
				failures.append("unit snapshot should include order")
	if not found_villager:
		failures.append("observation should include villager entity")

	root.free()


func _test_json_safe_snapshot(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var state := MatchState.new()
	state.setup_defaults()
	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.resource_type = Enums.ResourceType.WOOD
	resource.amount = 50.0
	resource.sim_pos = Vector2(3.0, 4.0)
	root.add_child(resource)

	var payload := ObservationBuilderScript.build_json_safe(
		state, root, Enums.Team.PLAYER, Enums.Team.AI, 0.0
	)
	var json_text := JSON.stringify(payload)
	if json_text.is_empty():
		failures.append("json_safe observation should stringify")
	var parsed: Variant = JSON.parse_string(json_text)
	if parsed == null:
		failures.append("json_safe observation should parse back as JSON")

	root.free()
