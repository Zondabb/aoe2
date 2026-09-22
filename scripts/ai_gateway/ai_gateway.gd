class_name AiGateway
extends Node

const DEFAULT_TICK_INTERVAL := 0.5

const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")
const EventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const CommandExecutorScript := preload("res://scripts/ai_gateway/command_executor.gd")
const CommandExecutionContextScript := preload(
	"res://scripts/ai_gateway/command_execution_context.gd"
)
const HttpAiClientScript := preload("res://scripts/ai_gateway/http_ai_client.gd")
const LocalAiServerScript := preload("res://scripts/ai_gateway/local_ai_server.gd")
const AiServiceAdapterScript := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiGatewayMetricsScript := preload("res://scripts/ai_gateway/ai_gateway_metrics.gd")
const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")
const CivAiProfileScript := preload("res://scripts/data/civ_ai_profile.gd")
const PromptAssemblerScript := preload("res://scripts/ai_gateway/prompt_assembler.gd")
const LlmResponseParserScript := preload("res://scripts/ai_gateway/llm_response_parser.gd")

var match_state: MatchState
var entities: Node2D
var config: AiConfig
var decision_log: AiDecisionLog
var metrics
var match_id := ""
var match_time := 0.0
var tick := 0
var enabled := true
var last_tick_latency_ms := -1.0
var service_status := "starting"

var _teams: Array[Dictionary] = []
var _exec_contexts: Dictionary = {}
var _tick_accum := 0.0
var _http_client: HttpAiClient
var _local_server: LocalAiServer
var _adapter: AiServiceAdapter
var _pending_responses: Array[Dictionary] = []
var _request_in_flight := false
var _chat_histories: Dictionary = {}


func setup(
	state: MatchState,
	entities_root: Node2D,
	teams: Array,
	gateway_config: AiConfig = null,
	shared_log: AiDecisionLog = null
) -> void:
	match_state = state
	entities = entities_root
	config = gateway_config if gateway_config != null else AiConfigScript.from_game_session()
	decision_log = shared_log if shared_log != null else AiDecisionLogScript.new()
	metrics = AiGatewayMetricsScript.new()
	_teams.clear()
	for team_entry in teams:
		if team_entry is Dictionary:
			_teams.append(team_entry)
	_init_runtime()
	set_process(true)


func stop() -> void:
	enabled = false
	service_status = "stopped"
	set_process(false)
	if _http_client != null and is_instance_valid(_http_client):
		_http_client.cancel_requests()
	if _local_server != null and _local_server.is_running():
		_local_server.stop()


func _init_runtime() -> void:
	_adapter = AiServiceAdapterScript.new()
	_adapter.configure(match_state, entities, decision_log)

	_http_client = HttpAiClientScript.new()
	_http_client.name = "HttpAiClient"
	add_child(_http_client)
	_http_client.configure(config)

	_local_server = LocalAiServerScript.new()
	_local_server.name = "LocalAiServer"
	_local_server.configure(config, _adapter, _http_client)
	add_child(_local_server)

	for team_entry in _teams:
		var team := int(team_entry.get("team", Enums.Team.AI))
		var civ: CivDef = team_entry.get("civ")
		var ctx := CommandExecutionContextScript.new()
		ctx.match_state = match_state
		ctx.entities = entities
		ctx.team = team
		ctx.civ = civ
		ctx.metrics = metrics
		_exec_contexts[team] = ctx

	call_deferred("_on_match_start")


func _on_match_start() -> void:
	if not enabled:
		return
	match_id = "m_%d" % int(Time.get_unix_time_from_system())
	EventBufferScript.clear()
	metrics.clear()
	_chat_histories.clear()
	for ctx in _exec_contexts.values():
		(ctx as CommandExecutionContext).clear_command_history()

	if not await _ensure_ai_service():
		service_status = "offline"
		enabled = false
		set_process(false)
		push_warning("AiGateway: AI service unavailable; AI decisions disabled")
		return

	service_status = "online"
	await _http_client.post_match_start(
		{
			"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
			"match_id": match_id,
			"teams": _teams_payload(),
		}
	)
	if decision_log != null:
		decision_log.log(
			0.0,
			"Gateway",
			"SETUP",
			"AI Gateway 已连接 %s (%s)" % [config.display_url(), config.protocol],
		)
	call_deferred("_run_tick_requests", tick)


func _ensure_ai_service() -> bool:
	if config.use_local_embedded:
		config.service_url = AiConfigScript.default_service_url()
		_http_client.configure(config)
		return await _local_server.start_async()

	var health := await _http_client.get_health()
	return health.get("ok") == true


