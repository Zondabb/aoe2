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
var _generation := 0
var _event_subscriber := 0
var _event_delivery: Dictionary = {}
var _event_manual_revision := 0
var _delivery_succeeded := false
var _remote_session_ended := false
var agent_status: Dictionary = {}
var planning_status: Dictionary = {}
var goals: Dictionary = {}


func setup(
	state: MatchState,
	entities_root: Node2D,
	teams: Array,
	gateway_config: AiConfig = null,
	shared_log: AiDecisionLog = null
) -> void:
	if _http_client != null:
		stop()
		_http_client.queue_free()
		if _local_server != null:
			_local_server.queue_free()
	_generation += 1
	enabled = true
	service_status = "starting"
	match_time = 0.0
	tick = 0
	_tick_accum = 0.0
	_remote_session_ended = false
	agent_status.clear()
	planning_status.clear()
	goals.clear()
	_pending_responses.clear()
	_exec_contexts.clear()
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


func stop(status: String = "stopped") -> void:
	var stopped_epoch := _generation
	_generation += 1
	enabled = false
	service_status = status
	set_process(false)
	_pending_responses.clear()
	_request_in_flight = false
	if _event_subscriber != 0:
		EventBufferScript.unsubscribe(_event_subscriber)
		_event_subscriber = 0
	if _http_client != null and is_instance_valid(_http_client):
		_http_client.cancel_requests()
	if _local_server != null and is_instance_valid(_local_server):
		_local_server.stop()
	if not _remote_session_ended and not match_id.is_empty() and config != null and not config.use_local_embedded and is_inside_tree():
		_remote_session_ended = true
		_close_remote_session(get_tree(), config, match_id, stopped_epoch)


static func _close_remote_session(tree: SceneTree, source: AiConfig, session_id: String, epoch: int) -> void:
	# Root-owned cleanup survives removing an autoplay Gateway or its scene.
	var client := HttpAiClientScript.new()
	tree.root.add_child.call_deferred(client)
	await tree.process_frame
	if not is_instance_valid(client) or not client.is_inside_tree():
		return
	var cleanup_config := AiConfigScript.new()
	cleanup_config.service_url = source.service_url
	cleanup_config.api_token = source.api_token
	cleanup_config.timeout_sec = 2.0
	cleanup_config.use_local_embedded = false
	client.configure(cleanup_config)
	await client.post_match_end({"match_id": session_id, "session_epoch": str(epoch)})
	if is_instance_valid(client):
		client.queue_free()


func _exit_tree() -> void:
	stop()


func _is_current(generation: int) -> bool:
	return enabled and generation == _generation and not is_queued_for_deletion()


func _read_events() -> Array:
	_event_delivery = EventBufferScript.peek(_event_subscriber)
	_event_manual_revision = EntityRegistryScript.manual_revision
	return _event_delivery.get("events", [])


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
		ctx.session_epoch = str(_generation)
		ctx.require_session_epoch = config.uses_multi_agent_protocol()
		_exec_contexts[team] = ctx

	call_deferred("_on_match_start", _generation)


func _on_match_start(generation: int = -1) -> void:
	if generation == -1:
		generation = _generation
	if not _is_current(generation):
		return
	match_id = "m_%d_%d_%d" % [int(Time.get_unix_time_from_system() * 1000.0), Time.get_ticks_usec(), get_instance_id()]
	if _event_subscriber != 0:
		EventBufferScript.unsubscribe(_event_subscriber)
	_event_subscriber = EventBufferScript.subscribe()
	metrics.clear()
	for ctx in _exec_contexts.values():
		(ctx as CommandExecutionContext).clear_command_history()
		ctx.match_id = match_id
		ctx.session_epoch = str(generation)

	var starting_server := _local_server
	var available := await _ensure_ai_service()
	if not _is_current(generation):
		if starting_server != null and is_instance_valid(starting_server) and starting_server.is_running():
			starting_server.stop()
		return
	if not available:
		stop("unauthorized" if _http_client.last_error == "http_401" else "offline")
		push_warning("AiGateway: AI service unavailable; AI decisions disabled")
		return

	var start_result := await _http_client.post_match_start(
		{
			"protocol_version": 3 if config.uses_multi_agent_protocol() else AiProtocolScript.PROTOCOL_VERSION,
			"match_id": match_id,
			"session_epoch": str(generation),
			"teams": _teams_payload(),
		}
	)
	if not _is_current(generation):
		return
	if start_result.get("ok") != true:
		stop("unauthorized" if start_result.get("reason") == "http_401" else "offline")
		return
	service_status = "online"
	if decision_log != null:
		decision_log.log(
			0.0,
			"Gateway",
			"SETUP",
			"AI Gateway 已连接 %s (%s)" % [config.display_url(), "v3_multi_agent" if config.uses_multi_agent_protocol() else config.protocol],
		)
	call_deferred("_run_tick_requests", tick)


