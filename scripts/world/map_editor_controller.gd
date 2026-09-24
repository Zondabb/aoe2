extends Node2D

const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
const Document := preload("res://scripts/world/map_document.gd")
const NavHolder := preload("res://scripts/systems/nav_service_holder.gd")
const VisionHolder := preload("res://scripts/systems/vision_service_holder.gd")
const CombatDirector := preload("res://scripts/systems/auto_combat_director.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const SAVE_DIRECTORY := "user://maps"
const EXAMPLE := "res://data/maps/editor_demo.json"
enum Tool { SELECT, PLACE, ERASE }

var document := Document.new()
var entities: Node2D
var camera: Camera2D
var state: MatchState
var playing := false
var tool := Tool.PLACE
var selected_id := ""
var _selected_runtime: Node2D
var _ground: Node2D
var _nav: NavHolder
var _vision: VisionHolder
var _combat := CombatDirector.new()
var _nodes := {}
var _kind := "building"
var _brush_id := "town_center"
var _panning := false
var _drag_record := {}
var _drag_offset := Vector2.ZERO
var _previous_auto_quit := true
var _pending_action: Callable
var _ui: Control
var _edit_panel: VBoxContainer
var _play_panel: VBoxContainer
var _name_edit: LineEdit
var _width: SpinBox
var _height: SpinBox
var _category: OptionButton
var _palette: ItemList
var _team: OptionButton
var _snap: CheckBox
var _grid: CheckBox
var _auto_attack: CheckBox
var _tool_choice: OptionButton
var _selection_label: Label
var _inspector: VBoxContainer
var _x: SpinBox
var _z: SpinBox
var _owner: OptionButton
var _amount: SpinBox
var _rate: SpinBox
var _resource_fields: VBoxContainer
var _title: Label
var _status: Label
var _coordinates: Label
var _play_button: Button
var _undo_button: Button
var _redo_button: Button
var _file_buttons: Array[Button] = []
var _dialog: FileDialog
var _confirm: ConfirmationDialog
var _error: AcceptDialog

func _ready() -> void:
	_previous_auto_quit = get_tree().auto_accept_quit
	get_tree().auto_accept_quit = false
	var backdrop := CanvasLayer.new()
	backdrop.layer = -1
	add_child(backdrop)
	var background := ColorRect.new()
	background.color = Color("152027")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_child(background)
	_ground = Node2D.new()
	add_child(_ground)
	entities = Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	add_child(entities)
	camera = Camera2D.new()
	camera.position_smoothing_enabled = false
	add_child(camera)
	_nav = NavHolder.new()
	_nav.name = "NavService"
	add_child(_nav)
	_vision = VisionHolder.new()
	_vision.setup()
	add_child(_vision)
	_build_ui()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIRECTORY))
	_rebuild_world()
	fit_map()
	get_viewport().size_changed.connect(fit_map)
	_set_status("从左侧选择对象，在地图上单击放置。可先打开示例地图。")

