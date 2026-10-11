extends ConfirmationDialog
## Shared named-slot picker for the main menu and the running match.

signal save_requested(path: String)
signal load_requested(path: String)

const SaveService := preload("res://scripts/core/save_game_service.gd")
const SAVE_DIRECTORY := "user://saves"

var saving := false
var _paths: Array[String] = []
var _list: ItemList
var _name: LineEdit
var _name_row: HBoxContainer
var _message: Label
var _intro: Label

func _ready() -> void:
	name = "SaveGameDialog"
	process_mode = Node.PROCESS_MODE_ALWAYS
	dialog_hide_on_ok = false
	cancel_button_text = "取消"
	min_size = Vector2i(520, 350)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	add_child(column)
	_intro = Label.new()
	_intro.custom_minimum_size = Vector2(480, 40)
	_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro.max_lines_visible = 2
	column.add_child(_intro)
	_list = ItemList.new()
	_list.name = "SaveSlots"
	_list.custom_minimum_size = Vector2(480, 180)
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_slot_selected)
	_list.item_activated.connect(func(index: int):
		_slot_selected(index)
		if not saving: _submit())
	column.add_child(_list)
	_name_row = HBoxContainer.new()
	column.add_child(_name_row)
	var caption := Label.new()
	caption.text = "存档名称"
	_name_row.add_child(caption)
	_name = LineEdit.new()
	_name.name = "SlotName"
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.max_length = 80
	_name.text_changed.connect(func(_value: String): _refresh_action())
	_name.text_submitted.connect(func(_value: String): _submit())
	_name_row.add_child(_name)
	_message = Label.new()
	_message.name = "SaveError"
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.max_lines_visible = 2
	_message.custom_minimum_size = Vector2(480, 42)
	_message.add_theme_color_override("font_color", Color("efbd83"))
	column.add_child(_message)
	confirmed.connect(_submit)

func open_slots(save_mode: bool) -> void:
	saving = save_mode
	title = "保存单机游戏" if saving else "读取单机存档"
	_intro.text = "输入名称创建存档，或选中已有存档进行覆盖。" if saving else "选择要恢复的存档。读取后将继续该存档中的对局。"
	_name_row.visible = saving
	_message.text = ""
	_paths.clear()
	_list.clear()
	var directory := DirAccess.open(SAVE_DIRECTORY)
	if directory != null:
		for file in directory.get_files():
			if file.get_extension().to_lower() == "json":
				_paths.append(SAVE_DIRECTORY.path_join(file))
	_paths.sort_custom(func(a: String, b: String): return FileAccess.get_modified_time(a) > FileAccess.get_modified_time(b))
	for path in _paths:
		var label := "快速存档" if path == SaveService.DEFAULT_SAVE_PATH else path.get_file().get_basename()
		var local_timestamp := FileAccess.get_modified_time(path) + int(Time.get_time_zone_from_system().bias) * 60
		var timestamp := Time.get_datetime_string_from_unix_time(local_timestamp).replace("T", " ")
		_list.add_item(label + "    ·    " + timestamp)
		_list.set_item_tooltip(_list.item_count - 1, ProjectSettings.globalize_path(path))
	if saving:
		_name.text = "存档 " + Time.get_datetime_string_from_system().replace("T", " ").replace(":", "-")
	elif not _paths.is_empty():
		_list.select(0)
	if _paths.is_empty() and not saving:
		_message.text = "还没有单机存档。请先在游戏中点击“保存游戏”。"
	_refresh_action()
	popup_centered(Vector2i(580, 400))
	if saving:
		_name.grab_focus()
		_name.select_all()
	else:
		_list.grab_focus()

func show_error(message: String) -> void:
	_message.text = message
	_message.tooltip_text = message

func _slot_selected(index: int) -> void:
	if index < 0 or index >= _paths.size(): return
	_message.text = ""
	if saving: _name.text = _paths[index].get_file().get_basename()
	_refresh_action()

func _valid_name() -> bool:
	var slot := _name.text.strip_edges()
	if slot.is_empty() or slot in [".", ".."] or slot.ends_with("."): return false
	for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		if slot.contains(character): return false
	return true

func _refresh_action() -> void:
	if saving:
		get_ok_button().disabled = not _valid_name()
		var path := SAVE_DIRECTORY.path_join(_name.text.strip_edges() + ".json")
		get_ok_button().text = "覆盖存档" if FileAccess.file_exists(path) else "保存游戏"
	else:
		get_ok_button().text = "读取存档"
		get_ok_button().disabled = _list.get_selected_items().is_empty()

func _submit() -> void:
	if saving:
		if not _valid_name():
			show_error("请输入有效的存档名称，不要使用路径或特殊符号。")
			return
		save_requested.emit(SAVE_DIRECTORY.path_join(_name.text.strip_edges() + ".json"))
	else:
		var selected := _list.get_selected_items()
		if not selected.is_empty(): load_requested.emit(_paths[selected[0]])