func _ensure_ai_service() -> bool:
	if config.use_local_embedded:
		config.service_url = AiConfigScript.default_service_url()
		_http_client.configure(config)
		return await _local_server.start_async()

	var client := _http_client
	var health := await client.get_health()
	if is_instance_valid(client):
		client.last_error = String(health.get("reason", ""))
	return health.get("ok") == true


func _process(delta: float) -> void:
	if not enabled or match_state == null:
		return
	if not is_instance_valid(entities) or not entities.is_inside_tree() or entities.is_queued_for_deletion():
		stop()
		return
	if match_state.winner != -1:
		stop()
		return
	match_time += delta
	if service_status != "online":
		return
	_tick_accum += delta
	if _tick_accum < _tick_interval():
		return
	_tick_accum = 0.0
	tick += 1
	_execute_due_commands(tick)
	if not _request_in_flight:
		_run_tick_requests(tick)


func _run_tick_requests(current_tick: int) -> void:
	var generation := _generation
	if not _is_current(generation) or _request_in_flight or service_status != "online":
		return
	_request_in_flight = true
	_delivery_succeeded = true
	for entry in _teams:
		EntityRegistryScript.sample_owned_state(entities, int(entry.get("team", Enums.Team.AI)), match_time)
	var events := _read_events()
	if config != null and config.uses_multi_agent_protocol():
		for team_entry in _teams:
			await _request_multi_agent_for_team(team_entry, current_tick, events)
			if not _is_current(generation):
				return
	elif config != null and config.uses_chat_protocol():
		if _should_use_tick_batch():
			await _request_chat_batch(current_tick, events)
		else:
			for team_entry in _teams:
				await _request_chat_for_team(team_entry, current_tick, events)
				if not _is_current(generation):
					return
	elif _should_use_tick_batch():
		await _request_tick_batch(current_tick, events)
	else:
		for team_entry in _teams:
			await _request_tick_for_team(team_entry, current_tick, events)
			if not _is_current(generation):
				return
	if _is_current(generation):
		if _delivery_succeeded:
			EventBufferScript.acknowledge(_event_subscriber, int(_event_delivery.get("to_seq", 0)))
		_request_in_flight = false


func _tick_interval() -> float:
	if config == null:
		return DEFAULT_TICK_INTERVAL
	if config.uses_multi_agent_protocol():
		return clampf(config.fast_tick_interval_sec, 0.25, 5.0)
	return maxf(DEFAULT_TICK_INTERVAL * 0.1, float(config.tick_interval_sec))


func _should_use_tick_batch() -> bool:
	return config != null and config.use_tick_batch and _teams.size() >= 2


