extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = load("res://tests/test_production_queue.gd").new().run()
	failures.append_array(load("res://tests/test_command_panel.gd").new().run())
	for failure in failures:
		push_error(failure)
	print("PRODUCTION QUEUE TESTS: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
