class_name AiConfig
extends RefCounted

const GameSettingsScript := preload("res://scripts/core/game_settings.gd")

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8765
const DEFAULT_TIMEOUT_SEC := 2.0
const DEFAULT_TICK_INTERVAL_SEC := 0.5
const DEFAULT_MAX_TOKENS := 2048
const DEFAULT_BACKEND := "rules_compat"
const DEFAULT_MODEL := "aoe2-rules-v1"
## Required by the chat envelope only. The Python service selects the real model.
const SERVICE_MODEL := "aoe2-service"
const PROTOCOL_V1_TICK := "v1_tick"
const PROTOCOL_V2_CHAT := "v2_chat"
const PROTOCOL_V3_MULTI_AGENT := "v3_multi_agent"
const ENV_AI_URL := "AOE2_AI_URL"
const ENV_AI_TOKEN := "AOE2_AI_TOKEN"

var service_url := ""
var chat_url := ""
var timeout_sec := DEFAULT_TIMEOUT_SEC
var tick_interval_sec := DEFAULT_TICK_INTERVAL_SEC
var use_local_embedded := true
## v1_tick | v2_chat | v3_multi_agent; multi_agent_enabled upgrades external v2.
var protocol := PROTOCOL_V1_TICK
## Derived from protocol for v1 tick payloads.
var protocol_version := 1
## Python AI service access token (cfg: api_token), never a model provider key.
var api_token := ""
## Legacy programmatic compatibility; neither cfg/session loading nor HTTP uses these.
var backend := DEFAULT_BACKEND
var model := DEFAULT_MODEL
var max_tokens := DEFAULT_MAX_TOKENS
var use_tick_batch := true
var history_turns := 0
var log_observation := false
var llm_base_url := ""
## Explicit in-memory legacy configurations remain legacy unless enabled.
var multi_agent_enabled := false
var fast_tick_interval_sec := 1.0
var fast_timeout_sec := 3.0

## Alias for older call sites / docs that used bearer_token.
var bearer_token: String:
	get:
		return api_token
	set(value):
		api_token = value


static func from_game_session() -> AiConfig:
	var config := AiConfig.new()
	config.service_url = String(GameSession.ai_service_url).strip_edges()
	config.chat_url = String(GameSession.ai_chat_url).strip_edges()
	config.timeout_sec = maxf(0.5, float(GameSession.ai_service_timeout_sec))
	config.tick_interval_sec = clampf(
		float(GameSession.ai_tick_interval_sec),
		GameSettingsScript.MIN_TICK_INTERVAL_SEC,
		GameSettingsScript.MAX_TICK_INTERVAL_SEC,
	)
	config.use_local_embedded = bool(GameSession.ai_use_local_embedded)
	config.protocol = GameSettingsScript.normalize_protocol(String(GameSession.ai_protocol))
	if config.protocol == PROTOCOL_V1_TICK and int(GameSession.ai_protocol_version) >= 2:
		config.protocol = GameSettingsScript.version_to_protocol(int(GameSession.ai_protocol_version))
	config.protocol_version = GameSettingsScript.protocol_to_version(config.protocol)
	config.api_token = String(GameSession.ai_service_token).strip_edges()
	config.use_tick_batch = bool(GameSession.ai_use_tick_batch)
	config.multi_agent_enabled = bool(GameSession.ai_multi_agent_enabled)
	config.fast_tick_interval_sec = float(GameSession.ai_fast_tick_interval_sec)
	config.fast_timeout_sec = float(GameSession.ai_fast_timeout_sec)
	config.apply_env_override()
	config.finalize_urls()
	return config


## Build from GameSettings load (cfg + env), without requiring prior GameSession write.
static func from_game_settings() -> AiConfig:
	var ai: Dictionary = GameSettingsScript.load_ai_settings()
	var config := AiConfig.new()
	config.service_url = String(ai.get("service_url", "")).strip_edges()
	config.chat_url = String(ai.get("chat_url", "")).strip_edges()
	config.timeout_sec = maxf(0.5, float(ai.get("timeout_sec", DEFAULT_TIMEOUT_SEC)))
	config.tick_interval_sec = clampf(
		float(ai.get("tick_interval_sec", DEFAULT_TICK_INTERVAL_SEC)),
		GameSettingsScript.MIN_TICK_INTERVAL_SEC,
		GameSettingsScript.MAX_TICK_INTERVAL_SEC,
	)
	config.use_local_embedded = bool(ai.get("use_local_embedded", true))
	config.protocol = GameSettingsScript.normalize_protocol(String(ai.get("protocol", PROTOCOL_V1_TICK)))
	config.protocol_version = GameSettingsScript.protocol_to_version(config.protocol)
	config.api_token = String(ai.get("api_token", "")).strip_edges()
	config.multi_agent_enabled = bool(ai.get("multi_agent_enabled", true))
	config.fast_tick_interval_sec = float(ai.get("fast_tick_interval_sec", 1.0))
	config.fast_timeout_sec = float(ai.get("fast_timeout_sec", 3.0))
	config.finalize_urls()
	return config


