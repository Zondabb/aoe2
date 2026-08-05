# tests/test_match_3d.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/match_3d.tscn") as PackedScene
	if packed == null:
		failures.append("match scene should load")
		return failures

	var scene_root := packed.instantiate()
	(Engine.get_main_loop() as SceneTree).root.add_child(scene_root)
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

	var entities := scene_root.get_node("Entities")
	if entities.get_child_count() != 5:
		failures.append("bootstrap should spawn a villager, TC, and three resources")
	else:
		var unit := entities.get_node("PlayerVillager")
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

		var food_bush := entities.get_node_or_null("FoodBush")
		var town_center := entities.get_node_or_null("TownCenter")
		if food_bush == null or not food_bush.has_method("extract"):
			failures.append("bootstrap should spawn gatherable food")
		elif town_center == null or not town_center.has_method("accepts_resource"):
			failures.append("bootstrap should spawn a resource drop-off TC")
		else:
			selection.call("_issue_gather", food_bush)
			if unit.get("order") != Enums.OrderType.GATHER:
				failures.append("resource command should issue a gather order")
	if scene_root.get_node_or_null("ResourceLabel") == null:
		failures.append("match should display resource counters")

	scene_root.queue_free()

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
