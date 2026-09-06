extends RefCounted

const PromptAssemblerScript := preload("res://scripts/ai_gateway/prompt_assembler.gd")
const AiToolCatalogScript := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_tool_catalog_names(failures)
	_test_user_prompt_contains_economy_and_entity(failures)
	return failures


func _test_tool_catalog_names(failures: Array[String]) -> void:
	var expected := [
		"gather",
		"train",
		"place_building",
		"build",
		"move",
		"attack",
		"stop",
		"noop",
	]
	if AiToolCatalogScript.TOOL_NAMES != expected:
		failures.append("tool catalog names must match design §4.5")
	var payload: Array = AiToolCatalogScript.tools_payload()
	if payload.size() != expected.size():
		failures.append("tools_payload size should match TOOL_NAMES")
	var names: Array = []
	for tool in payload:
		if tool is Dictionary:
			var fn: Dictionary = (tool as Dictionary).get("function", {})
			names.append(String(fn.get("name", "")))
	if names != expected:
		failures.append("tools_payload names should match TOOL_NAMES, got %s" % str(names))


func _test_user_prompt_contains_economy_and_entity(failures: Array[String]) -> void:
	var observation := {
		"economy": {"food": 180, "wood": 200, "gold": 100, "pop_used": 4, "pop_cap": 5},
		"derived": {
			"own_tc_id": 5,
			"own_tc_pos": [-40.0, -40.0],
			"enemy_tc_id": 105,
			"enemy_tc_pos": [40.0, 40.0],
			"threat_near_base": false,
			"villager_count": 4,
			"military_count": 0,
			"incomplete_buildings": 0,
		},
		"entities": [
			{
				"id": 12,
				"kind": "unit",
				"def_id": "villager",
				"team": 0,
				"pos": [-38.2, -39.1],
				"hp": 25.0,
				"max_hp": 25.0,
				"order": "GATHER",
			},
			{
				"id": 30,
				"kind": "resource",
				"resource_type": "FOOD",
				"pos": [-25.0, -20.0],
				"amount": 125.0,
			},
		],
	}
	var events := [{"seq": 40, "type": "resource_depleted", "entity_id": 30}]
	var payload: Dictionary = PromptAssemblerScript.assemble(
		observation,
		events,
		{"match_id": "m_test", "team": 0, "tick": 128, "time_sec": 64.0, "profile_id": "chinese", "team_label": "Chinese"}
	)
	if payload.get("stream") != false:
		failures.append("assembled chat request must set stream=false")
	var messages: Array = payload.get("messages", [])
	if messages.size() != 2:
		failures.append("assemble should produce system + user messages")
		return
	var user := String((messages[1] as Dictionary).get("content", ""))
	if user.find("food=180") < 0:
		failures.append("user prompt should include food=180, got: %s" % user)
	if user.find("wood=200") < 0:
		failures.append("user prompt should include wood=200")
	if user.find("id=12") < 0 or user.find("villager") < 0:
		failures.append("user prompt should include villager entity text")
	if user.find("resource_depleted#30") < 0:
		failures.append("user prompt should include event text")
	var meta: Dictionary = payload.get("metadata", {})
	if int(meta.get("protocol_version", 0)) != 2:
		failures.append("metadata.protocol_version should be 2")
	if not (payload.get("observation") is Dictionary):
		failures.append("assemble should attach structured observation")
	var tools: Array = payload.get("tools", [])
	if tools.size() != AiToolCatalogScript.TOOL_NAMES.size():
		failures.append("assemble should include full tool catalog")
	var with_history: Dictionary = PromptAssemblerScript.assemble(
		observation,
		[],
		{"tick": 1, "team": 0},
		[{"role": "assistant", "content": "tools: gather"}],
	)
	var hist_messages: Array = with_history.get("messages", [])
	if hist_messages.size() != 3:
		failures.append("history should insert between system and user, got %d" % hist_messages.size())
	elif String((hist_messages[1] as Dictionary).get("content", "")).find("gather") < 0:
		failures.append("history assistant summary should be kept")
	var no_history: Dictionary = PromptAssemblerScript.assemble(observation, [], {"tick": 1})
	if (no_history.get("messages", []) as Array).size() != 2:
		failures.append("empty history should keep system+user only")