func _process(delta: float) -> void:
	if not enabled or match_state == null:
		return
	if match_state.winner != -1:
		stop()
		return
	match_time += delta
	_tick_accum += delta
	if _tick_accum < _tick_interval():
		return
	_tick_accum = 0.0
	tick += 1
	_execute_due_commands(tick)
	if not _request_in_flight:
		_run_tick_requests(tick)


func _run_tick_requests(current_tick: int) -> void:
	_request_in_flight = true
	if config != null and config.uses_chat_protocol():
		if _should_use_tick_batch():
			await _request_chat_batch(current_tick)
		else:
			var events := EventBufferScript.drain()
			for team_entry in _teams:
				await _request_chat_for_team(team_entry, current_tick, events)
	elif _should_use_tick_batch():
		await _request_tick_batch(current_tick)
	else:
		for team_entry in _teams:
			await _request_tick_for_team(team_entry, current_tick, EventBufferScript.drain())
	_request_in_flight = false


func _tick_interval() -> float:
	if config == null:
		return DEFAULT_TICK_INTERVAL
	return maxf(DEFAULT_TICK_INTERVAL * 0.1, float(config.tick_interval_sec))


func _should_use_tick_batch() -> bool:
	return config != null and config.use_tick_batch and _teams.size() >= 2


func _execute_due_commands(current_tick: int) -> void:
	var execute_through := current_tick - 1
	if execute_through < 0:
		return
	var remaining: Array[Dictionary] = []
	for response in _pending_responses:
		if int(response.get("for_tick", -1)) > execute_through:
			remaining.append(response)
			continue
		_apply_response(response)
	_pending_responses = remaining


func _apply_response(response: Dictionary) -> void:
	var team := int(response.get("team", Enums.Team.AI))
	var ctx: CommandExecutionContext = _exec_contexts.get(team)
	if ctx == null:
		return
	for cmd in response.get("commands", []):
		if cmd is Dictionary:
			CommandExecutorScript.execute(cmd, ctx)
	for debug_entry in response.get("debug", []):
		if debug_entry is Dictionary and decision_log != null:
			var label := _team_label(team)
			decision_log.log(
				match_time,
				label,
				String(debug_entry.get("category", "")),
				String(debug_entry.get("message", "")),
			)


func _request_tick_batch(current_tick: int) -> void:
	var events := EventBufferScript.drain()
	var requests: Array = []
	for team_entry in _teams:
		requests.append(_build_tick_payload(team_entry, current_tick, events))
	var payload := {
		"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
		"match_id": match_id,
		"requests": requests,
	}
	var started_usec := Time.get_ticks_usec()
	var responses := await _http_client.post_tick_batch(payload)
	if responses.is_empty() and config.use_local_embedded and _adapter != null:
		responses = _adapter.handle_tick_batch(payload).get("responses", [])
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if responses.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	for response in responses:
		if response is Dictionary:
			_queue_response(response)


func _request_tick_for_team(
	team_entry: Dictionary, current_tick: int, events: Array
) -> void:
	var team := int(team_entry.get("team", Enums.Team.AI))
	var request := _build_tick_payload(team_entry, current_tick, events)
	var started_usec := Time.get_ticks_usec()
	var response := await _http_client.post_tick(request)
	if response.is_empty() and config.use_local_embedded and _adapter != null:
		response = _adapter.handle_tick(request)
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if response.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	response["team"] = team
	_pending_responses.append(response)


func _request_chat_batch(current_tick: int) -> void:
	var events := EventBufferScript.drain()
	var requests: Array = []
	for team_entry in _teams:
		requests.append(_build_chat_payload(team_entry, current_tick, events))
	var payload := {"requests": requests}
	var started_usec := Time.get_ticks_usec()
	var completions := await _http_client.post_chat_completions_batch(payload)
	if completions.is_empty() and _should_fallback_embedded():
		completions = _adapter.handle_chat_completions_batch(payload).get("responses", [])
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if completions.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	var index := 0
	for team_entry in _teams:
		if index >= completions.size():
			break
		var completion: Variant = completions[index]
		if completion is Dictionary:
			_queue_chat_completion(
				completion,
				int(team_entry.get("team", Enums.Team.AI)),
				current_tick,
			)
		index += 1


