extends Control

const Loader := preload("res://scripts/world/map_loader.gd")
const Data := preload("res://scripts/world/map_data.gd")
const DefaultMap := preload("res://scripts/world/default_map_generator.gd")
const Preview := preload("res://scripts/ui/map_preview.gd")
const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const HttpClient := preload("res://scripts/ai_gateway/http_ai_client.gd")
const OnlineLobby := preload("res://scripts/ui/online_lobby.gd")
const MAIN_ART := preload("res://assets/ui/menu/main_background.jpg")
const SETUP_ART := preload("res://assets/ui/menu/setup_background.jpg")
const CIV_IDS := [&"chinese", &"teutons"]
var page := "main"
var map_paths: Array[String] = []
var selected_data: Dictionary = {}
var map_error := ""
var starting := false
var _design: Control
var _background: TextureRect
var _shade: ColorRect
var _main: Control
var _setup: Control
var _online: Control
var _map_choice: OptionButton
var _player_choice: OptionButton
var _enemy_choice: OptionButton
var _ai_choice: OptionButton
var _preview: Control
var _map_info: Label
var _civ_info: Label
var _status: Label
var _main_status: Label
var _start: Button
var _file: FileDialog
var _advanced: AcceptDialog
var _ai_url_edit: LineEdit
var _ai_token_edit: LineEdit
var _embedded_check: CheckBox
var _busy: Control

func _ready() -> void:
	var return_to_lobby := GameSession.online_return_to_lobby
	GameSession.online_return_to_lobby = false
	_reset_online_session()
	_build_ui()
	_refresh_maps()
	show_main()
	if return_to_lobby:
		_multiplayer_pressed()
	if not GameSession.menu_notice.is_empty():
		if return_to_lobby:
			_online.show_status(GameSession.menu_notice)
		else:
			_main_status.text = GameSession.menu_notice
		GameSession.menu_notice = ""
	resized.connect(_layout)
	_layout()

func _layout() -> void:
	var factor := minf(size.x / 1280.0, size.y / 720.0)
	_design.scale = Vector2.ONE * factor
	_design.position = (size - Vector2(1280, 720) * factor) * 0.5

func _rect(node: Control, parent: Node, name: String, rect: Rect2) -> Control:
	node.name = name
	parent.add_child(node)
	node.position = rect.position
	node.size = rect.size
	return node

