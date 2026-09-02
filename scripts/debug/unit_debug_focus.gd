class_name UnitDebugFocus
extends RefCounted

## 观战/调试：仅对当前点选单位输出移动、卸货等调试信息。

static var _focus_id := -1
static var _listeners: Array[Callable] = []
## ai_vs_ai 观战：未点选单位时不输出任何单位调试日志。
static var _spectator_mode := false


static func set_spectator_mode(enabled: bool) -> void:
	_spectator_mode = enabled


static func set_focus_unit(unit: Object) -> void:
	var prev_id := _focus_id
	if unit != null and is_instance_valid(unit) and unit is Node2D:
		if (unit as Node2D).is_in_group("units"):
			_focus_id = unit.get_instance_id()
			if _spectator_mode and _focus_id != prev_id:
				_emit_line("[unit:%s] [focus] selected" % str(unit.get("name")))
			return
	_focus_id = -1
	if _spectator_mode and prev_id >= 0:
		_emit_line("[unit] [focus] cleared")


static func set_focus_from_selection(selected: Array) -> void:
	for entity in selected:
		if entity is Node2D and (entity as Node2D).is_in_group("units"):
			set_focus_unit(entity)
			return
	set_focus_unit(null)


static func clear_focus() -> void:
	_focus_id = -1


static func focused_unit() -> Node2D:
	if _focus_id < 0:
		return null
	var obj := instance_from_id(_focus_id)
	if obj == null or not is_instance_valid(obj):
		_focus_id = -1
		return null
	return obj as Node2D


static func is_focused(unit: Object) -> bool:
	return unit != null and is_instance_valid(unit) and unit.get_instance_id() == _focus_id


static func add_listener(callback: Callable) -> void:
	if callback not in _listeners:
		_listeners.append(callback)


static func remove_listener(callback: Callable) -> void:
	_listeners.erase(callback)


static func log(unit: Object, channel: String, message: String, details: Dictionary = {}) -> void:
	if not _should_emit_for(unit):
		return
	var unit_name := str(unit.get("name")) if unit != null else "?"
	var line := "[unit:%s] [%s] %s" % [unit_name, channel, message]
	if not details.is_empty():
		line += " " + str(details)
	_emit_line(line)


static func log_status(unit: Object, line: String) -> void:
	if not _should_emit_for(unit):
		return
	var unit_name := str(unit.get("name")) if unit != null else "?"
	_emit_line("[unit:%s] [status] %s" % [unit_name, line])


static func _should_emit_for(unit: Object) -> bool:
	if _spectator_mode and _focus_id < 0:
		return false
	if _focus_id >= 0 and not is_focused(unit):
		return false
	return true


static func _emit_line(line: String) -> void:
	print(line)
	for listener in _listeners:
		listener.call(line)
