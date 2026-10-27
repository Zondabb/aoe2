extends Control

signal back_requested

const CIV_IDS := [&"chinese", &"teutons"]
var _network: Node
var _server_url: LineEdit
var _nickname: LineEdit
var _civ: OptionButton
var _status: Label
var _start: Button
var _cancel: Button
var _back: Button
var _entering := false
var _browse_open := false
var _browse_button: Button
var _matches_panel: PanelContainer
var _matches_list: VBoxContainer
var _matches_notice: Label
var _last_refresh := -10000

func _ready() -> void:
	_build_ui()
	_network = get_node_or_null("/root/NetworkSession")
	if _network == null:
		show_status("联机组件未加载，请重新启动游戏。")
	else:
		_network.status_changed.connect(_on_status_changed)
		_network.matched.connect(_on_matched)
		_network.ended.connect(_on_ended)
		if _network.has_signal("matches_received"):
			_network.connect("matches_received", _on_matches_received)
	_refresh_controls()

func _label(node_name: String, text: String, rect: Rect2, font_size := 18) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color("372416"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _style(control: Control) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("4b3523") if state == "normal" else Color("765534") if state == "hover" else Color("30271f")
		box.border_color = Color("e4bf70") if state in ["hover", "focus"] else Color("a1834e")
		box.set_border_width_all(2 if state == "focus" else 1)
		box.set_content_margin_all(10)
		control.add_theme_stylebox_override(state, box)
	control.add_theme_color_override("font_color", Color("f6e6bd"))
	control.add_theme_color_override("font_hover_color", Color("fff2c9"))
	control.add_theme_font_size_override("font_size", 18)

func _button(node_name: String, text: String, rect: Rect2, action: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.position = rect.position
	button.size = rect.size
	_style(button)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(action)
	add_child(button)
	return button

func _edit(node_name: String, text: String, rect: Rect2, max_chars: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.name = node_name
	edit.text = text
	edit.max_length = max_chars
	edit.position = rect.position
	edit.size = rect.size
	_style(edit)
	add_child(edit)
	return edit

func _build_ui() -> void:
	_label("Title", "联机对战", Rect2(215, 40, 700, 58), 34)
	_label("Description", "1 对 1 即时对战 · 默认双营地\n双方连接同一服务后自动配对，匹配成功后进入战场。", Rect2(215, 106, 850, 64), 19)
	_label("ServerTitle", "联机服务地址", Rect2(215, 197, 520, 30))
	_server_url = _edit("ServerUrl", GameSession.online_server_url, Rect2(215, 235, 850, 48), 2048)
	_server_url.placeholder_text = "ws://127.0.0.1:8001/ws"
	_server_url.tooltip_text = "默认地址来自 game_settings.cfg 的 [multiplayer] 配置；也可临时填写服务器的 ws:// 或 wss:// 地址。"
	_label("NicknameTitle", "玩家昵称", Rect2(215, 311, 500, 30))
	_nickname = _edit("Nickname", GameSession.online_player_name, Rect2(215, 350, 490, 48), 24)
	_nickname.placeholder_text = "输入昵称（最多 24 个字符）"
	_label("CivTitle", "你的文明", Rect2(755, 311, 310, 30))
	_civ = OptionButton.new()
	_civ.name = "Civilization"
	_civ.position = Vector2(755, 350)
	_civ.size = Vector2(310, 48)
	_civ.add_item("中国")
	_civ.add_item("条顿")
	_civ.select(1 if GameSession.online_civ_id == &"teutons" else 0)
	_style(_civ)
	add_child(_civ)
	_label("MapInfo", "地图：经典双营地 · 480 × 480（原版双人尺寸）\n双方各控制一个阵营；离开对局或连接中断将结束本局。", Rect2(215, 432, 850, 64), 17)
	_status = _label("Status", "准备就绪，点击开始匹配。", Rect2(215, 528, 850, 83), 18)
	_back = _button("Back", "返回主菜单", Rect2(215, 640, 168, 48), go_back)
	_cancel = _button("Cancel", "取消匹配", Rect2(648, 640, 180, 48), cancel_matchmaking)
	_start = _button("Start", "开始匹配", Rect2(848, 632, 221, 58), start_matchmaking)
	_browse_button = _button("BrowseMatches", "观看对战", Rect2(408, 640, 218, 48), _toggle_browse)
	_build_matches_panel()
	_nickname.text_submitted.connect(func(_text: String): start_matchmaking())
	_server_url.text_submitted.connect(func(_text: String): _nickname.grab_focus())

func _build_matches_panel() -> void:
	_matches_panel = PanelContainer.new()
	_matches_panel.name = "LiveMatches"
	_matches_panel.position = Vector2(215, 305)
	_matches_panel.size = Vector2(850, 210)
	var skin := StyleBoxFlat.new()
	skin.bg_color = Color("2f251d")
	skin.border_color = Color("a1834e")
	skin.set_border_width_all(1)
	skin.set_content_margin_all(10)
	_matches_panel.add_theme_stylebox_override("panel", skin)
	add_child(_matches_panel)
	var contents := VBoxContainer.new()
	_matches_panel.add_child(contents)
	var header := HBoxContainer.new()
	contents.add_child(header)
	_matches_notice = Label.new()
	_matches_notice.text = "正在进行的对局"
	_matches_notice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_matches_notice)
	var refresh := Button.new()
	refresh.name = "RefreshMatches"
	refresh.text = "刷新"
	refresh.pressed.connect(refresh_matches)
	header.add_child(refresh)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	contents.add_child(scroll)
	_matches_list = VBoxContainer.new()
	_matches_list.name = "MatchList"
	_matches_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_matches_list)
	_matches_panel.hide()

func _process(_delta: float) -> void:
	if _browse_open and is_visible_in_tree() and not _entering and Time.get_ticks_msec() - _last_refresh >= 5000:
		refresh_matches()

func _toggle_browse() -> void:
	if _entering or (_network != null and _network.state not in ["idle", "browsing"]): return
	_browse_open = not _browse_open
	if not _browse_open and _network != null and _network.state == "browsing": _network.leave()
	_refresh_controls()
	if _browse_open: refresh_matches()

func refresh_matches() -> void:
	if _network == null or not _network.has_method("request_matches") or _entering: return
	if _network.state not in ["idle", "browsing"]: return
	_last_refresh = Time.get_ticks_msec()
	var url := _server_url.text.strip_edges()
	GameSession.online_server_url = url
	var error: Error = _network.call("request_matches", url)
	if error != OK: show_status("无法获取对局列表：" + error_string(error))

func _on_matches_received(matches: Array) -> void:
	for child in _matches_list.get_children():
		_matches_list.remove_child(child)
		child.queue_free()
	_matches_notice.text = "暂无正在进行的对局" if matches.is_empty() else "正在进行的对局（%d）" % matches.size()
	for entry in matches:
		if entry is not Dictionary or entry.get("match_id") is not String: continue
		var names: Array[String] = ["队伍 1", "队伍 2"]
		for player in entry.get("players", []):
			if player is Dictionary:
				var team := _wire_team(player.get("team"))
				if team >= 0: names[team] = String(player.get("name", "玩家"))
		var row := HBoxContainer.new()
		row.name = "Match_" + String(entry.match_id)
		_matches_list.add_child(row)
		var title := Label.new()
		title.text = "%s  对战  %s" % names
		title.tooltip_text = title.text
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(title)
		var info := Label.new()
		var elapsed := maxi(0, int(entry.get("elapsed_seconds", 0)))
		info.text = "%02d:%02d · %d 人观战" % [elapsed / 60, elapsed % 60, int(entry.get("spectator_count", 0))]
		info.add_theme_font_size_override("font_size", 14)
		row.add_child(info)
		var watch := Button.new()
		watch.name = "Watch"
		watch.text = "观战"
		watch.pressed.connect(_watch_match.bind(String(entry.match_id)))
		row.add_child(watch)
	show_status("选择对局进入只读观战，可切换双方视角或查看全图。列表每 5 秒刷新。")
	_refresh_controls()

func _watch_match(match_id: String) -> void:
	if _network == null or _entering or not _network.has_method("watch_match"): return
	var error: Error = _network.call("watch_match", _server_url.text.strip_edges(), match_id)
	if error != OK: show_status("无法加入观战：" + error_string(error))
	_refresh_controls()

func focus_start() -> void:
	_refresh_controls()
	if not _start.disabled:
		_start.grab_focus()

func show_status(message: String) -> void:
	_status.text = message
	_status.tooltip_text = message

func start_matchmaking() -> void:
	if _network == null or _network.state not in ["idle", "browsing"] or _entering:
		return
	var url := _server_url.text.strip_edges()
	var player_name := _nickname.text.strip_edges()
	if not (url.begins_with("ws://") or url.begins_with("wss://")):
		show_status("服务地址必须以 ws:// 或 wss:// 开头，例如 ws://127.0.0.1:8001/ws。")
		_server_url.grab_focus()
		return
	if player_name.is_empty():
		show_status("请先输入玩家昵称。")
		_nickname.grab_focus()
		return
	GameSession.online_server_url = url
	GameSession.online_player_name = player_name
	GameSession.online_civ_id = CIV_IDS[_civ.selected]
	var error: Error = _network.join_queue(url, player_name, str(GameSession.online_civ_id))
	if error != OK:
		show_status("无法连接联机服务：" + error_string(error))
	_refresh_controls()

func cancel_matchmaking() -> void:
	if _network == null or _entering:
		return
	_network.cancel_queue()
	_refresh_controls()

func go_back() -> void:
	if _entering:
		return
	if _network != null:
		_network.leave()
	GameSession.online_active = false
	GameSession.online_spectator = false
	_refresh_controls()
	back_requested.emit()

func _refresh_controls() -> void:
	var busy: bool = _entering or (_network != null and _network.state not in ["idle", "browsing"])
	_server_url.editable = not busy
	_nickname.editable = not busy
	_civ.disabled = busy
	_start.disabled = busy or _network == null
	_cancel.disabled = not busy or _entering
	_back.disabled = _entering
	_browse_button.disabled = busy
	_browse_button.text = "返回匹配" if _browse_open else "观看对战"
	get_node("Title").text = "联机观战" if _browse_open else "联机对战"
	get_node("Description").text = "选择正在进行的对局，点击观战进入战场。\n可切换双方视角或查看全图，不能控制任何单位。" if _browse_open else "1 对 1 即时对战 · 默认双营地\n双方连接同一服务后自动配对，匹配成功后进入战场。"
	_matches_panel.visible = _browse_open
	for child_name in ["NicknameTitle", "Nickname", "CivTitle", "Civilization", "MapInfo"]:
		get_node(child_name).visible = not _browse_open
	_start.visible = not _browse_open
	_cancel.visible = not _browse_open
	for row in _matches_list.get_children():
		var watch := row.get_node_or_null("Watch") as Button
		if watch != null: watch.disabled = busy
	if busy:
		get_viewport().gui_release_focus()

func _on_status_changed(message: String) -> void:
	show_status(message)
	_refresh_controls()

func _on_ended(info: Dictionary) -> void:
	if _entering:
		return
	GameSession.online_active = false
	show_status(str(info.get("message", "对局连接已结束，可重新匹配。")))
	_refresh_controls()

func _on_matched(info: Dictionary) -> void:
	if _entering or not is_visible_in_tree():
		return
	if not _configure_match(info):
		_network.leave()
		show_status("匹配信息不完整，请重试。")
		_refresh_controls()
		return
	_entering = true
	show_status("正在进入观战…" if GameSession.online_spectator else "匹配成功，正在进入战场…")
	_refresh_controls()
	var error := get_tree().change_scene_to_file("res://scenes/match_2d.tscn")
	if error != OK:
		_entering = false
		GameSession.online_active = false
		GameSession.online_spectator = false
		_network.leave()
		show_status("无法进入对局：" + error_string(error))
		_refresh_controls()

func _configure_match(info: Dictionary) -> bool:
	# Resolve by world team, not arrival order or this client's local perspective.
	var players: Variant = info.get("players", [])
	if players is not Array or players.size() != 2:
		return false
	var civilizations := {}
	for player in players:
		if player is Dictionary:
			var side := _wire_team(player.get("team"))
			if side < 0: return false
			civilizations[side] = StringName(str(player.get("civ", "")))
	var team := _wire_team(info.get("team"))
	var spectator: bool = info.get("role", "player") == "spectator"
	if (not spectator and team not in [0, 1]) or civilizations.size() != 2 or civilizations.get(0) not in CIV_IDS or civilizations.get(1) not in CIV_IDS:
		return false
	GameSession.online_active = true
	GameSession.online_spectator = spectator
	GameSession.online_team = -1 if spectator else team
	GameSession.player_civ_id = civilizations[0]
	GameSession.ai_civ_id = civilizations[1]
	GameSession.match_map_data = {}
	GameSession.match_ai_mode = "sandbox"
	return true

func _wire_team(value: Variant) -> int:
	if value is not int and value is not float: return -1
	if not is_finite(float(value)) or float(value) != floor(float(value)): return -1
	var team := int(value)
	return team if team in [0, 1] else -1