static func default_service_url() -> String:
	return "http://%s:%d" % [DEFAULT_HOST, DEFAULT_PORT]


func apply_env_override() -> void:
	var env_url := OS.get_environment(ENV_AI_URL).strip_edges()
	if not env_url.is_empty():
		service_url = env_url
		use_local_embedded = false
	var env_token := OS.get_environment(ENV_AI_TOKEN).strip_edges()
	if not env_token.is_empty():
		api_token = env_token


func finalize_urls() -> void:
	if service_url.is_empty() and use_local_embedded:
		service_url = default_service_url()
	protocol = GameSettingsScript.normalize_protocol(protocol)
	protocol_version = GameSettingsScript.protocol_to_version(protocol)


func save_to_game_session() -> void:
	GameSession.ai_service_url = service_url
	GameSession.ai_chat_url = chat_url
	GameSession.ai_service_timeout_sec = timeout_sec
	GameSession.ai_tick_interval_sec = tick_interval_sec
	GameSession.ai_use_local_embedded = use_local_embedded
	GameSession.ai_protocol = GameSettingsScript.normalize_protocol(protocol)
	GameSession.ai_protocol_version = GameSettingsScript.protocol_to_version(GameSession.ai_protocol)
	GameSession.ai_service_token = api_token
	GameSession.ai_use_tick_batch = use_tick_batch
	GameSession.ai_multi_agent_enabled = multi_agent_enabled
	GameSession.ai_fast_tick_interval_sec = fast_tick_interval_sec
	GameSession.ai_fast_timeout_sec = fast_timeout_sec


static func from_civ_select(
	raw_url: String,
	use_embedded: bool,
	raw_token: String = "",
	token_from_ui: bool = false,
) -> AiConfig:
	var config := AiConfig.new()
	config.service_url = raw_url.strip_edges()
	config.use_local_embedded = use_embedded
	config.timeout_sec = maxf(0.5, float(GameSession.ai_service_timeout_sec))
	config.tick_interval_sec = clampf(
		float(GameSession.ai_tick_interval_sec),
		GameSettingsScript.MIN_TICK_INTERVAL_SEC,
		GameSettingsScript.MAX_TICK_INTERVAL_SEC,
	)
	config.chat_url = String(GameSession.ai_chat_url).strip_edges()
	config.protocol = GameSettingsScript.normalize_protocol(String(GameSession.ai_protocol))
	config.protocol_version = GameSettingsScript.protocol_to_version(config.protocol)
	config.api_token = String(GameSession.ai_service_token).strip_edges()
	config.use_tick_batch = bool(GameSession.ai_use_tick_batch)
	config.multi_agent_enabled = bool(GameSession.ai_multi_agent_enabled)
	config.fast_tick_interval_sec = float(GameSession.ai_fast_tick_interval_sec)
	config.fast_timeout_sec = float(GameSession.ai_fast_timeout_sec)
	if config.service_url.is_empty():
		config.use_local_embedded = true
	config.apply_env_override()
	if token_from_ui:
		# Civ-select UI is authoritative (including empty = clear token for this match).
		config.api_token = raw_token.strip_edges()
	elif not raw_token.strip_edges().is_empty():
		config.api_token = raw_token.strip_edges()
	config.finalize_urls()
	return config


func requires_startup_probe() -> bool:
	return not service_url.is_empty()


func requires_external_only_probe() -> bool:
	return not service_url.is_empty() and not use_local_embedded


func allows_embedded_fallback() -> bool:
	return use_local_embedded


func uses_chat_protocol() -> bool:
	return protocol == PROTOCOL_V2_CHAT


func uses_multi_agent_protocol() -> bool:
	# Explicit v1 clients retain their tick schema; v2/v3 need no provider knowledge.
	return not use_local_embedded and (protocol == PROTOCOL_V3_MULTI_AGENT or (multi_agent_enabled and protocol == PROTOCOL_V2_CHAT))


func multi_agent_tick_url() -> String:
	return "%s/v3/ai/tick" % _base_url()


func tick_url() -> String:
	return "%s/v1/ai/tick" % _base_url()


func tick_batch_url() -> String:
	return "%s/v1/ai/tick_batch" % _base_url()


func uses_openai_backend() -> bool:
	var name := backend.strip_edges().to_lower()
	return name in ["openai", "llm", "openai_compat"]


func chat_completions_batch_url() -> String:
	return "%s/v1/chat/completions_batch" % _base_url()


func chat_completions_url() -> String:
	var explicit := chat_url.strip_edges()
	if not explicit.is_empty():
		if explicit.ends_with("/"):
			return explicit.substr(0, explicit.length() - 1)
		return explicit
	return "%s/v1/chat/completions" % _base_url()


func match_start_url() -> String:
	return "%s/v1/ai/match/start" % _base_url()


func match_end_url() -> String:
	return "%s/v1/ai/match/end" % _base_url()


func health_url() -> String:
	return "%s/health" % _base_url()


func display_url() -> String:
	if service_url.is_empty():
		return default_service_url()
	return service_url


func _base_url() -> String:
	var url := service_url.strip_edges()
	if url.is_empty():
		url = default_service_url()
	if url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url
