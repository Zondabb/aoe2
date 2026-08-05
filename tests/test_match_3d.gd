# tests/test_match_3d.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var game_session := tree.root.get_node_or_null("GameSession")
	if game_session == null:
		failures.append("GameSession should be configured as an autoload")
	else:
		game_session.set("player_civ_id", &"chinese")
		game_session.set("ai_civ_id", &"teutons")
	var packed := load("res://scenes/match_3d.tscn") as PackedScene
	if packed == null:
		failures.append("match scene should load")
		return failures

	var scene_root := packed.instantiate()
	tree.root.add_child(scene_root)
	scene_root.get_node("Bootstrap").call("_ready")
	if not scene_root.get_node_or_null("Map/Ground") is MeshInstance3D:
		failures.append("match scene should contain ground mesh")
	var camera := scene_root.get_node_or_null("CameraRig/Camera3D") as Camera3D
	if camera == null:
		failures.append("match scene should contain camera")
	elif camera.get_script() == null:
		failures.append("match camera should have controller script")
	else:
		camera.call("_ready")
		if camera.get("pitch_degrees") != 50.0 or camera.get("yaw_degrees") != 45.0:
			failures.append("match camera should use the requested view angles")
		var zoom_event := InputEventMouseButton.new()
		zoom_event.button_index = MOUSE_BUTTON_WHEEL_UP
		zoom_event.pressed = true
		for index in 10:
			camera.call("_unhandled_input", zoom_event)
		if camera.get("distance") != 18.0:
			failures.append("match camera zoom should clamp at minimum distance")
		var rig := camera.get_parent_node_3d()
		var original_rig_position := rig.position
		camera.call("_pan", Vector2.RIGHT, 1.0)
		if rig.position == original_rig_position:
			failures.append("match camera pan should move its rig")
	if scene_root.get_node_or_null("Entities") == null:
		failures.append("match scene should contain entities root")
	if scene_root.get_node_or_null("Bootstrap") == null:
		failures.append("match scene should contain bootstrap")
	var selection := scene_root.get_node_or_null("SelectionController")
	if selection == null or selection.get_script() == null:
		failures.append("match scene should contain selection controller")
	else:
		selection.call("_ready")
	var build_system := scene_root.get_node_or_null("BuildSystem")
	if build_system == null or build_system.get_script() == null:
		failures.append("match scene should contain a wired build system")
	elif build_system.get("match_state") == null:
		failures.append("bootstrap should configure the build system")
	var hud := scene_root.get_node_or_null("HUD")
	if hud == null or hud.get_script() == null:
		failures.append("match scene should contain the building HUD")
	elif hud.get("build_system") != build_system or hud.get("selection") != selection:
		failures.append("bootstrap should connect HUD building controls")

	var entities := scene_root.get_node("Entities")
	if entities.get_child_count() != 15:
		failures.append("bootstrap should spawn both bases with Chinese extra villager")
	else:
		var unit := entities.get_node("PlayerVillager1")
		unit.call("_ready")
		if unit.get("team") != Enums.Team.PLAYER:
			failures.append("spawned villager should belong to player")
		if unit.get("def") == null or unit.get("hp") != unit.get("def").max_hp:
			failures.append("spawned villager should initialize from its unit definition")
		if unit.position.y != 0.0 or unit.get("sim_pos").y != 0.0:
			failures.append("unit simulation should stay on y=0")

		selection.call("_add_selection", unit)
		if not unit.get_node("SelectionRing").visible:
			failures.append("selection should show the unit selection ring")

		var move_target := Vector3(5.0, 8.0, 0.0)
		selection.call("_issue_move", move_target)
		if unit.get("order") != Enums.OrderType.MOVE:
			failures.append("right-click move should issue a move order")
		var original_position: Vector3 = unit.position
		unit.call("_physics_process", 0.5)
		if unit.position.x <= original_position.x:
			failures.append("unit should move toward its target on the XZ plane")
		if unit.position.y != 0.0 or unit.get("sim_pos").y != 0.0:
			failures.append("moving unit should remain on y=0")

		var food_bush := entities.get_node_or_null("PlayerFoodBush")
		var town_center := entities.get_node_or_null("PlayerTownCenter")
		var ai_town_center := entities.get_node_or_null("AiTownCenter")
		if food_bush == null or not food_bush.has_method("extract"):
			failures.append("bootstrap should spawn gatherable food")
		elif town_center == null or not town_center.has_method("accepts_resource"):
			failures.append("bootstrap should spawn a resource drop-off TC")
		elif town_center.position != Vector3(-40.0, 0.0, -40.0):
			failures.append("player TC should spawn at the player base origin")
		elif ai_town_center == null or ai_town_center.position != Vector3(40.0, 0.0, 40.0):
			failures.append("AI TC should spawn at the opposite base origin")
		elif entities.get_node_or_null("PlayerVillager4") == null:
			failures.append("Chinese should start with four villagers")
		elif entities.get_node_or_null("AiVillager4") != null:
			failures.append("Teutons should start with three villagers")
		elif ai_town_center.get("civ").id != &"teutons":
			failures.append("AI should use the civilization opposite the player")
		elif town_center.get("def") == null or town_center.get("match_state") != scene_root.get_node("Bootstrap").get("match_state"):
			failures.append("bootstrap should configure the town center for training")
		else:
			town_center.call("_ready")
			selection.call("_issue_gather", food_bush)
			if unit.get("order") != Enums.OrderType.GATHER:
				failures.append("resource command should issue a gather order")
			selection.call("_clear_selection")
			selection.call("_add_selection", town_center)
			if hud.get_node("TrainPanel").get_child_count() != 1:
				failures.append("selecting the town center should show its train button")
			if bool(build_system.call(
				"begin_placement",
				load("res://data/buildings/house.tres")
			)):
				failures.append("building placement should require a selected villager")
			selection.call("_clear_selection")
			selection.call("_add_selection", unit)
			var state := (
				scene_root.get_node("Bootstrap").get("match_state") as MatchState
			)
			var initial_wood: int = state.get_resource(
				Enums.Team.PLAYER, Enums.ResourceType.WOOD
			)
			if not bool(build_system.call(
				"begin_placement",
				load("res://data/buildings/house.tres")
			)):
				failures.append("HUD build system should begin affordable house placement")
			else:
				var ghost := build_system.get("_ghost") as Node3D
				if ghost.is_in_group("buildings"):
					failures.append("placement preview should not be a selectable building")
				ghost.position = Vector3(8.0, 0.0, 0.0)
				if not bool(build_system.call("confirm_placement")):
					failures.append("build system should confirm a valid house placement")
				elif unit.get("order") != Enums.OrderType.BUILD:
					failures.append("placed foundation should command selected villager to build")
				elif state.get_resource(
					Enums.Team.PLAYER, Enums.ResourceType.WOOD
				) >= initial_wood:
					failures.append("confirming placement should spend building resources")
				unit.call("command_move", Vector3.ZERO)
				selection.call("_issue_build", ghost)
				if unit.get("order") != Enums.OrderType.BUILD:
					failures.append("right-clicking a foundation should resume construction")
	if hud != null and hud.get_node_or_null("TopBar/ResourcesLabel") == null:
		failures.append("HUD should display resource counters")
	if hud != null:
		var state := scene_root.get_node("Bootstrap").get("match_state") as MatchState
		state.set_winner(Enums.Team.PLAYER)
		var result_panel := hud.get_node_or_null("ResultPanel") as Control
		var result_label := hud.find_child("ResultLabel", true, false) as Label
		if result_panel == null or not result_panel.visible:
			failures.append("winner should show the result panel")
		elif result_label == null or result_label.text != "胜利":
			failures.append("player win should display victory text")
		if selection.is_processing_unhandled_input():
			failures.append("winner should stop player input orders")
		if build_system.is_processing_unhandled_input():
			failures.append("winner should stop building input")

	tree.root.remove_child(scene_root)
	scene_root.free()

	if game_session != null:
		game_session.set("player_civ_id", &"teutons")
		var teutons_match := packed.instantiate()
		tree.root.add_child(teutons_match)
		teutons_match.get_node("Bootstrap").call("_ready")
		var teutons_entities := teutons_match.get_node("Entities")
		if teutons_entities.get_node_or_null("PlayerVillager4") != null:
			failures.append("Teutons should start with three villagers")
		if teutons_entities.get_node_or_null("AiVillager4") == null:
			failures.append("Chinese AI should start with four villagers")
		var teutons_player_tc := teutons_entities.get_node_or_null("PlayerTownCenter")
		var chinese_ai_tc := teutons_entities.get_node_or_null("AiTownCenter")
		if teutons_player_tc == null or teutons_player_tc.get("civ").id != &"teutons":
			failures.append("player base should use the selected Teutons civilization")
		if chinese_ai_tc == null or chinese_ai_tc.get("civ").id != &"chinese":
			failures.append("AI should switch to Chinese when player selects Teutons")
		tree.root.remove_child(teutons_match)
		teutons_match.free()

	var picker_script := load("res://scripts/input/ground_picker.gd")
	if picker_script == null:
		failures.append("ground picker should load")
	else:
		var picked: Variant = picker_script.intersect_ground(
			Vector3(2.0, 10.0, 3.0), Vector3(0.0, -1.0, 0.0)
		)
		if picked != Vector3(2.0, 0.0, 3.0):
			failures.append("ground picker should intersect the y=0 plane")
	return failures
