extends Control

const SaveService := preload("res://scripts/core/save_game_service.gd")
const SaveDialog := preload("res://scripts/ui/save_game_dialog.gd")

var _dialog
var _return_dialog: ConfirmationDialog
var _notice: Label
var _notice_time := 0.0
var _paused_for_dialog := false
var _previous_pause := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if GameSession.online_active:
		hide()
		set_process(false)
		set_process_unhandled_key_input(false)
		return
	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	add_child(buttons)
	buttons.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	buttons.offset_left = -278
	buttons.offset_top = 3
	buttons.offset_right = -8
	buttons.offset_bottom = 32
	buttons.add_theme_constant_override("separation", 6)
	_add_button(buttons, "SaveButton", "保存游戏", open_save, "保存当前单机对局；F5 快速存档")
	_add_button(buttons, "LoadButton", "读取存档", open_load, "从单机存档恢复游戏；F9 打开读档")
	_add_button(buttons, "MenuButton", "主菜单", _open_return, "返回主菜单")
	_notice = Label.new()
	_notice.name = "SaveNotice"
	add_child(_notice)
	_notice.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_notice.offset_left = -510
	_notice.offset_top = 38
	_notice.offset_right = -8
	_notice.offset_bottom = 70
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.add_theme_color_override("font_outline_color", Color.BLACK)
	_notice.add_theme_constant_override("outline_size", 5)
	_notice.add_theme_font_size_override("font_size", 16)
	_dialog = SaveDialog.new()
	add_child(_dialog)
	_dialog.save_requested.connect(_save)
	_dialog.load_requested.connect(_load)
	_dialog.visibility_changed.connect(func():
		if not _dialog.visible: _release_pause())
	_return_dialog = ConfirmationDialog.new()
	_return_dialog.title = "返回主菜单"
	_return_dialog.dialog_text = "返回主菜单前，请确认已保存当前游戏。"
	_return_dialog.ok_button_text = "返回主菜单"
	_return_dialog.cancel_button_text = "继续游戏"
	_return_dialog.confirmed.connect(_return_to_menu)
	_return_dialog.visibility_changed.connect(func():
		if not _return_dialog.visible: _release_pause())
	add_child(_return_dialog)

func _add_button(parent: Node, node_name: String, caption: String, action: Callable, hint: String) -> void:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.custom_minimum_size = Vector2(82, 29)
	button.add_theme_font_size_override("font_size", 14)
	button.tooltip_text = hint
	button.pressed.connect(action)
	parent.add_child(button)

func _bootstrap() -> Node:
	return get_node_or_null("../../Bootstrap")

func open_save() -> void:
	if GameSession.online_active or _bootstrap() == null or _dialog.visible or _return_dialog.visible: return
	_pause_for_dialog()
	_dialog.open_slots(true)

func open_load() -> void:
	if GameSession.online_active or _dialog.visible or _return_dialog.visible: return
	_pause_for_dialog()
	_dialog.open_slots(false)

func _save(path: String) -> void:
	var error := SaveService.save(_bootstrap(), path)
	if not error.is_empty():
		_dialog.show_error(error)
		_show_notice(error, true)
		return
	_dialog.hide()
	_show_notice("游戏已保存：" + ("快速存档" if path == SaveService.DEFAULT_SAVE_PATH else path.get_file().get_basename()))

func _load(path: String) -> void:
	var error := SaveService.prepare_load(path)
	if not error.is_empty():
		_dialog.show_error(error)
		return
	_release_pause()
	var scene_error := get_tree().change_scene_to_file("res://scenes/match_2d.tscn")
	if scene_error != OK:
		GameSession.pending_save_data = {}
		_pause_for_dialog()
		_dialog.show_error("无法进入存档对局：" + error_string(scene_error))
	else:
		_dialog.hide()

func _open_return() -> void:
	if _dialog.visible or _return_dialog.visible: return
	_pause_for_dialog()
	_return_dialog.popup_centered()

func _return_to_menu() -> void:
	_release_pause()
	get_tree().change_scene_to_file("res://scenes/civ_select.tscn")

func _pause_for_dialog() -> void:
	if _paused_for_dialog: return
	_previous_pause = get_tree().paused
	_paused_for_dialog = true
	get_tree().paused = true

func _release_pause() -> void:
	if not _paused_for_dialog: return
	get_tree().paused = _previous_pause
	_paused_for_dialog = false

func _show_notice(message: String, failed := false) -> void:
	_notice.text = message
	_notice.tooltip_text = message
	_notice.add_theme_color_override("font_color", Color("ffab91") if failed else Color("f1d395"))
	_notice_time = 5.0

func _process(delta: float) -> void:
	if _notice_time <= 0.0: return
	_notice_time -= delta
	if _notice_time <= 0.0: _notice.text = ""

func _unhandled_key_input(event: InputEvent) -> void:
	if GameSession.online_active or _dialog == null or _dialog.visible or _return_dialog.visible: return
	if not event is InputEventKey or not event.pressed or event.echo: return
	if event.keycode == KEY_F5:
		_save(SaveService.DEFAULT_SAVE_PATH)
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_F9:
		open_load()
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	_release_pause()
