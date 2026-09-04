extends RefCounted

const AiVsAiScene := preload("res://scenes/ai_vs_ai.tscn")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_scene_structure(failures)
	return failures


func _test_scene_structure(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := AiVsAiScene.instantiate()
	tree.root.add_child(root)
	root.get_node("Bootstrap").call("_ready")
	root.get_node("Bootstrap").call("_setup_ai_gateway")
	var gateway := root.get_node_or_null("AiGateway")
	if gateway == null:
		failures.append("ai_vs_ai scene should spawn AiGateway")
	var log_panel := root.get_node_or_null("UILayer/AiDebugLog")
	if log_panel == null:
		failures.append("ai_vs_ai scene should contain AiDebugLog panel")
	var state := root.get_node("Bootstrap").get("match_state") as MatchState
	if state == null:
		failures.append("ai_vs_ai bootstrap should expose match_state")
	elif state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) < 1:
		failures.append("ai_vs_ai should initialize team resources")
	tree.root.remove_child(root)
	root.free()
