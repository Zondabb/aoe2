extends RefCounted

const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const GameSettingsScript := preload("res://scripts/core/game_settings.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	var snap := _snapshot_ai_session()
	_test_empty_url_defaults_to_embedded(failures)
	_test_external_only_requires_probe(failures)
	_test_protocol_and_token_roundtrip(failures)
	_test_chat_url_derivation(failures)
	_test_from_game_settings(failures)
	_restore_ai_session(snap)
	return failures


func _test_empty_url_defaults_to_embedded(failures: Array[String]) -> void:
	GameSession.ai_service_url = ""
	GameSession.ai_use_local_embedded = true
	var config := AiConfigScript.from_civ_select("", true)
	if config.service_url != AiConfigScript.default_service_url():
		failures.append("empty civ_select URL should resolve to default service URL")
	if not config.use_local_embedded:
		failures.append("empty civ_select URL should keep embedded enabled")


func _test_external_only_requires_probe(failures: Array[String]) -> void:
	var config := AiConfigScript.from_civ_select("http://127.0.0.1:9999", false)
	if not config.requires_external_only_probe():
		failures.append("custom URL without embedded should require external probe")
	if config.allows_embedded_fallback():
		failures.append("external-only config should not allow embedded fallback")


func _test_protocol_and_token_roundtrip(failures: Array[String]) -> void:
	GameSession.ai_service_url = "http://127.0.0.1:8765"
	GameSession.ai_chat_url = ""
	GameSession.ai_protocol = "v2_chat"
	GameSession.ai_protocol_version = 1
	GameSession.ai_service_token = "secret-from-session"
	GameSession.ai_backend = "rules_compat"
	GameSession.ai_model = "aoe2-rules-v1"
	GameSession.ai_max_tokens = 1024
	GameSession.ai_tick_interval_sec = 0.5
	GameSession.ai_use_local_embedded = false
	GameSession.ai_use_tick_batch = true

	var config := AiConfigScript.from_game_session()
	# Skip env token if present by checking session path used api_token field.
	if config.protocol != "v2_chat":
		failures.append("from_game_session should normalize protocol to v2_chat")
	if config.protocol_version != 2:
		failures.append("v2_chat should set protocol_version=2")
	if OS.get_environment(AiConfigScript.ENV_AI_TOKEN).is_empty():
		if config.api_token != "secret-from-session":
			failures.append("from_game_session should copy api_token from GameSession")
		if config.bearer_token != config.api_token:
			failures.append("bearer_token alias should match api_token")
	if config.max_tokens != 1024:
		failures.append("from_game_session should copy max_tokens")

	config.protocol = "v1_tick"
	config.api_token = "ui-token"
	config.chat_url = "http://127.0.0.1:8765/v1/chat/completions"
	config.save_to_game_session()
	if GameSession.ai_protocol != "v1_tick":
		failures.append("save_to_game_session should write ai_protocol")
	if GameSession.ai_protocol_version != 1:
		failures.append("save_to_game_session should sync ai_protocol_version")
	if GameSession.ai_service_token != "ui-token":
		failures.append("save_to_game_session should write ai_service_token from api_token")
	if GameSession.ai_chat_url != config.chat_url:
		failures.append("save_to_game_session should write ai_chat_url")

	var with_ui_token := AiConfigScript.from_civ_select(
		"http://127.0.0.1:8765",
		false,
		"from-ui",
		true,
	)
	if with_ui_token.api_token != "from-ui":
		failures.append("from_civ_select UI token should override session/env token when non-empty")
	var clear_ui_token := AiConfigScript.from_civ_select("http://127.0.0.1:8765", false, "", true)
	if not clear_ui_token.api_token.is_empty():
		failures.append("from_civ_select empty UI token should clear api_token")


func _test_chat_url_derivation(failures: Array[String]) -> void:
	var config := AiConfigScript.new()
	config.service_url = "http://127.0.0.1:8765"
	config.chat_url = ""
	if config.chat_completions_url() != "http://127.0.0.1:8765/v1/chat/completions":
		failures.append("empty chat_url should derive from service_url")
	config.chat_url = "http://example.com/v1/chat/completions/"
	if config.chat_completions_url() != "http://example.com/v1/chat/completions":
		failures.append("explicit chat_url should strip trailing slash")
	config.service_url = "http://127.0.0.1:8765"
	if config.chat_completions_batch_url() != "http://127.0.0.1:8765/v1/chat/completions_batch":
		failures.append("batch chat URL should derive from service_url")


func _test_from_game_settings(failures: Array[String]) -> void:
	var config := AiConfigScript.from_game_settings()
	var proto := GameSettingsScript.normalize_protocol(config.protocol)
	if proto != "v1_tick" and proto != "v2_chat":
		failures.append("from_game_settings protocol invalid: %s" % config.protocol)
	if config.timeout_sec < GameSettingsScript.MIN_TIMEOUT_SEC:
		failures.append("from_game_settings timeout too small")
	if OS.get_environment(AiConfigScript.ENV_AI_TOKEN).is_empty() and not config.api_token.is_empty():
		failures.append("from_game_settings should keep empty api_token without env")


func _snapshot_ai_session() -> Dictionary:
	return {
		"ai_service_url": GameSession.ai_service_url,
		"ai_chat_url": GameSession.ai_chat_url,
		"ai_service_timeout_sec": GameSession.ai_service_timeout_sec,
		"ai_tick_interval_sec": GameSession.ai_tick_interval_sec,
		"ai_use_local_embedded": GameSession.ai_use_local_embedded,
		"ai_protocol": GameSession.ai_protocol,
		"ai_protocol_version": GameSession.ai_protocol_version,
		"ai_service_token": GameSession.ai_service_token,
		"ai_backend": GameSession.ai_backend,
		"ai_model": GameSession.ai_model,
		"ai_max_tokens": GameSession.ai_max_tokens,
		"ai_use_tick_batch": GameSession.ai_use_tick_batch,
		"ai_history_turns": GameSession.ai_history_turns,
		"ai_log_observation": GameSession.ai_log_observation,
		"ai_llm_base_url": GameSession.ai_llm_base_url,
	}


func _restore_ai_session(snap: Dictionary) -> void:
	GameSession.ai_service_url = snap["ai_service_url"]
	GameSession.ai_chat_url = snap["ai_chat_url"]
	GameSession.ai_service_timeout_sec = snap["ai_service_timeout_sec"]
	GameSession.ai_tick_interval_sec = snap["ai_tick_interval_sec"]
	GameSession.ai_use_local_embedded = snap["ai_use_local_embedded"]
	GameSession.ai_protocol = snap["ai_protocol"]
	GameSession.ai_protocol_version = snap["ai_protocol_version"]
	GameSession.ai_service_token = snap["ai_service_token"]
	GameSession.ai_backend = snap["ai_backend"]
	GameSession.ai_model = snap["ai_model"]
	GameSession.ai_max_tokens = snap["ai_max_tokens"]
	GameSession.ai_use_tick_batch = snap["ai_use_tick_batch"]
	GameSession.ai_history_turns = snap["ai_history_turns"]
	GameSession.ai_log_observation = snap["ai_log_observation"]
	GameSession.ai_llm_base_url = snap["ai_llm_base_url"]
