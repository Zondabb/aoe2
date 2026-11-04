extends Control

## The control belongs to the local player; the match controller owns authority.
var _controller: Node
var _panel: PanelContainer
var _check: CheckBox
var _follow: CheckBox
var _status: Label
var _service_button: Button
var _service_panel: PanelContainer
var _service_rows: Dictionary = {}
var _service_note: Label
var _route_message := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if get_node("/root/GameSession").get("online_spectator") == true:
		hide()
		set_process(false)
		return
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
	_follow = CheckBox.new()
	_follow.name = "BroadcastCamera"
	_follow.text = "自动运镜"
	_follow.tooltip_text = "优先展示视野内的交战，其次是建筑完工和新单位。方向键、小地图或滚轮可手动调整，7 秒后恢复。"
	_follow.add_theme_font_size_override("font_size", 14)
	_follow.button_pressed = true
	_follow.hide()
	_follow.toggled.connect(_on_follow_toggled)
	row.add_child(_follow)
	_service_button = Button.new()
	_service_button.name = "ServiceSettings"
	_service_button.text = "AI 地址"
	_service_button.toggle_mode = true
	_service_button.visible = false
	_service_button.toggled.connect(_on_service_panel_toggled)
	row.add_child(_service_button)
	_build_service_panel(style)
	resized.connect(_sync_layout)
	_sync_layout()
	call_deferred("_bind_controller")


func _build_service_panel(style: StyleBoxFlat) -> void:
	_service_panel = PanelContainer.new()
	_service_panel.name = "ServicePanel"
	_service_panel.visible = false
	_service_panel.add_theme_stylebox_override("panel", style.duplicate())
	add_child(_service_panel)
	var contents := VBoxContainer.new()
	contents.name = "Contents"
	contents.add_theme_constant_override("separation", 4)
	_service_panel.add_child(contents)
	for team in [0, 1]:
		var row := HBoxContainer.new()
		row.name = "Team%d" % team
		contents.add_child(row)
		var label := Label.new()
		label.text = "队伍 %d AI" % (team + 1)
		label.add_theme_font_size_override("font_size", 13)
		row.add_child(label)
		var address := LineEdit.new()
		address.name = "Address"
		address.placeholder_text = "http://127.0.0.1:8765"
		address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		address.custom_minimum_size.x = 80
		address.add_theme_font_size_override("font_size", 13)
		address.add_theme_color_override("font_uneditable_color", Color("e0d0a7"))
		address.text_submitted.connect(func(_value: String) -> void: _apply_service_url(team))
		row.add_child(address)
		var apply := Button.new()
		apply.name = "Apply"
		apply.text = "应用"
		apply.pressed.connect(_apply_service_url.bind(team))
		row.add_child(apply)
		var status := Label.new()
		status.name = "Team%dStatus" % team
		status.add_theme_font_size_override("font_size", 12)
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		contents.add_child(status)
		_service_rows[team] = {"row": row, "address": address, "apply": apply, "status": status}
	_service_note = Label.new()
	_service_note.name = "Note"
	_service_note.add_theme_font_size_override("font_size", 12)
	_service_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	contents.add_child(_service_note)


func _on_service_panel_toggled(open: bool) -> void:
	_service_panel.visible = open and _service_button.visible
	_sync_layout()


func _sync_service_settings(state: Dictionary) -> void:
	var game := get_node_or_null("/root/GameSession")
	var online := game != null and bool(game.get("online_active"))
	var local_team := int(game.call("local_team")) if game != null else 0
	var network := get_node_or_null("/root/NetworkSession")
	var host := not online or (network != null and network.has_method("is_host") and bool(network.call("is_host")))
	_service_button.visible = online and _controller.has_method("team_service_url")
	_service_panel.visible = _service_button.visible and _service_button.button_pressed
	var states: Dictionary = _controller.call("capture_states") if _controller.has_method("capture_states") else {}
	for team: int in _service_rows:
		var entry: Dictionary = _service_rows[team]
		entry.row.visible = host or team == local_team
		var address: LineEdit = entry.address
		address.editable = host and String(state.get("status", "")) != "ended"
		entry.apply.visible = host
		entry.apply.disabled = not address.editable
		var team_state: Dictionary = states.get(str(team), state if team == local_team else {})
		var team_status := String(team_state.get("status", "off"))
		var status_text := {"active": "托管中", "connecting": "正在连接…", "pending": "等待主机确认…", "error": "连接失败", "ended": "对局结束"}
		entry.status.text = String(status_text.get(team_status, "手动控制"))
		if team_status == "error":
			entry.status.text = String(team_state.get("message", "连接失败，请检查 Python 服务"))
		entry.status.visible = entry.row.visible
		entry.status.add_theme_color_override("font_color", Color("ffb195") if team_status == "error" else Color("e0d0a7"))
		if _controller.has_method("team_service_url"):
			var actual := String(_controller.call("team_service_url", team))
			# Preserve unsubmitted edits while state updates arrive from the AI.
			if not host or (not address.has_focus() and not bool(address.get_meta("dirty", false))):
				address.text = actual
			address.tooltip_text = "当前服务：" + actual
		if not address.text_changed.is_connected(_on_address_edited.bind(team)):
			address.text_changed.connect(_on_address_edited.bind(team))
	var note := "地址从主机访问；127.0.0.1 指主机。应用后会重新连接该队 AI。" if host else "由主机配置 AI 服务；此处显示自己队伍的实际地址。"
	_service_note.text = note + ("\n" + _route_message if not _route_message.is_empty() else "")
	# Hiding the other team's row on a guest also shrinks the panel's height.
	call_deferred("_sync_layout")


func _on_address_edited(_text: String, team: int) -> void:
	_service_rows[team].address.set_meta("dirty", true)


func _apply_service_url(team: int) -> void:
	if not is_instance_valid(_controller) or not _controller.has_method("request_team_service_url"):
		return
	var entry: Dictionary = _service_rows[team]
	var accepted := bool(_controller.call("request_team_service_url", team, String(entry.address.text)))
	_route_message = "地址已应用。" if accepted else "地址无效或无权修改；请输入 http:// 或 https:// 服务地址。"
	if accepted:
		entry.address.set_meta("dirty", false)
		entry.address.text = String(_controller.call("team_service_url", team))
	_sync_state()


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
	_follow.visible = enabled and status == "active" and has_node("../../Camera2D/BroadcastDirector")
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
	_sync_service_settings(state)


func _on_toggled(enabled: bool) -> void:
	if is_instance_valid(_controller):
		_controller.call("request_local_enabled", enabled)
	# Render authoritative state, including a rejected or pending request.
	_sync_state()

func _on_follow_toggled(enabled: bool) -> void:
	var director := get_node_or_null("../../Camera2D/BroadcastDirector")
	if director != null:
		director.set_follow_enabled(enabled)


func _sync_layout() -> void:
	if _panel == null:
		return
	_panel.position = Vector2(16, 36)
	_panel.size = Vector2(minf(440, maxf(280, size.x - 32)), 34)
	if _service_panel != null:
		_service_panel.position = Vector2(16, 74)
		_service_panel.size = Vector2(_panel.size.x, 0)