func _exit_tree() -> void:
	get_tree().auto_accept_quit = _previous_auto_quit
	Collision.clear_map_bounds()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_instance_valid(_confirm):
		_request_discard(func(): get_tree().quit())

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui)
	var theme := Theme.new()
	theme.default_font_size = 15
	_ui.theme = theme
	var toolbar := _panel(_ui, Vector2(12, 10), Vector2(-12, 96), true)
	var top := VBoxContainer.new()
	toolbar.add_child(top)
	_title = _label(top, "地图编辑器", 19)
	_title.clip_text = true
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	top.add_child(row)
	_file_buttons.append(_button(row, "新建", func(): _request_discard(_new_map)))
	_file_buttons.append(_button(row, "打开…", func(): _request_discard(_open_dialog)))
	_file_buttons.append(_button(row, "保存", func(): _save(false)))
	_file_buttons.append(_button(row, "另存为…", func(): _save(true)))
	_file_buttons.append(_button(row, "示例地图", func(): _request_discard(func(): open_map(EXAMPLE))))
	_undo_button = _button(row, "撤销", func(): _history(false))
	_redo_button = _button(row, "重做", func(): _history(true))
	_button(row, "全图 (F)", fit_map)
	_play_button = _button(row, "▶ 试运行 (P)", toggle_play)
	_button(row, "返回主菜单", func(): _request_discard(func(): get_tree().change_scene_to_file("res://scenes/civ_select.tscn")))
	var sidebar := _panel(_ui, Vector2(12, 106), Vector2(292, -46))
	sidebar.anchor_bottom = 1.0
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	_edit_panel = VBoxContainer.new()
	_edit_panel.add_theme_constant_override("separation", 8)
	content.add_child(_edit_panel)
	_label(_edit_panel, "地图设置", 18)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "地图名称"
	_name_edit.max_length = 120
	_edit_panel.add_child(_name_edit)
	var sizes := HBoxContainer.new()
	_edit_panel.add_child(sizes)
	_width = _spin(sizes, "宽", Data.MIN_SIZE, Data.MAX_SIZE, 1)
	_height = _spin(sizes, "高", Data.MIN_SIZE, Data.MAX_SIZE, 1)
	_button(_edit_panel, "应用名称 / 尺寸", _apply_settings)
	_tool_choice = OptionButton.new()
	for text in ["1  选择 / 拖动", "2  连续放置", "3  删除工具"]:
		_tool_choice.add_item(text)
	_tool_choice.item_selected.connect(_set_tool)
	_edit_panel.add_child(_tool_choice)
	_category = OptionButton.new()
	for text in ["建筑", "资源", "动态单位"]:
		_category.add_item(text)
	_category.item_selected.connect(func(index: int):
		_kind = ["building", "resource", "unit"][index]
		_populate_palette()
		_set_tool(Tool.PLACE))
	_edit_panel.add_child(_category)
	_palette = ItemList.new()
	_palette.custom_minimum_size = Vector2(0, 142)
	_palette.item_selected.connect(func(index: int):
		_brush_id = Catalog.ids(_kind)[index]
		_set_tool(Tool.PLACE))
	_edit_panel.add_child(_palette)
	_team = _teams(_edit_panel)
	_team.tooltip_text = "新放置对象的阵营；资源为中立。"
	_snap = _check(_edit_panel, "对齐 1 格", true)
	_grid = _check(content, "显示网格 (G)", true)
	_selection_label = _label(_edit_panel, "未选中对象", 14)
	_selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector = VBoxContainer.new()
	_edit_panel.add_child(_inspector)
	var position_row := HBoxContainer.new()
	_inspector.add_child(position_row)
	_x = _spin(position_row, "X", -10000, 10000, 0.1)
	_z = _spin(position_row, "Z", -10000, 10000, 0.1)
	_owner = _teams(_inspector)
	_resource_fields = VBoxContainer.new()
	_inspector.add_child(_resource_fields)
	_amount = _spin(_resource_fields, "资源总量", 0.1, 1000000, 0.1)
	_rate = _spin(_resource_fields, "采集速度 / 秒", 0.1, 1000000, 0.1)
	_button(_inspector, "应用对象属性", _apply_inspector)
	_button(_inspector, "删除选中对象 (Delete)", delete_selected)
	_play_panel = VBoxContainer.new()
	_play_panel.add_theme_constant_override("separation", 10)
	content.add_child(_play_panel)
	_label(_play_panel, "试运行", 20)
	var help := _label(_play_panel, "左键选择任意阵营的单位\n右键地面：移动\n右键资源：村民采集\n右键敌人：攻击\n空格：停止当前单位\n\n结束试运行将恢复编辑地图。\n此模式不启用经济 AI 和战争迷雾。", 15)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_auto_attack = _check(_play_panel, "双方自动战斗", false)
	var navigation := _label(content, "中键拖动：平移\n滚轮：缩放  ·  F：全图\nCtrl+S：保存  ·  Ctrl+O：打开\nCtrl+Z / Ctrl+Y：撤销 / 重做", 13)
	navigation.modulate = Color("acbdb4")
	var footer := _panel(_ui, Vector2(12, -38), Vector2(-12, -8), true)
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	var status_row := HBoxContainer.new()
	footer.add_child(status_row)
	_status = _label(status_row, "", 14)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_coordinates = _label(status_row, "", 14)
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.filters = PackedStringArray(["*.json ; JSON 地图"])
	_dialog.size = Vector2i(850, 540)
	_dialog.file_selected.connect(_file_selected)
	_ui.add_child(_dialog)
	_confirm = ConfirmationDialog.new()
	_confirm.title = "尚有未保存的更改"
	_confirm.dialog_text = "继续将丢弃当前地图的未保存更改。\n需要保留时，请取消并先保存。"
	_confirm.ok_button_text = "放弃更改并继续"
	_confirm.cancel_button_text = "取消"
	_confirm.confirmed.connect(func():
		if _pending_action.is_valid():
			_pending_action.call())
	_ui.add_child(_confirm)
	_error = AcceptDialog.new()
	_error.title = "地图编辑器"
	_ui.add_child(_error)
	_populate_palette()

