extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures: Array[String] = load("res://tests/test_network_runtime.gd").new().run()
	for failure in failures:
		push_error(failure)
	print("NETWORK RUNTIME TESTS PASSED" if failures.is_empty() else "NETWORK RUNTIME TESTS FAILED")
	quit(0 if failures.is_empty() else 1)
