extends SceneTree


func _initialize() -> void:
	var failures: Array[String] = load("res://tests/test_team_color.gd").new().run()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("TEAM COLOR TESTS PASSED")
	quit(0 if failures.is_empty() else 1)