func _panel(parent: Control, start: Vector2, finish: Vector2, stretch_x := false) -> PanelContainer:
	var panel := PanelContainer.new()
	parent.add_child(panel)
	if stretch_x:
		panel.anchor_right = 1.0
	panel.offset_left = start.x
	panel.offset_top = start.y
	panel.offset_right = finish.x
	panel.offset_bottom = finish.y
	var style := StyleBoxFlat.new()
	style.bg_color = Color("202c31")
	style.border_color = Color("52625b")
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _label(parent: Node, text: String, size := 15) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _spin(parent: Node, label: String, minimum: float, maximum: float, step: float) -> SpinBox:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(column)
	_label(column, label, 13)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(spin)
	return spin

func _teams(parent: Node) -> OptionButton:
	var option := OptionButton.new()
	option.add_item("玩家 / 中国（蓝）")
	option.add_item("对手 / 条顿（红）")
	parent.add_child(option)
	return option

func _check(parent: Node, text: String, pressed: bool) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	check.button_pressed = pressed
	check.focus_mode = Control.FOCUS_NONE
	parent.add_child(check)
	return check

func _populate_palette() -> void:
	_palette.clear()
	for id in Catalog.ids(_kind):
		_palette.add_item(Catalog.NAMES[id])
	_palette.select(0)
	_brush_id = Catalog.ids(_kind)[0]
	_team.disabled = _kind == "resource"

func _set_tool(value: int) -> void:
	tool = value
	_tool_choice.select(value)
	_clear_drag()
	_release_focus()

func _record(id: String) -> Dictionary:
	for record in document.data.entities:
		if record.id == id:
			return record
	return {}

func _refresh_ui() -> void:
	var rect := Data.bounds(document.data)
	_name_edit.text = document.data.display_name
	_width.value = rect.size.x
	_height.value = rect.size.y
	_title.text = "%s%s  ·  %d × %d  ·  %d 个对象  ·  %s" % ["* " if document.is_dirty() else "", document.data.display_name, rect.size.x, rect.size.y, document.data.entities.size(), document.path.get_file() if not document.path.is_empty() else "尚未保存"]
	_title.tooltip_text = ProjectSettings.globalize_path(document.path)
	_edit_panel.visible = not playing
	_play_panel.visible = playing
	_grid.visible = not playing
	_play_button.text = "■ 停止试运行 (P)" if playing else "▶ 试运行 (P)"
	for button in _file_buttons:
		button.disabled = playing
	_undo_button.disabled = playing or document._undo.is_empty()
	_redo_button.disabled = playing or document._redo.is_empty()
	_tool_choice.select(tool)
	var record := _record(selected_id)
	_inspector.visible = not record.is_empty()
	_selection_label.text = "未选中对象"
	if record.is_empty():
		return
	_selection_label.text = "%s  ·  %s" % [Catalog.NAMES[Catalog.definition_id(record)], record.id]
	_x.value = record.pos[0]
	_z.value = record.pos[1]
	_owner.visible = record.type != "resource"
	_resource_fields.visible = record.type == "resource"
	if record.type == "resource":
		_amount.value = record.amount
		_rate.value = record.gather_rate
	else:
		_owner.select(0 if record.team == "player" else 1)

