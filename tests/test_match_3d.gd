# tests/test_match_3d.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var packed := load("res://scenes/match_3d.tscn") as PackedScene
	if packed == null:
		failures.append("match scene should load")
		return failures

	var scene_root := packed.instantiate()
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

	scene_root.free()

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
