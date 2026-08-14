class_name AiDecisionLog
extends RefCounted

var entries: Array[String] = []
var max_entries := 300
var enabled := true
var _listeners: Array[Callable] = []


func add_listener(listener: Callable) -> void:
	if listener.is_valid() and not _listeners.has(listener):
		_listeners.append(listener)


func remove_listener(listener: Callable) -> void:
	_listeners.erase(listener)


func log(match_time: float, team_label: String, category: String, message: String) -> void:
	if not enabled:
		return
	var line := "[t=%.1fs] %s | %s | %s" % [match_time, team_label, category, message]
	print("AI: ", line)
	entries.append(line)
	while entries.size() > max_entries:
		entries.pop_front()
	for listener in _listeners:
		if listener.is_valid():
			listener.call(line)


func clear() -> void:
	entries.clear()