func _clear_entities() -> void:
	_selected_runtime = null
	_nodes.clear()
	for entity in entities.get_children():
		entity.free()

func _rebuild_world() -> void:
	_clear_drag()
	_clear_entities()
	state = MatchState.new()
	state.setup_defaults()
	state.frozen = not playing
	var rect := Data.bounds(document.data)
	_nav.setup_rect(Vector2i(rect.position), Vector2i(rect.end))
	Loader.setup_ground(document.data, _ground)
	Loader.spawn_entities(document.data, entities, state, not playing)
	for entity in entities.get_children():
		_nodes[entity.get_meta("map_id")] = entity
	_nav.rebuild_from_scene()
	_vision.rebuild_from_scene()
	_combat.setup(entities, state)
	_refresh_ui()

func _sync_entities() -> void:
	var wanted := {}
	for record in document.data.entities:
		wanted[record.id] = record
	for id in _nodes.keys():
		if not wanted.has(id) or _nodes[id].get_meta("map_record") != wanted[id]:
			_nodes[id].free()
			_nodes.erase(id)
	for record in document.data.entities:
		if not _nodes.has(record.id):
			_nodes[record.id] = Loader.spawn_entity(record, entities, state, true)
	for id in _nodes:
		_nodes[id].set_selected(id == selected_id)
	_nav.rebuild_from_scene()
	_vision.rebuild_from_scene()
	_refresh_ui()

func _commit(data: Dictionary) -> bool:
	var errors := Data.validate(data)
	if not errors.is_empty():
		_show_error("\n".join(errors))
		return false
	if document.commit(data):
		_sync_entities()
	return true

func place_at(point: Vector2) -> bool:
	if playing:
		return false
	var record := _brush(point)
	var reason := Data.placement_error(document.data, record)
	if not reason.is_empty():
		_set_status(reason, true)
		return false
	record.id = Data.next_id(document.data)
	var data := document.data.duplicate(true)
	data.entities.append(record)
	selected_id = record.id
	if not _commit(data):
		return false
	_set_status("已放置 %s；继续单击可连续放置。" % Catalog.NAMES[_brush_id])
	return true

func _brush(point: Vector2) -> Dictionary:
	return Catalog.make_record(_kind, _brush_id, _snap_point(point), "player" if _team.selected == 0 else "ai")

func _snap_point(point: Vector2) -> Vector2:
	return point.round() if _snap.button_pressed else point.snapped(Vector2(0.1, 0.1))

func _select(id: String) -> void:
	selected_id = id
	for key in _nodes:
		_nodes[key].set_selected(key == id)
	_refresh_ui()

func delete_selected() -> void:
	if playing or selected_id.is_empty():
		return
	var data := document.data.duplicate(true)
	data.entities = data.entities.filter(func(record: Dictionary): return record.id != selected_id)
	selected_id = ""
	_commit(data)
	_set_status("对象已删除，可用 Ctrl+Z 撤销。")

func _apply_inspector() -> void:
	var original := _record(selected_id)
	if original.is_empty() or playing:
		return
	var changed := original.duplicate(true)
	changed.pos = [_x.value, _z.value]
	if changed.type == "resource":
		changed.amount = _amount.value
		changed.gather_rate = _rate.value
	else:
		changed.team = "player" if _owner.selected == 0 else "ai"
	_update_record(changed)

func _update_record(record: Dictionary) -> bool:
	var reason := Data.placement_error(document.data, record, record.id)
	if not reason.is_empty():
		_set_status(reason, true)
		return false
	var data := document.data.duplicate(true)
	for index in data.entities.size():
		if data.entities[index].id == record.id:
			data.entities[index] = record
			break
	if not _commit(data):
		return false
	_set_status("已更新对象属性。")
	_release_focus()
	return true

