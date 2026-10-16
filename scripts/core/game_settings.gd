class_name GameSettings
extends RefCounted

## Packaged defaults. Optional override: user://game_settings.cfg
## Multiplayer also supports game_settings.cfg beside the desktop executable.
const RES_PATH := "res://data/game_settings.cfg"
const USER_PATH := "user://game_settings.cfg"
const DEFAULT_MULTIPLAYER := {"host": "127.0.0.1", "port": 8001, "use_tls": false}

const DEFAULT_SPEED := 1.0
const MIN_SPEED := 0.1
const MAX_SPEED := 8.0

const ENV_AI_URL := "AOE2_AI_URL"
const ENV_AI_TOKEN := "AOE2_AI_TOKEN"

const DEFAULT_AI := {
	"service_url": "",
	"chat_url": "",
	"api_token": "",
	"backend": "rules_compat",
	"model": "aoe2-rules-v1",
	"timeout_sec": 2.0,
	"tick_interval_sec": 0.5,
	"protocol": "v1_tick",
	"use_local_embedded": true,
	"max_tokens": 2048,
	"history_turns": 0,
	"log_observation": false,
	"llm_base_url": "",
	"multi_agent_enabled": true,
	"fast_tick_interval_sec": 1.0,
	"fast_timeout_sec": 3.0,
}

const MIN_TIMEOUT_SEC := 0.5
const MAX_TIMEOUT_SEC := 120.0
const MIN_TICK_INTERVAL_SEC := 0.05
const MAX_TICK_INTERVAL_SEC := 10.0
const MIN_MAX_TOKENS := 1
const MAX_MAX_TOKENS := 32768
const MIN_HISTORY_TURNS := 0
const MAX_HISTORY_TURNS := 16

static var last_loaded_speed := DEFAULT_SPEED
static var last_loaded_ai: Dictionary = DEFAULT_AI.duplicate(true)
static var last_loaded_multiplayer: Dictionary = DEFAULT_MULTIPLAYER.duplicate(true)


static func clamp_speed(speed: float) -> float:
	return clampf(speed, MIN_SPEED, MAX_SPEED)


static func normalize_protocol(raw: String) -> String:
	var p := raw.strip_edges().to_lower()
	if p in ["v3_multi_agent", "v3", "3"]:
		return "v3_multi_agent"
	if p == "v2_chat" or p == "v2" or p == "2" or p == "chat":
		return "v2_chat"
	return "v1_tick"


static func protocol_to_version(protocol: String) -> int:
	if normalize_protocol(protocol) == "v3_multi_agent":
		return 3
	return 2 if normalize_protocol(protocol) == "v2_chat" else 1


static func version_to_protocol(version: int) -> String:
	if version >= 3:
		return "v3_multi_agent"
	return "v2_chat" if version >= 2 else "v1_tick"


## Read [game] speed from user override (if present) else res:// defaults.
static func load_speed() -> float:
	var cfg := _load_config_file()
	if cfg == null:
		last_loaded_speed = DEFAULT_SPEED
		return last_loaded_speed
	last_loaded_speed = clamp_speed(float(cfg.get_value("game", "speed", DEFAULT_SPEED)))
	return last_loaded_speed


