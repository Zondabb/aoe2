extends Control

## The control belongs to the local player; the match controller owns authority.
var _controller: Node
var _panel: PanelContainer
var _check: CheckBox
var _status: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.08, 0.055, 0.88)
	style.border_color = Color(0.48, 0.39, 0.24, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 6
	style.content_margin_right = 8
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	_panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	_panel.add_child(row)
	_check = CheckBox.new()
	_check.name = "AutoplayCheck"
	_check.text = "AI 托管（Python LLM）"
	_check.add_theme_font_size_override("font_size", 14)
	_check.add_theme_icon_override("unchecked", _checkbox_icon(false, false))
	_check.add_theme_icon_override("checked", _checkbox_icon(true, false))
	_check.add_theme_icon_override("unchecked_disabled", _checkbox_icon(false, true))
	_check.add_theme_icon_override("checked_disabled", _checkbox_icon(true, true))
	_check.disabled = true
	_check.toggled.connect(_on_toggled)
	row.add_child(_check)
	_status = Label.new()
	_status.name = "Status"
	_status.add_theme_font_size_override("font_size", 13)
	_status.text = "准备中…"
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_status)
	resized.connect(_sync_layout)
	_sync_layout()
	call_deferred("_bind_controller")


func _checkbox_icon(checked: bool, disabled: bool) -> Texture2D:
	# An explicit gold outline stays visible on the original dark game theme.
	# These native SVG icons scale cleanly and require no bitmap assets.
	var border := "#978b6a" if disabled else "#ddc792"
	var fill := "#25251e" if disabled else "#1c2016"
	var mark := ""
	if checked:
		fill = "#3d4431" if disabled else "#365833"
		border = "#a99b75" if disabled else "#f1d395"
		var ink := "#bdc69f" if disabled else "#eaf8bf"
		mark = "<path d='M4 9 L7.2 12.2 L13.6 5.8' fill='none' stroke='%s' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'/>" % ink
	var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18' viewBox='0 0 18 18'><rect x='1' y='1' width='16' height='16' rx='2' fill='%s' stroke='%s' stroke-width='2'/>%s</svg>" % [fill, border, mark]
	var icon := Image.new()
	icon.load_svg_from_string(svg)
	return ImageTexture.create_from_image(icon)


func _process(_delta: float) -> void:
	# Bootstrap creates the controller after the scene's child _ready calls.
	if _controller == null:
		_bind_controller()


func _bind_controller() -> void:
	_controller = get_node_or_null("../../PlayerAiControl")
	if _controller == null or not _controller.has_method("local_state"):
		_controller = null
		return
	if _controller.has_signal("state_changed") and not _controller.is_connected("state_changed", _sync_state):
		_controller.connect("state_changed", _sync_state)
	_sync_state()
	set_process(false)


func _sync_state() -> void:
	if not is_instance_valid(_controller):
		return
	var state: Dictionary = _controller.call("local_state")
	var enabled := bool(state.get("enabled", false))
	var status := String(state.get("status", "off"))
	var available := bool(state.get("available", false))
	var message := String(state.get("message", ""))
	_check.set_pressed_no_signal(enabled)
	# Connecting can be cancelled immediately. Only an unacknowledged online
	# request temporarily prevents another toggle.
	_check.disabled = status in ["pending", "ended"] or (not available and not enabled)
	match status:
		"connecting": _status.text = "正在连接…"
		"active": _status.text = "托管中"
		"pending": _status.text = "等待主机确认…"
		"error": _status.text = "连接失败，勾选重试"
		"ended": _status.text = "对局结束"
		_: _status.text = "手动控制" if available else "准备中…"
	var color := Color("e0d0a7")
	if status == "active": color = Color("c2e5ad")
	elif status == "error": color = Color("ffb195")
	_status.add_theme_color_override("font_color", color)
	var hint := "勾选后，外部 Python LLM 接管自己的队伍，负责探索、建设、生产和出兵。\n取消后恢复手动控制，丢弃后续 AI 指令；已执行的移动、建造和生产继续进行。"
	var game := get_node_or_null("/root/GameSession")
	if game != null and bool(game.get("online_active")):
		hint += "\n联机由主机运行并配置 Python AI 服务，双方只能开关自己的托管。"
	if not message.is_empty(): hint += "\n" + message
	_check.tooltip_text = hint
	_status.tooltip_text = message if not message.is_empty() else hint


func _on_toggled(enabled: bool) -> void:
	if is_instance_valid(_controller):
		_controller.call("request_local_enabled", enabled)
	# Render authoritative state, including a rejected or pending request.
	_sync_state()


func _sync_layout() -> void:
	if _panel == null:
		return
	_panel.position = Vector2(16, 36)
	_panel.size = Vector2(minf(440, maxf(280, size.x - 32)), 34)