func _apply_settings() -> void:
	if playing:
		return
	var data := document.data.duplicate(true)
	data.display_name = _name_edit.text.strip_edges()
	data.bounds = Data.create(int(_width.value), int(_height.value)).bounds
	var errors := Data.validate(data)
	if not errors.is_empty():
		_show_error("无法应用设置（缩小地图前请移走越界对象）：\n" + "\n".join(errors))
		return
	document.commit(data)
	_rebuild_world()
	fit_map()
	_release_focus()
	_set_status("地图名称与尺寸已更新。")

func _history(redo: bool) -> void:
	if playing:
		return
	_clear_drag()
	var changed := document.redo() if redo else document.undo()
	if changed:
		selected_id = ""
		_rebuild_world()
		_set_status("已重做。" if redo else "已撤销。")

func _new_map() -> void:
	playing = false
	selected_id = ""
	document.replace(Data.create())
	_rebuild_world()
	fit_map()
	_set_status("新地图已创建，可在左侧设置宽高。")

func open_map(path: String) -> bool:
	var result := Loader.load_file(path)
	if result.has("error"):
		_show_error(result.error)
		return false
	playing = false
	selected_id = ""
	document.replace(result.data, "" if path == EXAMPLE else path)
	_rebuild_world()
	fit_map()
	_set_status("已打开：%s" % path)
	return true

func _open_dialog() -> void:
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.title = "打开 JSON 地图"
	_dialog.current_dir = ProjectSettings.globalize_path(SAVE_DIRECTORY)
	_dialog.current_file = ""
	_dialog.popup_centered()

func _save(save_as: bool) -> void:
	if playing:
		return
	if not save_as and not document.path.is_empty():
		save_map(document.path)
		return
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dialog.title = "保存 JSON 地图"
	_dialog.current_dir = ProjectSettings.globalize_path(SAVE_DIRECTORY) if document.path.is_empty() else document.path.get_base_dir()
	_dialog.current_file = "map.json" if document.path.is_empty() else document.path.get_file()
	_dialog.popup_centered()

func _file_selected(path: String) -> void:
	if _dialog.file_mode == FileDialog.FILE_MODE_OPEN_FILE:
		open_map(path)
	else:
		save_map(path if path.get_extension().to_lower() == "json" else path + ".json")

func save_map(path: String) -> bool:
	var error := Loader.save_file(document.data, path)
	if not error.is_empty():
		_show_error(error)
		return false
	document.path = path
	document.mark_saved()
	_refresh_ui()
	_set_status("已保存：%s" % ProjectSettings.globalize_path(path))
	return true

func _request_discard(action: Callable) -> void:
	if document.is_dirty():
		_pending_action = action
		_confirm.popup_centered()
	else:
		action.call()

func _show_error(message: String) -> void:
	_set_status(message.get_slice("\n", 0), true)
	_error.dialog_text = message.left(1800)
	_error.popup_centered(Vector2i(620, 240))

func _set_status(text: String, warning := false) -> void:
	_status.text = text
	_status.tooltip_text = text
	_status.modulate = Color("ffba86") if warning else Color("d5e4d7")

func _release_focus() -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()

func fit_map() -> void:
	if camera == null:
		return
	var rect := Data.bounds(document.data)
	var viewport := get_viewport_rect().size
	var available := Vector2(maxf(200, viewport.x - 330), maxf(150, viewport.y - 175))
	var projected := Vector2((rect.size.x + rect.size.y) * IsoMath.SCALE_X, (rect.size.x + rect.size.y) * IsoMath.SCALE_Y)
	var factor := clampf(minf(available.x / projected.x, available.y / projected.y) * 0.92, 0.06, 2.0)
	camera.zoom = Vector2.ONE * factor
	camera.position = IsoMath.world_to_screen(rect.get_center()) - Vector2(150, 28) / factor
	camera.force_update_scroll()