## Read [ai] settings: user:// → res:// → env (AOE2_AI_URL / AOE2_AI_TOKEN).
static func load_ai_settings() -> Dictionary:
	var out: Dictionary = DEFAULT_AI.duplicate(true)
	var cfg := _load_config_file()
	if cfg != null:
		out["service_url"] = String(cfg.get_value("ai", "service_url", out["service_url"])).strip_edges()
		out["chat_url"] = String(cfg.get_value("ai", "chat_url", out["chat_url"])).strip_edges()
		out["api_token"] = String(cfg.get_value("ai", "api_token", out["api_token"])).strip_edges()
		out["backend"] = String(cfg.get_value("ai", "backend", out["backend"])).strip_edges()
		out["model"] = String(cfg.get_value("ai", "model", out["model"])).strip_edges()
		out["timeout_sec"] = clampf(
			float(cfg.get_value("ai", "timeout_sec", out["timeout_sec"])),
			MIN_TIMEOUT_SEC,
			MAX_TIMEOUT_SEC,
		)
		out["tick_interval_sec"] = clampf(
			float(cfg.get_value("ai", "tick_interval_sec", out["tick_interval_sec"])),
			MIN_TICK_INTERVAL_SEC,
			MAX_TICK_INTERVAL_SEC,
		)
		out["protocol"] = normalize_protocol(String(cfg.get_value("ai", "protocol", out["protocol"])))
		out["use_local_embedded"] = bool(cfg.get_value("ai", "use_local_embedded", out["use_local_embedded"]))
		out["max_tokens"] = clampi(
			int(cfg.get_value("ai", "max_tokens", out["max_tokens"])),
			MIN_MAX_TOKENS,
			MAX_MAX_TOKENS,
		)
		out["history_turns"] = clampi(
			int(cfg.get_value("ai", "history_turns", out["history_turns"])),
			MIN_HISTORY_TURNS,
			MAX_HISTORY_TURNS,
		)
		out["log_observation"] = bool(cfg.get_value("ai", "log_observation", out["log_observation"]))
		out["llm_base_url"] = String(cfg.get_value("ai", "llm_base_url", out["llm_base_url"])).strip_edges()
		out["multi_agent_enabled"] = bool(cfg.get_value("ai", "multi_agent_enabled", out["multi_agent_enabled"]))
		out["fast_tick_interval_sec"] = clampf(float(cfg.get_value("ai", "fast_tick_interval_sec", out["fast_tick_interval_sec"])), 0.25, 5.0)
		out["fast_timeout_sec"] = clampf(float(cfg.get_value("ai", "fast_timeout_sec", out["fast_timeout_sec"])), 0.5, 10.0)
	_apply_ai_env_override(out)
	if String(out.get("backend", "")).is_empty():
		out["backend"] = DEFAULT_AI["backend"]
	if String(out.get("model", "")).is_empty():
		out["model"] = DEFAULT_AI["model"]
	out["protocol"] = normalize_protocol(String(out.get("protocol", "v1_tick")))
	last_loaded_ai = out.duplicate(true)
	return out


## Write loaded AI settings into GameSession (does not re-apply env beyond load_ai_settings).
static func apply_ai_to_game_session() -> Dictionary:
	var ai := load_ai_settings()
	GameSession.ai_service_url = String(ai["service_url"])
	GameSession.ai_chat_url = String(ai["chat_url"])
	GameSession.ai_service_token = String(ai["api_token"])
	GameSession.ai_backend = String(ai["backend"])
	GameSession.ai_model = String(ai["model"])
	GameSession.ai_service_timeout_sec = float(ai["timeout_sec"])
	GameSession.ai_tick_interval_sec = float(ai["tick_interval_sec"])
	GameSession.ai_protocol = String(ai["protocol"])
	GameSession.ai_protocol_version = protocol_to_version(String(ai["protocol"]))
	GameSession.ai_use_local_embedded = bool(ai["use_local_embedded"])
	GameSession.ai_max_tokens = int(ai["max_tokens"])
	GameSession.ai_history_turns = int(ai["history_turns"])
	GameSession.ai_log_observation = bool(ai["log_observation"])
	GameSession.ai_llm_base_url = String(ai["llm_base_url"])
	GameSession.ai_multi_agent_enabled = bool(ai["multi_agent_enabled"])
	GameSession.ai_fast_tick_interval_sec = float(ai["fast_tick_interval_sec"])
	GameSession.ai_fast_timeout_sec = float(ai["fast_timeout_sec"])
	return ai


## Apply speed, AI and multiplayer connection settings at startup.
static func apply_from_config() -> float:
	var speed := load_speed()
	Engine.time_scale = speed
	apply_ai_to_game_session()
	apply_multiplayer_to_game_session()
	return speed


