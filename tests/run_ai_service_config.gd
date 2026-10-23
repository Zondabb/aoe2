extends SceneTree
## Thin-client service configuration and request regression checks.

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures: Array[String] = []
	for path in ["test_ai_config.gd", "test_game_settings.gd", "test_prompt_assembler.gd"]:
		failures.append_array(load("res://tests/" + path).new().run())
	var save_service = load("res://scripts/core/save_game_service.gd")
	for field in ["ai_backend", "ai_model", "ai_max_tokens", "ai_history_turns", "ai_log_observation", "ai_llm_base_url"]:
		if field in save_service.SESSION_FIELDS:
			failures.append("old saves must not restore upstream setting: %s" % field)
	for message in failures:
		push_error(message)
	print("AI SERVICE CONFIG: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