func toggle_play() -> void:
	_clear_drag()
	playing = not playing
	selected_id = ""
	_rebuild_world()
	_release_focus()
	_set_status("试运行：左键选择单位，右键移动 / 采集 / 攻击。" if playing else "已恢复试运行前的编辑地图。")

func _process(delta: float) -> void:
	if playing:
		_combat.set_team_auto_attack(Enums.Team.PLAYER, _auto_attack.button_pressed)
		_combat.set_team_auto_attack(Enums.Team.AI, _auto_attack.button_pressed)
		_combat.tick(delta)
	var point := IsoMath.screen_to_world(get_global_mouse_position())
	var coordinate_text := "X %.1f  Z %.1f" % [point.x, point.y] if Data.bounds(document.data).has_point(point) else "地图外"
	_coordinates.text = "%s  |  %.0f%%" % [coordinate_text, camera.zoom.x * 100.0]
	queue_redraw()

func _input(event: InputEvent) -> void:
	# Release even over UI so a drag cannot remain stuck after crossing the sidebar.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = false
		if event.button_index == MOUSE_BUTTON_LEFT and not _drag_record.is_empty():
			_finish_drag()

func _unhandled_input(event: InputEvent) -> void:
	if _dialog.visible or _confirm.visible or _error.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if _key(event):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		if _panning:
			camera.position -= event.relative / camera.zoom
		elif not _drag_record.is_empty():
			var point := _snap_point(_world_at(event.position) - _drag_offset)
			_drag_record.pos = [point.x, point.y]
			_nodes[selected_id].position = IsoMath.world_to_screen(point)
		return
	if not event is InputEventMouseButton or not event.pressed:
		return
	_release_focus()
	var point := _world_at(event.position)
	match event.button_index:
		MOUSE_BUTTON_MIDDLE:
			_panning = true
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			var before: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
			var factor := 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
			camera.zoom = Vector2.ONE * clampf(camera.zoom.x * factor, 0.06, 2.5)
			camera.force_update_scroll()
			camera.position += before - get_global_transform_with_canvas().affine_inverse() * event.position
		MOUSE_BUTTON_LEFT:
			if playing:
				_select_runtime(_pick(point))
			elif tool == Tool.PLACE:
				place_at(point)
			else:
				var hit := _pick(point)
				_select(hit.get_meta("map_id") if hit != null else "")
				if tool == Tool.ERASE:
					delete_selected()
				elif not selected_id.is_empty():
					_drag_record = _record(selected_id).duplicate(true)
					_drag_offset = point - Data.position_of(_drag_record)
		MOUSE_BUTTON_RIGHT:
			if playing:
				command_at(point)
			else:
				_set_tool(Tool.SELECT)
	get_viewport().set_input_as_handled()

func _world_at(viewport_point: Vector2) -> Vector2:
	return IsoMath.screen_to_world(get_global_transform_with_canvas().affine_inverse() * viewport_point)

func _key(event: InputEventKey) -> bool:
	if event.ctrl_pressed or event.meta_pressed:
		if playing:
			return false
		match event.keycode:
			KEY_S: _save(event.shift_pressed)
			KEY_O: _request_discard(_open_dialog)
			KEY_N: _request_discard(_new_map)
			KEY_Z: _history(event.shift_pressed)
			KEY_Y: _history(true)
			_: return false
		return true
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return false
	match event.keycode:
		KEY_F: fit_map()
		KEY_P: toggle_play()
		KEY_G: _grid.button_pressed = not _grid.button_pressed
		KEY_ESCAPE:
			if playing: toggle_play()
			else: _set_tool(Tool.SELECT)
		KEY_SPACE:
			if playing and is_instance_valid(_selected_runtime) and _selected_runtime is UnitAgent:
				_selected_runtime.command_stop()
		KEY_1, KEY_2, KEY_3:
			if not playing: _set_tool(event.keycode - KEY_1)
		KEY_DELETE:
			delete_selected()
		_: return false
	return true

