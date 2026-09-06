class_name AiServiceAdapter
extends RefCounted

const AiDirectorScript := preload("res://scripts/systems/ai/ai_director.gd")
const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")
const CivAiProfileScript := preload("res://scripts/data/civ_ai_profile.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const LlmResponseParserScript := preload("res://scripts/ai_gateway/llm_response_parser.gd")

var match_state: MatchState
var entities: Node2D
var shared_decision_log: AiDecisionLog

var _directors: Dictionary = {}


func configure(
	state: MatchState,
	entities_root: Node2D,
	decision_log: AiDecisionLog = null
) -> void:
	match_state = state
	entities = entities_root
	shared_decision_log = decision_log


func clear_match(match_id: String) -> void:
	var keys_to_remove: Array[String] = []
	for key in _directors.keys():
		if String(key).begins_with("%s:" % match_id):
			keys_to_remove.append(String(key))
	for key in keys_to_remove:
		var director: AiDirector = _directors[key]
		if director != null:
			director.stop()
		_directors.erase(key)


func handle_match_start(payload: Dictionary) -> Dictionary:
	var match_id := String(payload.get("match_id", ""))
	clear_match(match_id)
	return {"ok": true, "match_id": match_id}


func handle_match_end(payload: Dictionary) -> Dictionary:
	clear_match(String(payload.get("match_id", "")))
	return {"ok": true}


func handle_tick(request: Dictionary) -> Dictionary:
	var match_id := String(request.get("match_id", ""))
	var team := int(request.get("team", Enums.Team.AI))
	var tick := int(request.get("tick", 0))
	var time_sec := float(request.get("time_sec", 0.0))
	var profile_id := String(request.get("profile_id", ""))
	var enemy_team := int(request.get("enemy_team", Enums.Team.PLAYER))
	var team_label := String(request.get("team_label", ""))
	var observation: Dictionary = request.get("observation", {}) as Dictionary

	if match_state == null or entities == null:
		return _error_response(match_id, team, tick, "missing_world")

	var director := _get_or_create_director(
		match_id, team, profile_id, enemy_team, team_label
	)
	director.match_time = time_sec
	var result := director.evaluate_from_observation(tick, observation)
	return {
		"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
		"match_id": match_id,
		"team": team,
		"for_tick": tick,
		"commands": result.get("commands", []),
		"debug": result.get("debug", []),
	}


func handle_chat_completions(payload: Dictionary) -> Dictionary:
	var meta: Dictionary = payload.get("metadata", {}) as Dictionary
	if meta.is_empty() and payload.has("team"):
		meta = payload
	var tick_req := {
		"match_id": String(meta.get("match_id", payload.get("match_id", ""))),
		"team": int(meta.get("team", payload.get("team", Enums.Team.AI))),
		"team_label": String(meta.get("team_label", payload.get("team_label", ""))),
		"tick": int(meta.get("tick", payload.get("tick", 0))),
		"time_sec": float(meta.get("time_sec", payload.get("time_sec", 0.0))),
		"profile_id": String(meta.get("profile_id", payload.get("profile_id", ""))),
		"enemy_team": int(meta.get("enemy_team", payload.get("enemy_team", Enums.Team.PLAYER))),
		"events": payload.get("events", []),
		"observation": payload.get("observation", {}),
	}
	var tick_resp := handle_tick(tick_req)
	return LlmResponseParserScript.wrap_commands(
		tick_resp.get("commands", []),
		tick_resp.get("debug", []),
		String(payload.get("model", "aoe2-rules-v1")),
		"chatcmpl_%s_%d_%d" % [tick_req["match_id"], tick_req["tick"], tick_req["team"]],
		int(tick_req["tick"]),
	)


func handle_chat_completions_batch(payload: Dictionary) -> Dictionary:
	var responses: Array = []
	for item in payload.get("requests", []):
		if item is Dictionary:
			responses.append(handle_chat_completions(item))
	return {"responses": responses}


func handle_tick_batch(payload: Dictionary) -> Dictionary:
	var match_id := String(payload.get("match_id", ""))
	var responses: Array = []
	for item in payload.get("requests", []):
		if not (item is Dictionary):
			continue
		var request := (item as Dictionary).duplicate(true)
		request["match_id"] = match_id
		responses.append(handle_tick(request))
	return {
		"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
		"match_id": match_id,
		"responses": responses,
	}


func _get_or_create_director(
	match_id: String,
	team: Enums.Team,
	profile_id: String,
	enemy_team: Enums.Team,
	team_label: String
) -> AiDirector:
	var key := "%s:%d" % [match_id, int(team)]
	if _directors.has(key):
		return _directors[key] as AiDirector

	var civ := _civ_for_profile(profile_id, team)
	var director := AiDirectorScript.new()
	director.setup(
		match_state,
		entities,
		civ,
		team,
		enemy_team,
		team_label,
		shared_decision_log,
		false,
	)
	director.set_process(false)
	_directors[key] = director
	return director


func _civ_for_profile(profile_id: String, team: Enums.Team) -> CivDef:
	match StringName(profile_id):
		&"teutons":
			return load("res://data/civs/teutons.tres") as CivDef
		&"chinese":
			return load("res://data/civs/chinese.tres") as CivDef
		_:
			if team == Enums.Team.AI:
				return load("res://data/civs/teutons.tres") as CivDef
			return load("res://data/civs/chinese.tres") as CivDef


func _error_response(match_id: String, team: int, tick: int, error: String) -> Dictionary:
	return {
		"protocol_version": AiProtocolScript.PROTOCOL_VERSION,
		"match_id": match_id,
		"team": team,
		"for_tick": tick,
		"commands": [],
		"debug": [],
		"error": error,
	}
