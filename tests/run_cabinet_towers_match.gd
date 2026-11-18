extends "res://tests/run_ai_duel_match.gd"
## The duel driver in tools/test_cabinet_towers_e2e.py reads one observation at a time.
## Only the test transport changes. The parent runs the full map, fog, economy and command executor.

class LocalClient extends Node:
	var observation_path: String
	var last_error := ""

	func post_match_start(_payload: Dictionary) -> Dictionary:
		return {"ok": true}

	func post_multi_agent_tick(payload: Dictionary) -> Dictionary:
		var observation := FileAccess.open(observation_path, FileAccess.WRITE)
		if observation == null:
			last_error = error_string(FileAccess.get_open_error())
			return {}
		observation.store_string(JSON.stringify(payload))
		observation.close()
		print("CABINET TOWER TICK")
		var reply: Variant = JSON.parse_string(OS.read_string_from_stdin(1048576))
		if reply is Dictionary: return reply
		last_error = "Missing command batch from the duel driver"
		return {}

	func post_match_end(_payload: Dictionary) -> void:
		pass

func _create_client(address: String) -> Node:
	var client := LocalClient.new()
	client.observation_path = address
	root.add_child(client)
	return client
