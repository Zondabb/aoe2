class_name LlmResponseParser
extends RefCounted

const AiToolCatalogScript := preload("res://scripts/ai_gateway/ai_tool_catalog.gd")

const _ARG_KEYS := [
	"command_id",
	"unit_id",
	"building_id",
	"target_id",
	"building_def_id",
	"unit_def_id",
	"technology_id",
	"pos",
	"builder_id",
]


static func to_tick_response(completion: Dictionary, team: int, tick: int) -> Dictionary:
	return {
		"team": team,
		"for_tick": tick,
		"commands": parse(completion, tick),
		"debug": completion.get("debug", []),
	}


static func wrap_commands(
	commands: Array,
	debug: Array = [],
	model: String = "aoe2-rules-v1",
	completion_id: String = "chatcmpl_local",
	tick: int = 0
) -> Dictionary:
	var tool_calls: Array = []
	var seq := 0
	for cmd in commands:
		if not (cmd is Dictionary):
			continue
		var src: Dictionary = cmd
		var name := String(src.get("op", "")).strip_edges()
		if not AiToolCatalogScript.is_known(name):
			continue
		var args := {}
		for key in _ARG_KEYS:
			if src.has(key) and src[key] != null:
				args[key] = src[key]
		if String(args.get("command_id", "")).is_empty():
			args["command_id"] = "c_%d_%d" % [tick, seq]
		tool_calls.append(
			{
				"id": "call_%d" % (seq + 1),
				"type": "function",
				"function": {"name": name, "arguments": JSON.stringify(args)},
			}
		)
		seq += 1
	return {
		"id": completion_id,
		"object": "chat.completion",
		"model": model,
		"choices": [
			{
				"index": 0,
				"finish_reason": "tool_calls" if not tool_calls.is_empty() else "stop",
				"message": {
					"role": "assistant",
					"content": null,
					"tool_calls": tool_calls,
				},
			}
		],
		"usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
		"debug": debug,
	}


static func summarize_commands(commands: Array) -> String:
	if commands.is_empty():
		return "noop"
	var names: PackedStringArray = PackedStringArray()
	for cmd in commands:
		if cmd is Dictionary:
			names.append(String((cmd as Dictionary).get("op", "noop")))
	return "tools: " + ", ".join(names)


## Parse a Chat Completions body into Executor-compatible command dicts.
## Priority: tool_calls → content JSON commands → empty.
static func parse(completion: Dictionary, tick: int = 0) -> Array:
	var commands: Array = []
	if completion.is_empty():
		return commands
	var message := _first_message(completion)
	var tool_calls: Variant = message.get("tool_calls", [])
	if tool_calls is Array and not (tool_calls as Array).is_empty():
		var seq := 0
		for call in tool_calls:
			if not (call is Dictionary):
				continue
			var cmd := _command_from_tool_call(call, tick, seq)
			if not cmd.is_empty():
				commands.append(cmd)
				seq += 1
		return commands
	return _commands_from_content(message.get("content", null), tick)


static func _first_message(completion: Dictionary) -> Dictionary:
	var choices: Array = completion.get("choices", [])
	if choices.is_empty() or not (choices[0] is Dictionary):
		return {}
	var message: Variant = (choices[0] as Dictionary).get("message", {})
	return message if message is Dictionary else {}


static func _command_from_tool_call(call: Dictionary, tick: int, seq: int) -> Dictionary:
	var fn: Variant = call.get("function", {})
	if not (fn is Dictionary):
		return {}
	var name := String((fn as Dictionary).get("name", "")).strip_edges()
	if not AiToolCatalogScript.is_known(name):
		return {}
	var args := _parse_arguments((fn as Dictionary).get("arguments", ""))
	var cmd := {"op": name}
	_copy_arg_fields(cmd, args)
	_ensure_command_id(cmd, tick, seq)
	return cmd


static func _commands_from_content(content: Variant, tick: int) -> Array:
	var parsed := _parse_content_object(content)
	if parsed.is_empty():
		return []
	var raw_commands: Variant = parsed.get("commands", [])
	if not (raw_commands is Array):
		return []
	var out: Array = []
	var seq := 0
	for item in raw_commands:
		if not (item is Dictionary):
			continue
		var src: Dictionary = item
		var op := String(src.get("op", "")).strip_edges()
		if not AiToolCatalogScript.is_known(op):
			continue
		var cmd := {"op": op}
		_copy_arg_fields(cmd, src)
		_ensure_command_id(cmd, tick, seq)
		out.append(cmd)
		seq += 1
	return out


static func _parse_content_object(content: Variant) -> Dictionary:
	if content == null:
		return {}
	if content is Dictionary:
		return content
	if not (content is String):
		return {}
	var text := (content as String).strip_edges()
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


static func _parse_arguments(raw: Variant) -> Dictionary:
	if raw is Dictionary:
		return raw
	if not (raw is String):
		return {}
	var text := (raw as String).strip_edges()
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


static func _copy_arg_fields(cmd: Dictionary, args: Dictionary) -> void:
	for key in _ARG_KEYS:
		if args.has(key) and args[key] != null:
			cmd[key] = args[key]


static func _ensure_command_id(cmd: Dictionary, tick: int, seq: int) -> void:
	var existing := String(cmd.get("command_id", "")).strip_edges()
	if existing.is_empty():
		cmd["command_id"] = "c_%d_%d" % [tick, seq]
	else:
		cmd["command_id"] = existing