## Merge [multiplayer] per key: packaged defaults < beside desktop executable < user override.
## Explicit paths allow verification without changing the player's config file.
static func load_multiplayer_settings(default_path: String = RES_PATH, user_path: String = USER_PATH, external_path: String = "") -> Dictionary:
	var out: Dictionary = DEFAULT_MULTIPLAYER.duplicate(true)
	if external_path.is_empty() and not OS.has_feature("editor") and not OS.has_feature("web"):
		external_path = OS.get_executable_path().get_base_dir().path_join("game_settings.cfg")
	for path in [default_path, external_path, user_path]:
		if path.is_empty() or not FileAccess.file_exists(path):
			continue
		var cfg := ConfigFile.new()
		var error := cfg.load(path)
		if error != OK:
			push_warning("GameSettings: could not load multiplayer config %s (%s)" % [path, error_string(error)])
			continue
		for key in DEFAULT_MULTIPLAYER:
			if cfg.has_section_key("multiplayer", key):
				out[key] = cfg.get_value("multiplayer", key)
	out = normalize_multiplayer_settings(out)
	last_loaded_multiplayer = out.duplicate(true)
	return out


static func normalize_multiplayer_settings(settings: Dictionary) -> Dictionary:
	var host := str(settings.get("host", DEFAULT_MULTIPLAYER.host)).strip_edges()
	if host.begins_with("[") and host.ends_with("]"):
		host = host.substr(1, host.length() - 2)
	# Host is a bare IP/domain; URL paths and credentials belong to neither field.
	var valid := not host.is_empty()
	for forbidden in ["/", "\\", "@", "?", "#", " ", "\t", "\r", "\n", "[", "]"]:
		valid = valid and not host.contains(forbidden)
	if host.contains(":") and not host.is_valid_ip_address():
		valid = false
	if not valid:
		push_warning("GameSettings: multiplayer.host must be an IP or domain; using 127.0.0.1")
		host = DEFAULT_MULTIPLAYER.host
	var raw_port: Variant = settings.get("port", DEFAULT_MULTIPLAYER.port)
	var port := DEFAULT_MULTIPLAYER.port
	if (raw_port is int or (raw_port is String and raw_port.is_valid_int())) and int(raw_port) >= 1 and int(raw_port) <= 65535:
		port = int(raw_port)
	else:
		push_warning("GameSettings: multiplayer.port must be 1..65535; using 8001")
	var raw_tls: Variant = settings.get("use_tls", false)
	return {"host": host, "port": port, "use_tls": raw_tls if raw_tls is bool else false}


static func multiplayer_server_url(settings: Dictionary) -> String:
	var normalized := normalize_multiplayer_settings(settings)
	var host: String = normalized.host
	if host.contains(":"):
		host = "[%s]" % host
	return "%s://%s:%d/ws" % ["wss" if normalized.use_tls else "ws", host, normalized.port]


static func apply_multiplayer_to_game_session() -> Dictionary:
	var multiplayer := load_multiplayer_settings()
	GameSession.online_server_url = multiplayer_server_url(multiplayer)
	return multiplayer


static func _load_config_file() -> ConfigFile:
	var cfg := ConfigFile.new()
	var err := cfg.load(USER_PATH)
	var source := USER_PATH
	if err != OK:
		err = cfg.load(RES_PATH)
		source = RES_PATH
	if err != OK:
		push_warning(
			"GameSettings: failed to load %s (error %s). Quote all strings, e.g. protocol=\"v2_chat\" and service_url=\"http://127.0.0.1:8765\"."
			% [source, err]
		)
		return null
	return cfg


static func _apply_ai_env_override(ai: Dictionary) -> void:
	var env_url := OS.get_environment(ENV_AI_URL).strip_edges()
	if not env_url.is_empty():
		ai["service_url"] = env_url
		ai["use_local_embedded"] = false
	var env_token := OS.get_environment(ENV_AI_TOKEN).strip_edges()
	if not env_token.is_empty():
		ai["api_token"] = env_token
	var env_llm := OS.get_environment("AOE2_LLM_BASE_URL").strip_edges()
	if not env_llm.is_empty():
		ai["llm_base_url"] = env_llm
	var env_backend := OS.get_environment("AOE2_AI_BACKEND").strip_edges()
	if not env_backend.is_empty():
		ai["backend"] = env_backend
