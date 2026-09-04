extends RefCounted

const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const VisionServiceHolderScript := preload("res://scripts/systems/vision_service_holder.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const SWORDSMAN_DEF := preload("res://data/units/swordsman.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const BUILDING_AGENT_SCRIPT := preload("res://scripts/entities/building_agent.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	EntityRegistryScript.clear()
	_test_enemy_hidden_outside_vision(failures)
	return failures


func _test_enemy_hidden_outside_vision(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var vision_holder := VisionServiceHolderScript.new()
	vision_holder.setup(2.0)
	tree.root.add_child(vision_holder)

	var state := MatchState.new()
	state.setup_defaults()

	var own_tc := BUILDING_AGENT_SCRIPT.new()
	own_tc.def = TOWN_CENTER_DEF
	own_tc.team = Enums.Team.PLAYER
	own_tc.sim_pos = Vector2(0.0, 0.0)
	own_tc.is_complete = true
	own_tc.hp = 2400.0
	root.add_child(own_tc)

	var scout := UNIT_VIEW.instantiate()
	scout.def = SWORDSMAN_DEF
	scout.team = Enums.Team.PLAYER
	scout.match_state = state
	scout.sim_pos = Vector2(0.0, 0.0)
	scout.hp = float(SWORDSMAN_DEF.max_hp)
	scout.set("vision_radius_override", 5.0)
	root.add_child(scout)
	vision_holder.vision.register(scout)

	var far_enemy := UNIT_VIEW.instantiate()
	far_enemy.def = SWORDSMAN_DEF
	far_enemy.team = Enums.Team.AI
	far_enemy.match_state = state
	far_enemy.sim_pos = Vector2(500.0, 0.0)
	far_enemy.hp = float(SWORDSMAN_DEF.max_hp)
	root.add_child(far_enemy)
	vision_holder.vision.register(far_enemy)

	var observation := ObservationBuilderScript.build(
		state, root, Enums.Team.PLAYER, Enums.Team.AI, 0.0, 20.0
	)
	var holders := root.get_tree().get_nodes_in_group("vision_service")
	if holders.is_empty():
		failures.append("vision_service group should be present in scene tree")
	for entity in observation.get("entities", []):
		if entity is Dictionary and int(entity.get("team", -1)) == int(Enums.Team.AI):
			failures.append(
				"enemy outside vision should not appear in observation entities (got %s)"
				% JSON.stringify(entity)
			)
			break

	vision_holder.free()
	root.free()