func _request_chat_for_team(team_entry: Dictionary, current_tick: int, events: Array) -> void:
	var team := int(team_entry.get("team", Enums.Team.AI))
	var request := _build_chat_payload(team_entry, current_tick, events)
	var started_usec := Time.get_ticks_usec()
	var completion := await _http_client.post_chat_completions(request)
	if completion.is_empty() and _should_fallback_embedded():
		completion = _adapter.handle_chat_completions(request)
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if completion.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	_queue_chat_completion(completion, team, current_tick)


func _build_chat_payload(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	var tick_payload := _build_tick_payload(team_entry, current_tick, events)
	var team := int(tick_payload.get("team", 0))
	return PromptAssemblerScript.assemble(
		tick_payload.get("observation", {}),
		tick_payload.get("events", []),
		{
			"match_id": match_id,
			"team": team,
			"tick": current_tick,
			"time_sec": match_time,
			"profile_id": String(tick_payload.get("profile_id", "")),
			"enemy_team": int(tick_payload.get("enemy_team", 0)),
			"team_label": String(tick_payload.get("team_label", "")),
			"model": config.model if config != null else "aoe2-rules-v1",
			"max_tokens": config.max_tokens if config != null else 2048,
			"backend": config.backend if config != null else "rules_compat",
			"log_observation": config.log_observation if config != null else false,
			"llm_base_url": config.llm_base_url if config != null else "",
		},
		_history_for(team),
	)


func _queue_chat_completion(completion: Dictionary, team: int, current_tick: int) -> void:
	var choices: Array = completion.get("choices", [])
	if choices.is_empty():
		_record_tick_skip("empty_choices")
		return
	var response := LlmResponseParserScript.to_tick_response(completion, team, current_tick)
	_remember_history(team, response.get("commands", []))
	_queue_response(response)


func _history_for(team: int) -> Array:
	if config == null or config.history_turns <= 0:
		return []
	var stored: Variant = _chat_histories.get(team, [])
	return stored if stored is Array else []


func _remember_history(team: int, commands: Array) -> void:
	if config == null or config.history_turns <= 0:
		return
	var hist: Array = _history_for(team).duplicate()
	hist.append(
		{
			"role": "assistant",
			"content": LlmResponseParserScript.summarize_commands(commands),
		}
	)
	if hist.size() > config.history_turns:
		hist = hist.slice(hist.size() - config.history_turns)
	_chat_histories[team] = hist


func _should_fallback_embedded() -> bool:
	return config != null and config.use_local_embedded and _adapter != null


func _handle_auth_failure() -> bool:
	if _http_client == null or _http_client.last_error != "http_401":
		return false
	if _should_fallback_embedded():
		push_warning("AiGateway: 401 from AI service; using embedded adapter")
		return false
	push_warning("AiGateway: 401 unauthorized; AI decisions disabled")
	service_status = "unauthorized"
	stop()
	return true


func _queue_response(response: Dictionary) -> void:
	var team := int(response.get("team", Enums.Team.AI))
	response["team"] = team
	_pending_responses.append(response)


func _build_tick_payload(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	var team := int(team_entry.get("team", Enums.Team.AI))
	var enemy_team := int(team_entry.get("enemy_team", Enums.Team.PLAYER))
	var civ: CivDef = team_entry.get("civ")
	var profile := CivAiProfileScript.for_civ(civ)
	var observation := ObservationBuilderScript.build(
		match_state,
		entities,
		team,
		enemy_team,
		match_time,
		profile.defend_radius if profile != null else 20.0,
	)
	return {
		"team": team,
		"team_label": String(team_entry.get("label", _team_label(team))),
		"tick": current_tick,
		"time_sec": match_time,
		"profile_id": String(civ.id if civ != null else ""),
		"enemy_team": enemy_team,
		"events": EventBufferScript.for_team(events, team, match_state != null and match_state.fog_enabled),
		"observation": observation,
	}


func _record_tick_skip(reason: String) -> void:
	if metrics == null:
		return
	if reason in ["timeout", "http_408", "http_503", "network_error"]:
		metrics.record_tick_skip("timeout")
	else:
		metrics.record_tick_skip(reason)


func _teams_payload() -> Array:
	var payload: Array = []
	for team_entry in _teams:
		var civ: CivDef = team_entry.get("civ")
		payload.append(
			{
				"team": int(team_entry.get("team", Enums.Team.AI)),
				"profile_id": String(civ.id if civ != null else ""),
				"label": String(team_entry.get("label", "")),
			}
		)
	return payload


func _team_label(team: Enums.Team) -> String:
	for team_entry in _teams:
		if int(team_entry.get("team", -1)) == int(team):
			return String(team_entry.get("label", "AI"))
	return "AI"
