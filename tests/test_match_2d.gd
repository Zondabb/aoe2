# tests/test_match_2d.gd
extends RefCounted

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	var tree := Engine.get_main_loop() as SceneTree
	var game_session := tree.root.get_node_or_null("GameSession")
	if game_session == null:
		failures.append("GameSession should be configured as an autoload")
	else:
		game_session.set("player_civ_id", &"chinese")
		game_session.set("ai_civ_id", &"teutons")
	var packed := load("res://scenes/match_2d.tscn") as PackedScene
	if packed == null:
		failures.append("match scene should load")
		return failures

	var scene_root := packed.instantiate()
	tree.root.add_child(scene_root)
	scene_root.get_node("Bootstrap").call("_ready")
	# This synchronous layout/input fixture opts out; run_fog_of_war covers real scene startup.
	scene_root.get_node("Bootstrap").get("match_state").fog_enabled = false
	var ground := scene_root.get_node_or_null("Map/Ground") as Node2D
	if ground == null or ground.get_child_count() == 0:
		failures.append("match scene should contain iso grass ground tiles")
	var camera := scene_root.get_node_or_null("Camera2D") as Camera2D
	if camera == null:
		failures.append("match scene should contain camera")
	elif camera.get_script() == null:
		failures.append("match camera should have controller script")
	else:
		var expected := IsoMathScript.world_to_screen(Vector2(-40.0, -40.0))
		if not camera.position.is_equal_approx(expected):
			failures.append("camera should start focused on the player base")
		camera.call("_ready")
		var zoom_event := InputEventMouseButton.new()
		zoom_event.button_index = MOUSE_BUTTON_WHEEL_UP
		zoom_event.pressed = true
		for index in 20:
			camera.call("_unhandled_input", zoom_event)
		if not is_equal_approx(camera.zoom.x, camera.get("max_zoom")):
			failures.append("match camera zoom should clamp at maximum zoom")
		var original_position := camera.position
		camera.call("_pan", Vector2.RIGHT, 1.0)
		if camera.position == original_position:
			failures.append("match camera pan should move the camera")
	if scene_root.get_node_or_null("Entities") == null:
		failures.append("match scene should contain entities root")
	if scene_root.get_node_or_null("Bootstrap") == null:
		failures.append("match scene should contain bootstrap")
	var selection := scene_root.get_node_or_null("UILayer/SelectionController")
	if selection == null or selection.get_script() == null:
		failures.append("match scene should contain selection controller")
	else:
		selection.call("_ready")
	var build_system := scene_root.get_node_or_null("BuildSystem")
	if build_system == null or build_system.get_script() == null:
		failures.append("match scene should contain a wired build system")
	elif build_system.get("match_state") == null:
		failures.append("bootstrap should configure the build system")
	var hud := scene_root.get_node_or_null("UILayer/HUD")
	if hud == null or hud.get_script() == null:
		failures.append("match scene should contain the building HUD")
	elif hud.get("build_system") != build_system or hud.get("selection") != selection:
		failures.append("bootstrap should connect HUD building controls")
	var ui_layer := scene_root.get_node_or_null("UILayer") as CanvasLayer
	if ui_layer == null:
		failures.append("HUD/selection should live on a CanvasLayer fixed to the viewport")

	var entities := scene_root.get_node("Entities") as Node2D
	if not entities.y_sort_enabled:
		failures.append("Entities root should enable y_sort for iso depth")
	if entities.get_child_count() != 15:
		failures.append("bootstrap should spawn both bases with Chinese extra villager")
	else:
		var unit := entities.get_node("PlayerVillager1")
		unit.call("_ready")
		if unit.get("team") != Enums.Team.PLAYER:
			failures.append("spawned villager should belong to player")
		if unit.get("def") == null or unit.get("hp") != unit.get("def").max_hp:
			failures.append("spawned villager should initialize from its unit definition")
		var billboard := unit.get_node_or_null("Billboard") as AnimatedSprite2D
		var body := unit.get_node_or_null("Body") as CanvasItem
		if billboard == null or not bool(unit.get("_use_billboard")):
			failures.append("villager should bind an AnimatedSprite2D when sheet exists")
		elif body != null and body.visible:
			failures.append("placeholder body should hide when 2D sprite is bound")
		elif billboard.sprite_frames == null:
			failures.append("villager sprite should have SpriteFrames when sheet exists")
		elif not (
			billboard.sprite_frames.has_animation(&"walk_dir_0")
			or billboard.sprite_frames.has_animation(&"dir_0")
		):
			failures.append("villager sprite should have direction walk animations")
		elif unit.get_node_or_null("GroundShadow") == null:
			failures.append("villager should have a ground shadow under the sprite")

		if selection != null and billboard != null and bool(unit.get("_use_billboard")):
			var feet: Vector2 = unit.global_position
			var body_point: Vector2 = feet + Vector2(0.0, -36.0)
			var feet_hit: float = selection.call("_pick_distance", unit, feet)
			var body_hit: float = selection.call("_pick_distance", unit, body_point)
			var miss_hit: float = selection.call(
				"_pick_distance", unit, feet + Vector2(200.0, -200.0)
			)
			if not is_finite(feet_hit):
				failures.append("unit pick should hit near the feet origin")
			if not is_finite(body_hit):
				failures.append("unit pick should hit the sprite body above the feet")
			if is_finite(miss_hit):
				failures.append("unit pick should miss far outside the sprite")

		if unit.get_node("SelectionRing").visible:
			failures.append("selection ring should start hidden")
		selection.call("_add_selection", unit)
		if not unit.get_node("SelectionRing").visible:
			failures.append("selection should show the unit selection ring")

		var move_target := Vector2(5.0, 0.0)
		selection.call("_issue_move", move_target)
		if unit.get("order") != Enums.OrderType.MOVE:
			failures.append("right-click move should issue a move order")
		var move_marker := scene_root.get_node_or_null("MoveMarker") as Node2D
		if move_marker == null or not move_marker.visible:
			failures.append("move order should show a ground move marker")
		elif not move_marker.position.is_equal_approx(IsoMathScript.world_to_screen(move_target)):
			failures.append("move marker should sit on the iso screen target")
		var original_sim: Vector2 = unit.get("sim_pos")
		unit.call("_physics_process", 0.5)
		if unit.get("sim_pos").x <= original_sim.x:
			failures.append("unit should move toward its target on the logical plane")
		if not unit.position.is_equal_approx(IsoMathScript.world_to_screen(unit.get("sim_pos"))):
			failures.append("unit Node2D position should stay synced to iso screen coords")
		var stable_button := hud.find_child("StableButton", true, false) as Button
		if stable_button == null or stable_button.visible:
			failures.append("Chinese HUD should hide the stable build button")
		for drop_button_name in ["MillButton", "LumberButton", "MiningButton"]:
			if hud.find_child(drop_button_name, true, false) == null:
				failures.append("HUD should expose %s for drop-off buildings" % drop_button_name)
		if ground.get_child_count() < 10:
			failures.append("match ground should spawn grass tiles covering the play area")
		var player_billboard := unit.get_node_or_null("Billboard") as AnimatedSprite2D
		var ai_villager := entities.get_node_or_null("AiVillager1") as Node2D
		if ai_villager != null:
			ai_villager.call("_ready")
		var ai_billboard := (
			ai_villager.get_node_or_null("Billboard") as AnimatedSprite2D
			if ai_villager != null
			else null
		)
		if player_billboard == null or ai_billboard == null:
			failures.append("units should expose Billboard nodes for player-color checks")
		elif not bool(unit.get("_use_billboard")) or not bool(ai_villager.get("_use_billboard")):
			failures.append("both teams should bind 2D sprites for player-color checks")
		elif not player_billboard.material is ShaderMaterial or not ai_billboard.material is ShaderMaterial:
			failures.append("both teams should bind indexed player-color shader materials")
		elif (
			int(player_billboard.material.get_shader_parameter("target_player")) != 1
			or int(ai_billboard.material.get_shader_parameter("target_player")) != 2
		):
			failures.append("player and AI sprites should use blue/red palette rows")
		elif player_billboard.modulate != Color.WHITE or ai_billboard.modulate != Color.WHITE:
			failures.append("player colors should preserve untinted non-player pixels")

		var food_bush := entities.get_node_or_null("PlayerFoodBush")
		var town_center := entities.get_node_or_null("PlayerTownCenter")
		var ai_town_center := entities.get_node_or_null("AiTownCenter")
		if food_bush == null or not food_bush.has_method("extract"):
			failures.append("bootstrap should spawn gatherable food")
		elif town_center == null or not town_center.has_method("accepts_resource"):
			failures.append("bootstrap should spawn a resource drop-off TC")
		elif town_center.get("sim_pos") != Vector2(-40.0, -40.0):
			failures.append("player TC should spawn at the player base origin")
		elif ai_town_center == null or ai_town_center.get("sim_pos") != Vector2(40.0, 40.0):
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
			var tc_billboard := town_center.get_node_or_null("Billboard") as Sprite2D
			if selection != null and tc_billboard != null and tc_billboard.visible:
				var tc_feet: Vector2 = town_center.global_position
				var tc_body: Vector2 = tc_feet + Vector2(0.0, -48.0)
				var tc_feet_hit: float = selection.call("_pick_distance", town_center, tc_feet)
				var tc_body_hit: float = selection.call(
					"_pick_distance", town_center, tc_body
				)
				var tc_miss: float = selection.call(
					"_pick_distance", town_center, tc_feet + Vector2(260.0, -260.0)
				)
				if not is_finite(tc_feet_hit):
					failures.append("building pick should hit near the footprint origin")
				if not is_finite(tc_body_hit):
					failures.append("building pick should hit the sprite body above the base")
				if is_finite(tc_miss):
					failures.append("building pick should miss far outside the sprite")
			selection.call("_issue_gather", food_bush)
			if unit.get("order") != Enums.OrderType.GATHER:
				failures.append("resource command should issue a gather order")
			selection.call("_clear_selection")
			selection.call("_add_selection", food_bush)
			var bush_ring := food_bush.get_node_or_null("SelectionRing") as CanvasItem
			if bush_ring == null or not bush_ring.visible:
				failures.append("resource selection should show a footprint outline")
			selection.call("_clear_selection")
			selection.call("_add_selection", town_center)
			var tc_ring := town_center.get_node_or_null("SelectionRing") as CanvasItem
			if tc_ring == null or not tc_ring.visible:
				failures.append("building selection should show a footprint outline")
			elif not tc_ring is Line2D:
				failures.append("building selection should show a white footprint box (Line2D)")
			var train_button := hud.get_node("%CommandGrid").get_child(0) as BaseButton
			if train_button == null or train_button.get_meta("command_id", "") != "train_villager":
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
				var ghost := build_system.get("_ghost") as Node2D
				if ghost.is_in_group("buildings"):
					failures.append("placement preview should not be a selectable building")
				ghost.set("sim_pos", Vector2(8.0, 0.0))
				IsoMathScript.sync_node(ghost, Vector2(8.0, 0.0))
				if not bool(build_system.call("confirm_placement")):
					failures.append("build system should confirm a valid house placement")
				elif unit.get("order") != Enums.OrderType.BUILD:
					failures.append("placed foundation should command selected villager to build")
				elif state.get_resource(
					Enums.Team.PLAYER, Enums.ResourceType.WOOD
				) >= initial_wood:
					failures.append("confirming placement should spend building resources")
				unit.call("command_move", Vector2.ZERO)
				selection.call("_issue_build", ghost)
				if unit.get("order") != Enums.OrderType.BUILD:
					failures.append("right-clicking a foundation should resume construction")
	if hud != null and hud.get_node_or_null("%ResourcesLabel") == null:
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
		if not bool(state.get("frozen")):
			failures.append("winner should set MatchState.frozen")
		var player_unit := entities.get_node_or_null("PlayerVillager1") as Node2D
		if player_unit != null:
			if player_unit.is_physics_processing():
				failures.append("winner should disable player unit physics_process")
			var start_sim: Vector2 = player_unit.get("sim_pos")
			player_unit.call("command_move", start_sim + Vector2(6.0, 0.0))
			player_unit.call("_physics_process", 0.5)
			if player_unit.get("sim_pos").distance_to(start_sim) > 0.01:
				failures.append("frozen MatchState should stop player unit movement")

	tree.root.remove_child(scene_root)
	scene_root.free()

	if game_session != null:
		game_session.set("player_civ_id", &"teutons")
		game_session.set("ai_civ_id", &"chinese")
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
			failures.append("AI should use independently selected Chinese civilization")
		var teutons_hud := teutons_match.get_node_or_null("UILayer/HUD")
		var teutons_stable := (
			teutons_hud.find_child("StableButton", true, false) as Button
			if teutons_hud != null
			else null
		)
		if teutons_stable == null or not teutons_stable.visible:
			failures.append("Teutons HUD should show the stable build button")
		tree.root.remove_child(teutons_match)
		teutons_match.free()

	if not IsoMathScript.world_to_screen(Vector2(1, 0)).is_equal_approx(Vector2(22, 11)):
		failures.append("IsoMath world_to_screen should use 2:1 diamond mapping")
	if not IsoMathScript.screen_to_world(Vector2(22, 11)).is_equal_approx(Vector2(1, 0)):
		failures.append("IsoMath screen_to_world should invert world_to_screen")
	return failures
