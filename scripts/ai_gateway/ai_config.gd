class_name AiConfig
extends RefCounted

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 8765
const DEFAULT_TIMEOUT_SEC := 2.0
const ENV_AI_URL := "AOE2_AI_URL"

var service_url := ""
var timeout_sec := DEFAULT_TIMEOUT_SEC
var use_local_embedded := true
var protocol_version := 1


static func from_game_session() -> AiConfig:
	var config := AiConfig.new()
	config.service_url = String(GameSession.ai_service_url).strip_edges()
	config.timeout_sec = maxf(0.5, float(GameSession.ai_service_timeout_sec))
	config.use_local_embedded = bool(GameSession.ai_use_local_embedded)
	config.protocol_version = int(GameSession.ai_protocol_version)
	config.apply_env_override()
	config.finalize_urls()
	return config


static func default_service_url() -> String:
	return "http://%s:%d" % [DEFAULT_HOST, DEFAULT_PORT]


func apply_env_override() -> void:
	var env_url := OS.get_environment(ENV_AI_URL).strip_edges()
	if env_url.is_empty():
		return
	service_url = env_url
	use_local_embedded = false


func finalize_urls() -> void:
	if service_url.is_empty() and use_local_embedded:
		service_url = default_service_url()


func save_to_game_session() -> void:
	GameSession.ai_service_url = service_url
	GameSession.ai_service_timeout_sec = timeout_sec
	GameSession.ai_use_local_embedded = use_local_embedded
	GameSession.ai_protocol_version = protocol_version


static func from_civ_select(raw_url: String, use_embedded: bool) -> AiConfig:
	var config := AiConfig.new()
	config.service_url = raw_url.strip_edges()
	config.use_local_embedded = use_embedded
	config.timeout_sec = maxf(0.5, float(GameSession.ai_service_timeout_sec))
	config.protocol_version = int(GameSession.ai_protocol_version)
	if config.service_url.is_empty():
		config.use_local_embedded = true
	config.apply_env_override()
	config.finalize_urls()
	return config


func requires_startup_probe() -> bool:
	return not service_url.is_empty()


func requires_external_only_probe() -> bool:
	return not service_url.is_empty() and not use_local_embedded


func allows_embedded_fallback() -> bool:
	return use_local_embedded


func tick_url() -> String:
	return "%s/v1/ai/tick" % _base_url()


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