func _execute_due_commands(current_tick: int) -> void:
	if not enabled:
		return
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
	if not enabled:
		return
	if int(response.get("protocol_version", 1)) >= 3 and not _valid_multi_agent_response(response):
		return
	var team := int(response.get("team", Enums.Team.AI))
	var ctx: CommandExecutionContext = _exec_contexts.get(team)
	if ctx == null:
		return
	ctx.sim_time = match_time
	for cmd in response.get("commands", []):
		if not enabled:
			return
		if cmd is Dictionary:
			var result := CommandExecutorScript.execute(cmd, ctx)
			# Report acceptance/rejection to the issuing team's next decision.
			# Acceptance is not completion; foundations and queues remain observed.
			if cmd.get("op") != "noop" and result.get("reason") != "duplicate_skipped":
				var feedback := {
					"type":"command_result", "team":team,
					"command_id":String(cmd.get("command_id", "")),
					"op":String(cmd.get("op", "")), "ok":bool(result.get("ok", false)),
					"reason":String(result.get("reason", "")), "_visible_to":[team],
					"command":cmd.duplicate(true),
					"task_id":String(cmd.get("task_id", "")), "session_epoch":str(_generation),
					"time_sec":match_time, "tick":tick,
				}
				for key in ["unit_id", "builder_id", "building_id", "target_id"]:
					if cmd.has(key): feedback[key] = cmd[key]
				feedback["entity_id"] = cmd.get("unit_id", cmd.get("builder_id", cmd.get("building_id", null)))
				for key in ["created_entity_id", "created_entity_ids", "segment_count", "building_id", "queue_id", "queue_ids"]:
					if result.has(key):
						feedback[key] = result[key]
				EventBufferScript.push(feedback)
	for debug_entry in response.get("debug", []):
		if debug_entry is Dictionary and decision_log != null:
			var label := _team_label(team)
			decision_log.log(
				match_time,
				label,
				String(debug_entry.get("category", "")),
				String(debug_entry.get("message", "")),
			)


func _request_multi_agent_for_team(team_entry: Dictionary, current_tick: int, events: Array) -> void:
	var generation := _generation
	var team := int(team_entry.get("team", Enums.Team.AI))
	var payload := await _build_multi_agent_payload_budgeted(team_entry, current_tick, events)
	if not _is_current(generation) or payload.is_empty(): return
	var started := Time.get_ticks_usec()
	var response := await _http_client.post_multi_agent_tick(payload)
	if not _is_current(generation):
		return
	last_tick_latency_ms = float(Time.get_ticks_usec() - started) / 1000.0
	if response.is_empty() or not _valid_multi_agent_response(response, team, current_tick):
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if response.is_empty() else "invalid_v3_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	agent_status = response.get("agent_status", {})
	planning_status = response.get("planning", {})
	goals = response.get("goals", {})
	# v3 is already a fast deterministic command batch; no extra 10-second tick.
	_apply_response(response)


func _valid_multi_agent_response(response: Dictionary, expected_team: int = -1, expected_seq: int = -1) -> bool:
	if int(response.get("protocol_version", 0)) != 3 or String(response.get("match_id", "")) != match_id:
		return false
	if str(response.get("session_epoch", "")) != str(_generation):
		return false
	var team := int(response.get("team", -1))
	if not _exec_contexts.has(team) or (expected_team >= 0 and team != expected_team):
		return false
	if expected_seq >= 0 and (int(response.get("acknowledged_observation_seq", -1)) != expected_seq or int(response.get("for_tick", -1)) != expected_seq):
		return false
	return response.get("commands") is Array and response.get("agent_status", {}) is Dictionary and response.get("goals", {}) is Dictionary and response.get("planning", {}) is Dictionary


