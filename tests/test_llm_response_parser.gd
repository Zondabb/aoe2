extends RefCounted

const LlmResponseParserScript := preload("res://scripts/ai_gateway/llm_response_parser.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_tool_calls(failures)
	_test_content_json_commands(failures)
	_test_empty_choices(failures)
	_test_invalid_json_content(failures)
	return failures


func _test_tool_calls(failures: Array[String]) -> void:
	var completion := {
		"id": "chatcmpl_1",
		"object": "chat.completion",
		"choices": [
			{
				"index": 0,
				"finish_reason": "tool_calls",
				"message": {
					"role": "assistant",
					"content": null,
					"tool_calls": [
						{
							"id": "call_1",
							"type": "function",
							"function": {
								"name": "gather",
								"arguments": "{\"unit_id\":12,\"target_id\":30}",
							},
						},
						{
							"id": "call_2",
							"type": "function",
							"function": {
								"name": "train",
								"arguments": {
									"building_id": 5,
									"unit_def_id": "villager",
									"command_id": "c_128_9",
								},
							},
						},
					],
				},
			}
		],
	}
	var cmds: Array = LlmResponseParserScript.parse(completion, 128)
	if cmds.size() != 2:
		failures.append("tool_calls should parse two commands, got %d" % cmds.size())
		return
	if String(cmds[0].get("op", "")) != "gather":
		failures.append("first tool_call should be gather")
	if int(cmds[0].get("unit_id", -1)) != 12:
		failures.append("gather unit_id should be 12")
	if String(cmds[0].get("command_id", "")) != "c_128_0":
		failures.append("missing command_id should be generated as c_tick_seq")
	if String(cmds[1].get("command_id", "")) != "c_128_9":
		failures.append("existing command_id should be preserved")


func _test_content_json_commands(failures: Array[String]) -> void:
	var completion := {
		"choices": [
			{
				"message": {
					"role": "assistant",
					"content": '{"commands":[{"op":"move","unit_id":7,"pos":[1.0,2.0]}]}',
				}
			}
		]
	}
	var cmds: Array = LlmResponseParserScript.parse(completion, 3)
	if cmds.size() != 1:
		failures.append("content JSON commands should parse one command")
		return
	if String(cmds[0].get("op", "")) != "move":
		failures.append("content command op should be move")
	if String(cmds[0].get("command_id", "")) != "c_3_0":
		failures.append("content command should get generated command_id")


func _test_empty_choices(failures: Array[String]) -> void:
	var cmds: Array = LlmResponseParserScript.parse({"choices": []}, 1)
	if not cmds.is_empty():
		failures.append("empty choices should parse to no commands")
	cmds = LlmResponseParserScript.parse({}, 1)
	if not cmds.is_empty():
		failures.append("empty completion should parse to no commands")


func _test_invalid_json_content(failures: Array[String]) -> void:
	var completion := {
		"choices": [{"message": {"role": "assistant", "content": "not-json {"}}]
	}
	var cmds: Array = LlmResponseParserScript.parse(completion, 1)
	if not cmds.is_empty():
		failures.append("invalid JSON content should parse to no commands")
	var unknown := {
		"choices": [
			{
				"message": {
					"role": "assistant",
					"tool_calls": [
						{
							"id": "call_x",
							"type": "function",
							"function": {"name": "explode", "arguments": "{}"},
						}
					],
				}
			}
		]
	}
	cmds = LlmResponseParserScript.parse(unknown, 1)
	if not cmds.is_empty():
		failures.append("unknown tool name should be skipped")
	var wrapped: Dictionary = LlmResponseParserScript.wrap_commands(
		[{"op": "gather", "unit_id": 1, "target_id": 2}],
		[{"category": "ECON", "message": "采集"}],
		"aoe2-rules-v1",
		"chatcmpl_t",
		4,
	)
	var back: Array = LlmResponseParserScript.parse(wrapped, 4)
	if back.size() != 1 or String(back[0].get("op", "")) != "gather":
		failures.append("wrap_commands should round-trip gather")
	var tick_resp: Dictionary = LlmResponseParserScript.to_tick_response(wrapped, 1, 4)
	if int(tick_resp.get("team", -1)) != 1 or int(tick_resp.get("for_tick", -1)) != 4:
		failures.append("to_tick_response should set team and for_tick")
