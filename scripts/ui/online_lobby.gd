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

func _ready() -> void:
	_build_ui()
	_network = get_node_or_null("/root/NetworkSession")
	if _network == null:
		show_status("联机组件未加载，请重新启动游戏。")
	else:
		_network.status_changed.connect(_on_status_changed)
		_network.matched.connect(_on_matched)
		_network.ended.connect(_on_ended)
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
	_nickname.text_submitted.connect(func(_text: String): start_matchmaking())
	_server_url.text_submitted.connect(func(_text: String): _nickname.grab_focus())

func focus_start() -> void:
	_refresh_controls()
	if not _start.disabled:
		_start.grab_focus()

func show_status(message: String) -> void:
	_status.text = message
	_status.tooltip_text = message

func start_matchmaking() -> void:
	if _network == null or _network.state != "idle" or _entering:
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
	_refresh_controls()
	back_requested.emit()

func _refresh_controls() -> void:
	var busy: bool = _entering or (_network != null and _network.state != "idle")
	_server_url.editable = not busy
	_nickname.editable = not busy
	_civ.disabled = busy
	_start.disabled = busy or _network == null
	_cancel.disabled = not busy or _entering
	_back.disabled = _entering
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
	show_status("匹配成功，正在进入战场…")
	_refresh_controls()
	var error := get_tree().change_scene_to_file("res://scenes/match_2d.tscn")
	if error != OK:
		_entering = false
		GameSession.online_active = false
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
			civilizations[int(player.get("team", -1))] = StringName(str(player.get("civ", "")))
	var team := int(info.get("team", -1))
	if team not in [0, 1] or civilizations.size() != 2 or civilizations.get(0) not in CIV_IDS or civilizations.get(1) not in CIV_IDS:
		return false
	GameSession.online_active = true
	GameSession.online_team = team
	GameSession.player_civ_id = civilizations[0]
	GameSession.ai_civ_id = civilizations[1]
	GameSession.match_map_data = {}
	GameSession.match_ai_mode = "sandbox"
	return true
