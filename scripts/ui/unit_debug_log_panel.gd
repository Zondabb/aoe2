extends RichTextLabel

## 显示当前点选单位的调试日志（console 同步写入的行 + 状态快照）。

const UnitDebugFocusScript := preload("res://scripts/debug/unit_debug_focus.gd")

const STATUS_INTERVAL := 0.5
const MAX_LINES := 120

var _status_timer := 0.0
var _last_status_line := ""


func _ready() -> void:
	UnitDebugFocusScript.add_listener(_on_focus_log)
	set_process(true)


func bind_selection(selection: Node) -> void:
	if selection == null:
		return
	if not selection.is_connected("selection_changed", _on_selection_changed):
		selection.connect("selection_changed", _on_selection_changed)


func _on_selection_changed(_selected: Array) -> void:
	clear_log()
	_last_status_line = ""
	_status_timer = STATUS_INTERVAL


func _exit_tree() -> void:
	UnitDebugFocusScript.remove_listener(_on_focus_log)


func _process(delta: float) -> void:
	_status_timer += delta
	if _status_timer < STATUS_INTERVAL:
		return
	_status_timer = 0.0
	var unit := UnitDebugFocusScript.focused_unit()
	if unit == null or not unit.has_method("get_inspect_debug_line"):
		return
	var line: String = unit.call("get_inspect_debug_line")
	if line.is_empty() or line == _last_status_line:
		return
	_last_status_line = line
	UnitDebugFocusScript.log_status(unit, line)


func _on_focus_log(line: String) -> void:
	_append_line(line)


func _append_line(line: String) -> void:
	append_text(line + "\n")
	while get_line_count() > MAX_LINES:
		remove_paragraph(0)
	scroll_to_line(get_line_count())


func clear_log() -> void:
	clear()
	_last_status_line = ""
