# tests/run_tests.gd
extends SceneTree

func _initialize() -> void:
	var failures: Array[String] = []
	failures.append_array(load("res://tests/test_combat_math.gd").new().run())
	failures.append_array(load("res://tests/test_civ_defs.gd").new().run())
	failures.append_array(load("res://tests/test_match_state.gd").new().run())
	failures.append_array(load("res://tests/test_match_3d.gd").new().run())
	if failures.is_empty():
		print("ALL TESTS PASSED")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("TESTS FAILED: ", failures.size())
		quit(1)
