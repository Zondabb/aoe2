extends RefCounted

const GameSettingsScript := preload("res://scripts/core/game_settings.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	var previous := Engine.time_scale
	var previous_multiplayer_url: String = GameSession.online_server_url
	var snap := _snapshot_ai_session()

	if not is_equal_approx(GameSettingsScript.clamp_speed(0.01), GameSettingsScript.MIN_SPEED):
		failures.append("speed below min should clamp to MIN_SPEED")
	if not is_equal_approx(GameSettingsScript.clamp_speed(99.0), GameSettingsScript.MAX_SPEED):
		failures.append("speed above max should clamp to MAX_SPEED")

	var loaded := GameSettingsScript.load_speed()
	if loaded < GameSettingsScript.MIN_SPEED or loaded > GameSettingsScript.MAX_SPEED:
		failures.append("load_speed should stay within clamp bounds, got %s" % loaded)

	var applied := GameSettingsScript.apply_from_config()
	if not is_equal_approx(Engine.time_scale, applied):
		failures.append("apply_from_config should set Engine.time_scale")
	if not is_equal_approx(applied, loaded):
		failures.append("apply_from_config should use load_speed result")

	# Packaged default file should exist and be readable.
	var cfg := ConfigFile.new()
	if cfg.load(GameSettingsScript.RES_PATH) != OK:
		failures.append("res://data/game_settings.cfg should exist")
	else:
		var file_speed := float(cfg.get_value("game", "speed", -1.0))
		if file_speed <= 0.0:
			failures.append("game_settings.cfg should define a positive [game] speed")
		if not cfg.has_section("ai"):
			failures.append("game_settings.cfg should define [ai] section")
		else:
			var token := String(cfg.get_value("ai", "api_token", "MISSING"))
			if token != "":
				failures.append("packaged api_token should be empty (no secrets in res://)")
			var protocol := String(cfg.get_value("ai", "protocol", ""))
			if GameSettingsScript.normalize_protocol(protocol) not in ["v1_tick", "v2_chat"]:
				failures.append("packaged protocol should normalize to v1_tick or v2_chat")
			if String(cfg.get_value("ai", "backend", "")).is_empty():
				failures.append("packaged backend should parse as a non-empty string")
			if String(cfg.get_value("ai", "model", "")).is_empty():
				failures.append("packaged model should parse as a non-empty string")

	var ai := GameSettingsScript.load_ai_settings()
	for key in GameSettingsScript.DEFAULT_AI.keys():
		if not ai.has(key):
			failures.append("load_ai_settings missing key: %s" % key)
	if String(ai.get("api_token", "x")) != "" and OS.get_environment("AOE2_AI_TOKEN").is_empty():
		# Empty packaged token unless env overrides.
		failures.append("load_ai_settings api_token should be empty without AOE2_AI_TOKEN")
	if float(ai.get("timeout_sec", 0.0)) < GameSettingsScript.MIN_TIMEOUT_SEC:
		failures.append("timeout_sec should clamp to >= MIN_TIMEOUT_SEC")
	if float(ai.get("tick_interval_sec", 0.0)) < GameSettingsScript.MIN_TICK_INTERVAL_SEC:
		failures.append("tick_interval_sec should clamp to >= MIN_TICK_INTERVAL_SEC")
	if int(ai.get("max_tokens", 0)) < GameSettingsScript.MIN_MAX_TOKENS:
		failures.append("max_tokens should clamp to >= MIN_MAX_TOKENS")
	var proto := GameSettingsScript.normalize_protocol(String(ai.get("protocol", "")))
	if proto != "v1_tick" and proto != "v2_chat":
		failures.append("protocol should be v1_tick or v2_chat, got %s" % proto)
	if GameSettingsScript.protocol_to_version("v2_chat") != 2:
		failures.append("v2_chat should map to protocol version 2")
	if GameSettingsScript.protocol_to_version("v1_tick") != 1:
		failures.append("v1_tick should map to protocol version 1")

	GameSettingsScript.apply_ai_to_game_session()
	if GameSession.ai_protocol != proto:
		failures.append("apply_ai_to_game_session should set GameSession.ai_protocol")
	if GameSession.ai_protocol_version != GameSettingsScript.protocol_to_version(proto):
		failures.append("apply_ai_to_game_session should sync ai_protocol_version")

	_restore_ai_session(snap)
	GameSession.online_server_url = previous_multiplayer_url
	Engine.time_scale = previous
	return failures


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
