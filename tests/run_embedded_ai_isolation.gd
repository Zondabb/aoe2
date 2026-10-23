extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var suite = load("res://tests/test_embedded_ai_isolation.gd").new()
	root.add_child(suite)
	var result: int = await suite.run()
	suite.free()
	quit(result)