func _pick(point: Vector2) -> Node2D:
	var candidates := entities.get_children()
	candidates.sort_custom(func(a: Node2D, b: Node2D): return a.position.y > b.position.y)
	# Footprints take precedence over tall art extending across another object.
	for entity in candidates:
		if not entity.visible or not entity.has_meta("map_record"):
			continue
		var half := Catalog.half_size(entity.get_meta("map_record"))
		if Rect2(entity.sim_pos - half, half * 2.0).has_point(point):
			return entity
	for entity in candidates:
		if not entity.visible or not entity.has_meta("map_record"):
			continue
		var sprite := entity.get_node_or_null("Billboard") as Sprite2D
		if sprite != null and sprite.visible and sprite.get_rect().has_point(sprite.to_local(IsoMath.world_to_screen(point))):
			return entity
	return null

func _clear_drag() -> void:
	if not _drag_record.is_empty() and _nodes.has(selected_id) and is_instance_valid(_nodes[selected_id]):
		_nodes[selected_id].position = IsoMath.world_to_screen(Data.position_of(_record(selected_id)))
	_drag_record = {}
	_panning = false

func _finish_drag() -> void:
	var changed := _drag_record.duplicate(true)
	_clear_drag()
	_update_record(changed)

func _select_runtime(entity: Node2D) -> void:
	if is_instance_valid(_selected_runtime):
		_selected_runtime.set_selected(false)
	_selected_runtime = entity
	if entity != null:
		entity.set_selected(true)
		_set_status("已选择 %s，右键下达指令。" % Catalog.NAMES[Catalog.definition_id(entity.get_meta("map_record"))])

func command_at(point: Vector2) -> void:
	if not playing or not is_instance_valid(_selected_runtime) or not _selected_runtime is UnitAgent:
		return
	if state.frozen:
		_set_status("试运行已结束，停止后可重新运行。")
		return
	if not Data.bounds(document.data).has_point(point):
		_set_status("目标在地图边界外。", true)
		return
	var target := _pick(point)
	if target is ResourceNode and _selected_runtime.def.id == &"villager":
		_selected_runtime.command_gather(target)
	elif target != null and (target is UnitAgent or target is BuildingAgent) and target.team != _selected_runtime.team:
		_selected_runtime.command_attack(target)
	else:
		_selected_runtime.command_move(point)

func _draw() -> void:
	if not is_instance_valid(camera) or not is_instance_valid(_grid):
		return
	var rect := Data.bounds(document.data)
	if _grid.button_pressed and not playing:
		var step := 1 if camera.zoom.x >= 0.35 else 4
		for x in range(int(rect.position.x), int(rect.end.x) + 1, step):
			draw_line(IsoMath.world_to_screen(Vector2(x, rect.position.y)), IsoMath.world_to_screen(Vector2(x, rect.end.y)), Color(0.7, 0.9, 0.65, 0.18), -1)
		for z in range(int(rect.position.y), int(rect.end.y) + 1, step):
			draw_line(IsoMath.world_to_screen(Vector2(rect.position.x, z)), IsoMath.world_to_screen(Vector2(rect.end.x, z)), Color(0.7, 0.9, 0.65, 0.18), -1)
	_draw_rect_iso(rect, Color("cfb977"), 2.0 / camera.zoom.x)
	if playing or get_viewport().gui_get_hovered_control() != null or _dialog.visible or _confirm.visible or _error.visible:
		return
	var preview := _drag_record
	if preview.is_empty() and tool == Tool.PLACE:
		preview = _brush(IsoMath.screen_to_world(get_global_mouse_position()))
	if preview.is_empty():
		return
	var point := Data.position_of(preview)
	var half := Catalog.half_size(preview)
	var valid := Data.placement_error(document.data, preview, preview.id).is_empty()
	_draw_rect_iso(Rect2(point - half, half * 2.0), Color("86efac") if valid else Color("ff7068"), 2.0 / camera.zoom.x)

func _draw_rect_iso(rect: Rect2, color: Color, width: float) -> void:
	var points := PackedVector2Array()
	for point in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y), rect.position]:
		points.append(IsoMath.world_to_screen(point))
	draw_polyline(points, color, width, true)