func _build_multi_agent_payload(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	return _assemble_multi_agent_payload(_build_tick_payload(team_entry, current_tick, events), current_tick)


func _build_multi_agent_payload_budgeted(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	return _assemble_multi_agent_payload(await _build_tick_payload_budgeted(team_entry, current_tick, events), current_tick)


func _assemble_multi_agent_payload(payload: Dictionary, current_tick: int) -> Dictionary:
	if payload.is_empty(): return {}
	var delivery := _event_delivery.duplicate(true)
	delivery.erase("events")
	return {
		"model": AiConfigScript.SERVICE_MODEL,
		"messages": [], "tools": [], "observation": payload.observation, "events": payload.events,
		"metadata": {
			"protocol_version": 3, "match_id": match_id, "session_epoch": str(_generation),
			"observation_seq": current_tick, "tick": current_tick, "time_sec": payload.time_sec,
			"team": payload.team, "enemy_team": payload.enemy_team,
			"profile_id": payload.profile_id, "event_delivery": delivery,
		},
	}


func _request_tick_batch(current_tick: int, events: Array = []) -> void:
	var generation := _generation
	if not _is_current(generation):
		return
	var requests: Array = []
	for team_entry in _teams:
		var request := await _build_tick_payload_budgeted(team_entry, current_tick, events)
		if not _is_current(generation) or request.is_empty(): return
		requests.append(request)
	var payload := {
		"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
		"match_id": match_id,
		"requests": requests,
	}
	var started_usec := Time.get_ticks_usec()
	var responses := await _http_client.post_tick_batch(payload)
	if not _is_current(generation):
		return
	if responses.is_empty() and config.use_local_embedded and _adapter != null:
		responses = _adapter.handle_tick_batch(payload).get("responses", [])
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if responses.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	if responses.size() != requests.size():
		_delivery_succeeded = false
	for response in responses:
		if response is Dictionary:
			_queue_response(response)
		else:
			_delivery_succeeded = false


func _request_tick_for_team(
	team_entry: Dictionary, current_tick: int, events: Array
) -> void:
	var generation := _generation
	if not _is_current(generation):
		return
	var team := int(team_entry.get("team", Enums.Team.AI))
	var request := await _build_tick_payload_budgeted(team_entry, current_tick, events)
	if not _is_current(generation) or request.is_empty(): return
	var started_usec := Time.get_ticks_usec()
	var response := await _http_client.post_tick(request)
	if not _is_current(generation):
		return
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
	_queue_response(response)


func _request_chat_batch(current_tick: int, events: Array = []) -> void:
	var generation := _generation
	if not _is_current(generation):
		return
	var requests: Array = []
	for team_entry in _teams:
		var request := await _build_chat_payload_budgeted(team_entry, current_tick, events)
		if not _is_current(generation) or request.is_empty(): return
		requests.append(request)
	var payload := {"requests": requests}
	var started_usec := Time.get_ticks_usec()
	var completions := await _http_client.post_chat_completions_batch(payload)
	if not _is_current(generation):
		return
	if completions.is_empty() and _should_fallback_embedded():
		completions = _adapter.handle_chat_completions_batch(payload).get("responses", [])
	last_tick_latency_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	if completions.is_empty():
		if _handle_auth_failure():
			return
		_record_tick_skip(_http_client.last_error if _http_client != null else "empty_response")
		return
	metrics.record_tick_success(last_tick_latency_ms)
	if completions.size() != requests.size():
		_delivery_succeeded = false
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
		else:
			_delivery_succeeded = false
		index += 1


func _request_chat_for_team(team_entry: Dictionary, current_tick: int, events: Array) -> void:
	var generation := _generation
	if not _is_current(generation):
		return
	var team := int(team_entry.get("team", Enums.Team.AI))
	var request := await _build_chat_payload_budgeted(team_entry, current_tick, events)
	if not _is_current(generation) or request.is_empty(): return
	var started_usec := Time.get_ticks_usec()
	var completion := await _http_client.post_chat_completions(request)
	if not _is_current(generation):
		return
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
	return _assemble_chat_payload(_build_tick_payload(team_entry, current_tick, events), current_tick)


func _build_chat_payload_budgeted(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	return _assemble_chat_payload(await _build_tick_payload_budgeted(team_entry, current_tick, events), current_tick)


func _assemble_chat_payload(tick_payload: Dictionary, current_tick: int) -> Dictionary:
	if tick_payload.is_empty(): return {}
	var team := int(tick_payload.get("team", 0))
	return PromptAssemblerScript.assemble(
		tick_payload.get("observation", {}),
		tick_payload.get("events", []),
		{
			"match_id": match_id,
			"team": team,
			"tick": current_tick,
			"time_sec": tick_payload.time_sec,
			"profile_id": String(tick_payload.get("profile_id", "")),
			"enemy_team": int(tick_payload.get("enemy_team", 0)),
			"team_label": String(tick_payload.get("team_label", "")),
		},
	)


func _queue_chat_completion(completion: Dictionary, team: int, current_tick: int) -> void:
	if not enabled:
		return
	var choices: Array = completion.get("choices", [])
	if choices.is_empty():
		_record_tick_skip("empty_choices")
		return
	var response := LlmResponseParserScript.to_tick_response(completion, team, current_tick)
	_queue_response(response)


func _should_fallback_embedded() -> bool:
	return config != null and config.use_local_embedded and _adapter != null


func _handle_auth_failure() -> bool:
	if _http_client == null or _http_client.last_error != "http_401":
		return false
	if _should_fallback_embedded():
		push_warning("AiGateway: 401 from AI service; using embedded adapter")
		return false
	push_warning("AiGateway: 401 unauthorized; AI decisions disabled")
	stop("unauthorized")
	return true


func _queue_response(response: Dictionary) -> void:
	if not enabled:
		return
	var team := int(response.get("team", Enums.Team.AI))
	response["team"] = team
	_pending_responses.append(response)


func _prepare_tick_observation(team_entry: Dictionary) -> Dictionary:
	var team := int(team_entry.get("team", Enums.Team.AI))
	var context: CommandExecutionContext = _exec_contexts.get(team)
	if context != null:
		# All teams share this delivery snapshot. A later team's observation may
		# be built after awaiting earlier HTTP, but it has not received human
		# events created during that wait. Keep its execution fence at the batch.
		context.observed_manual_revision = _event_manual_revision if _request_in_flight else EntityRegistryScript.manual_revision
	var enemy_team := int(team_entry.get("enemy_team", Enums.Team.PLAYER))
	var civ: CivDef = team_entry.get("civ")
	var profile := CivAiProfileScript.for_civ(civ)
	var defend_radius: float = profile.defend_radius if profile != null else 20.0
	return {"team": team, "enemy_team": enemy_team, "civ": civ, "defend_radius": defend_radius, "time_sec": match_time}


func _build_tick_payload(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	var info := _prepare_tick_observation(team_entry)
	var observation := ObservationBuilderScript.build(match_state, entities, info.team, info.enemy_team, info.time_sec, info.defend_radius)
	return _assemble_tick_payload(team_entry, current_tick, events, info, observation)


func _build_tick_payload_budgeted(team_entry: Dictionary, current_tick: int, events: Array) -> Dictionary:
	var generation := _generation
	if not _is_current(generation): return {}
	if not is_instance_valid(entities) or not entities.is_inside_tree() or entities.is_queued_for_deletion():
		_delivery_succeeded = false
		return {}
	var info := _prepare_tick_observation(team_entry)
	var observation: Dictionary = await ObservationBuilderScript.build_budgeted(match_state, entities, info.team, info.enemy_team, info.time_sec,
		info.defend_radius, false, _wait_observation_frame.bind(generation), _observation_frame_budget_usec())
	if not _is_current(generation): return {}
	if observation.is_empty():
		# A cancelled preparation sent no HTTP request and cannot acknowledge the
		# event delivery. Never let an old generation overwrite a new one's flag.
		_delivery_succeeded = false
		return {}
	return _assemble_tick_payload(team_entry, current_tick, events, info, observation)


func _assemble_tick_payload(team_entry: Dictionary, current_tick: int, events: Array, info: Dictionary, observation: Dictionary) -> Dictionary:
	var team: int = info.team
	var civ: CivDef = info.civ
	return {
		"team": team,
		"team_label": String(team_entry.get("label", _team_label(team))),
		"tick": current_tick,
		"time_sec": info.time_sec,
		"profile_id": String(civ.id if civ != null else ""),
		"enemy_team": info.enemy_team,
		"events": EventBufferScript.for_team(events, team, match_state != null and match_state.fog_enabled),
		"observation": observation,
	}


func _observation_frame_budget_usec() -> int:
	return 4000


func _wait_observation_frame(generation: int) -> bool:
	if not _is_current(generation) or not is_instance_valid(_http_client): return false
	var client := _http_client
	var cancel_generation: int = client._cancel_generation
	# The HTTP client's cancellable waiter is also woken synchronously by stop(),
	# so all snapshot coroutines unwind before a Gateway can leave the tree.
	var resumed: bool = await client._wait_frame()
	return resumed and is_instance_valid(client) and client._cancel_generation == cancel_generation \
		and _is_current(generation) and client == _http_client and is_instance_valid(entities) \
		and entities.is_inside_tree() and not entities.is_queued_for_deletion()


func _record_tick_skip(reason: String) -> void:
	_delivery_succeeded = false
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