func _label(parent: Node, name: String, text: String, rect: Rect2, font_size := 18, light := false) -> Label:
	var label := _rect(Label.new(), parent, name, rect) as Label
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color("e9d6a6") if light else Color("372416"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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

func _button(parent: Node, name: String, text: String, rect: Rect2, action: Callable) -> Button:
	var button := _rect(Button.new(), parent, name, rect) as Button
	button.text = text
	_style(button)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(action)
	return button

func _choice(parent: Node, name: String, rect: Rect2, items: Array) -> OptionButton:
	var choice := _rect(OptionButton.new(), parent, name, rect) as OptionButton
	_style(choice)
	choice.fit_to_longest_item = false
	choice.clip_text = true
	for item in items:
		choice.add_item(item)
	return choice

func _build_ui() -> void:
	var base := ColorRect.new()
	base.color = Color("161411")
	add_child(base)
	base.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_design = _rect(Control.new(), self, "Design", Rect2(0, 0, 1280, 720))
	_background = _rect(TextureRect.new(), _design, "Background", Rect2(0, 0, 1280, 720)) as TextureRect
	_background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_background.stretch_mode = TextureRect.STRETCH_SCALE
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade = _rect(ColorRect.new(), _design, "Shade", Rect2(0, 0, 1280, 720)) as ColorRect
	_shade.color = Color(0.02, 0.01, 0, 0.42)
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_main = _rect(Control.new(), _design, "MainPage", Rect2(0, 0, 1280, 720))
	_label(_main, "Brand", "帝国时代 II", Rect2(100, 70, 570, 84), 52, true)
	_label(_main, "Subtitle", "AGE OF EMPIRES  ·  即时战略", Rect2(104, 150, 570, 36), 19, true)
	var panel := _rect(Panel.new(), _main, "MenuPanel", Rect2(725, 175, 430, 416)) as Panel
	var skin := StyleBoxFlat.new()
	skin.bg_color = Color(0.10, 0.075, 0.045, 0.95)
	skin.border_color = Color("947443")
	skin.set_border_width_all(2)
	panel.add_theme_stylebox_override("panel", skin)
	_label(panel, "Heading", "开始你的征程", Rect2(38, 25, 350, 40), 26, true)
	_button(panel, "SinglePlayer", "单机游戏", Rect2(38, 92, 354, 62), show_single_player)
	_button(panel, "Multiplayer", "联机对战", Rect2(38, 170, 354, 62), _multiplayer_pressed)
	_main_status = _label(panel, "Status", "选择单机游戏，或联机匹配另一位玩家。", Rect2(38, 250, 354, 76), 15, true)
	_button(panel, "MapEditor", "地图编辑器", Rect2(38, 338, 169, 42), func(): get_tree().change_scene_to_file("res://scenes/editor/map_editor.tscn"))
	_button(panel, "Quit", "退出游戏", Rect2(223, 338, 169, 42), func(): get_tree().quit())
	_button(_main, "CombatArena", "战斗测试场", Rect2(100, 634, 150, 40), func(): get_tree().change_scene_to_file("res://scenes/combat_arena.tscn"))
	_button(_main, "PathArena", "寻路测试场", Rect2(268, 634, 150, 40), func(): get_tree().change_scene_to_file("res://scenes/pathfinding_arena.tscn"))
	_setup = _rect(Control.new(), _design, "SinglePlayerPage", Rect2(0, 0, 1280, 720))
	_label(_setup, "Title", "单机游戏", Rect2(215, 40, 525, 58), 34)
	_label(_setup, "MapTitle", "地图", Rect2(215, 108, 400, 28), 19)
	_map_choice = _choice(_setup, "MapChoice", Rect2(215, 146, 394, 44), [])
	_map_choice.item_selected.connect(_map_selected)
	_button(_setup, "ImportMap", "导入地图…", Rect2(621, 146, 126, 44), _open_map)
	_preview = _rect(Preview.new(), _setup, "MapPreview", Rect2(215, 207, 532, 220))
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label(_setup, "Legend", "蓝色 · 玩家    红色 · 对手    绿色 / 金色 · 资源", Rect2(235, 437, 505, 26), 14)
	_map_info = _label(_setup, "MapInfo", "", Rect2(215, 478, 528, 87), 17)
	_map_info.mouse_filter = Control.MOUSE_FILTER_PASS
	_label(_setup, "PlayerTitle", "玩家文明", Rect2(799, 108, 250, 28), 19)
	_player_choice = _choice(_setup, "PlayerCiv", Rect2(799, 146, 270, 44), ["中国", "条顿"])
	_player_choice.select(1 if GameSession.player_civ_id == &"teutons" else 0)
	_player_choice.item_selected.connect(func(_index): _update_civ_description())
	_civ_info = _label(_setup, "CivInfo", "", Rect2(799, 203, 270, 76), 14)
	_label(_setup, "EnemyTitle", "对手文明", Rect2(799, 292, 270, 28), 19)
	_enemy_choice = _choice(_setup, "EnemyCiv", Rect2(799, 330, 270, 44), ["中国", "条顿"])
	_enemy_choice.select(1 if GameSession.ai_civ_id == &"teutons" else 0)
	_enemy_choice.item_selected.connect(func(_index): _refresh_default_preview())
	_label(_setup, "AiTitle", "对手控制", Rect2(799, 399, 270, 28), 19)
	_ai_choice = _choice(_setup, "AiMode", Rect2(799, 437, 270, 44), ["本地 AI", "沙盒 · 对手不自动行动", "外部 AI 服务"])
	_ai_choice.add_theme_font_size_override("font_size", 16)
	_ai_choice.item_selected.connect(func(index): get_node("Design/SinglePlayerPage/AiSettings").visible = index == 2)
	var advanced_button := _button(_setup, "AiSettings", "AI 服务设置…", Rect2(799, 500, 270, 40), func(): _advanced.popup_centered(Vector2i(560, 285)))
	advanced_button.visible = false
	_status = _label(_setup, "SetupStatus", "", Rect2(215, 575, 850, 47), 15)
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	_status.max_lines_visible = 2
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_button(_setup, "Back", "返回主菜单", Rect2(215, 640, 168, 48), show_main)
	_start = _button(_setup, "Start", "开始游戏", Rect2(848, 632, 221, 58), _start_game)
	_file = FileDialog.new()
	_file.name = "MapFileDialog"
	_file.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file.access = FileDialog.ACCESS_FILESYSTEM
	_file.filters = PackedStringArray(["*.json ; 地图文件"])
	_file.title = "选择保存的地图"
	_file.file_selected.connect(select_map_file)
	add_child(_file)
	_advanced = AcceptDialog.new()
	_advanced.name = "AiSettingsDialog"
	_advanced.title = "外部 AI 服务"
	_advanced.ok_button_text = "确定"
	add_child(_advanced)
	var options := VBoxContainer.new()
	options.add_theme_constant_override("separation", 14)
	_advanced.add_child(options)
	var intro := Label.new()
	intro.text = "单机默认使用本地 AI；此设置仅用于外部 AI 服务。"
	options.add_child(intro)
	_ai_url_edit = LineEdit.new()
	_ai_url_edit.placeholder_text = "http://127.0.0.1:8765"
	_ai_url_edit.text = GameSession.ai_service_url
	options.add_child(_ai_url_edit)
	_ai_token_edit = LineEdit.new()
	_ai_token_edit.placeholder_text = "API Token（可选）"
	_ai_token_edit.secret = true
	_ai_token_edit.text = GameSession.ai_service_token
	options.add_child(_ai_token_edit)
	_embedded_check = CheckBox.new()
	_embedded_check.text = "连接失败时允许使用内嵌 AI 服务"
	_embedded_check.button_pressed = GameSession.ai_use_local_embedded
	options.add_child(_embedded_check)
	_online = _rect(OnlineLobby.new(), _design, "OnlinePage", Rect2(0, 0, 1280, 720))
	_online.back_requested.connect(show_main)
	_busy = _rect(Control.new(), _design, "BusyBlocker", Rect2(0, 0, 1280, 720))
	_busy.mouse_filter = Control.MOUSE_FILTER_STOP
	_busy.visible = false
	_update_civ_description()

func show_main() -> void:
	if starting: return
	page = "main"
	_main.show()
	_setup.hide()
	_online.hide()
	_background.texture = MAIN_ART
	_shade.show()

func show_single_player() -> void:
	if starting: return
	_reset_online_session()
	page = "single"
	_main.hide()
	_online.hide()
	_setup.show()
	_background.texture = SETUP_ART
	_shade.hide()
	_refresh_maps()
	_start.grab_focus()

func _multiplayer_pressed() -> void:
	if starting: return
	page = "online"
	_main.hide()
	_setup.hide()
	_online.show()
	_background.texture = SETUP_ART
	_shade.hide()
	_online.focus_start()

func _reset_online_session() -> void:
	var network := get_node_or_null("/root/NetworkSession")
	if network != null and network.state != "idle":
		network.leave()
	GameSession.online_active = false
	GameSession.online_team = 0

func _update_civ_description() -> void:
	_civ_info.text = "诸葛弩 · 经济发展\n村民训练更快；默认地图额外一名村民。" if _player_choice.selected == 0 else "条顿武士 · 坚实防御\n建筑生命值提高，近战单位护甲增加。"
	_refresh_default_preview()

func _refresh_default_preview() -> void:
	if _preview == null or _enemy_choice == null or _map_choice.selected < 0 or not map_paths[_map_choice.selected].is_empty(): return
	_preview.show_map(DefaultMap.generate(DefaultMap.DEFAULT_SEED, CIV_IDS[_player_choice.selected], CIV_IDS[_enemy_choice.selected]))

func _refresh_maps() -> void:
	var previous := map_paths[_map_choice.selected] if _map_choice.selected >= 0 and _map_choice.selected < map_paths.size() else GameSession.selected_map_path
	map_paths = ["", "res://data/maps/editor_demo.json"]
	_map_choice.clear()
	_map_choice.add_item("经典双营地 · 120 × 120 原版格")
	_map_choice.add_item("双阵营营地 · 编辑示例")
	DirAccess.make_dir_recursive_absolute("user://maps")
	var directory := DirAccess.open("user://maps")
	if directory != null:
		for file in directory.get_files():
			if file.get_extension().to_lower() == "json":
				map_paths.append("user://maps/" + file)
				_map_choice.add_item(file.get_basename())
	if not previous.is_empty() and not map_paths.has(previous):
		map_paths.append(previous)
		_map_choice.add_item(previous.get_file().get_basename())
	var index := maxi(map_paths.find(previous), 0)
	_map_choice.select(index)
	_map_selected(index)

func _open_map() -> void:
	_file.current_dir = ProjectSettings.globalize_path("user://maps")
	_file.popup_centered(Vector2i(850, 540))

func select_map_file(path: String) -> void:
	if not map_paths.has(path):
		map_paths.append(path)
		_map_choice.add_item(path.get_file().get_basename())
	_map_choice.select(map_paths.find(path))
	_map_selected(_map_choice.selected)

func _read_selected_map() -> bool:
	map_error = ""
	selected_data = {}
	var path := map_paths[_map_choice.selected]
	if path.is_empty(): return true
	var result := Loader.load_file(path)
	if result.has("error"):
		map_error = result.error
		return false
	selected_data = result.data
	var playable := false
	for record in selected_data.entities:
		playable = playable or record.get("team") == "player"
	if not playable:
		map_error = "地图需要至少一个玩家单位或建筑。请先在地图编辑器中放置。"
		return false
	return true

func _map_selected(_index: int) -> void:
	var valid := _read_selected_map()
	_start.disabled = not valid
	_status.text = map_error
	_map_info.tooltip_text = ""
	_status.tooltip_text = map_error
	_map_choice.tooltip_text = map_paths[_map_choice.selected]
	_status.add_theme_color_override("font_color", Color("872c20"))
	if not valid:
		_preview.show_map({})
		_map_info.text = "地图不可用，请重新选择或修正文件。"
		return
	if selected_data.is_empty():
		_refresh_default_preview()
		_map_info.text = "经典双营地  ·  120 × 120 原版格\n对应 480 × 480 游戏格，双方对称开局。\n多片森林、浆果群及主矿、次矿和中立矿。"
	else:
		_preview.show_map(selected_data)
		var bounds := Data.bounds(selected_data)
		var players := 0
		var enemies := 0
		for record in selected_data.entities:
			if record.get("team") == "player": players += 1
			if record.get("team") == "ai": enemies += 1
		var title: String = selected_data.display_name
		_map_info.tooltip_text = title
		if title.length() > 20: title = title.left(19) + "…"
		_map_info.text = "%s  ·  %d × %d\n玩家对象 %d    对手对象 %d    总对象 %d\n保留地图中的初始位置与数量。" % [title, bounds.size.x, bounds.size.y, players, enemies, selected_data.entities.size()]
		if enemies == 0:
			_status.text = "此地图没有对手对象，适合探索或沙盒练习。"
			_status.add_theme_color_override("font_color", Color("664721"))

func _start_game() -> void:
	if starting or page != "single": return
	_reset_online_session()
	# Revalidate immediately before launch; a saved file may have changed on disk.
	_map_selected(_map_choice.selected)
	if not map_error.is_empty(): return
	_set_starting(true)
	_status.text = "正在准备对局…"
	var config: AiConfig
	if _ai_choice.selected == 2:
		config = AiConfigScript.from_civ_select(_ai_url_edit.text, _embedded_check.button_pressed, _ai_token_edit.text, true)
		var client := HttpClient.new()
		add_child(client)
		client.configure(config)
		var health := await client.get_health()
		client.cancel_requests()
		client.queue_free()
		if health.get("ok") != true and not config.allows_embedded_fallback():
			_status.text = "AI 服务无法连接，请检查服务设置或改用本地 AI。"
			_set_starting(false)
			return
	GameSession.player_civ_id = CIV_IDS[_player_choice.selected]
	GameSession.ai_civ_id = CIV_IDS[_enemy_choice.selected]
	GameSession.match_map_data = selected_data.duplicate(true)
	GameSession.selected_map_path = map_paths[_map_choice.selected]
	GameSession.match_ai_mode = ["local", "sandbox", "gateway"][_ai_choice.selected]
	if config != null: config.save_to_game_session()
	var error := get_tree().change_scene_to_file("res://scenes/match_2d.tscn")
	if error != OK:
		_status.text = "无法进入对局：" + error_string(error)
		_set_starting(false)

func _set_starting(value: bool) -> void:
	starting = value
	_busy.visible = value
	# A mouse overlay alone does not block the focused control's keyboard input.
	for child in _setup.get_children():
		if child is BaseButton: child.disabled = value
	_start.disabled = value or not map_error.is_empty()
	if value: get_viewport().gui_release_focus()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE and not starting:
		if page == "single":
			show_main()
			get_viewport().set_input_as_handled()
		elif page == "online":
			_online.go_back()
			get_viewport().set_input_as_handled()
