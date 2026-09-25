class_name HudController
extends Control

const PlayerCommands := preload("res://scripts/input/player_commands.gd")

const FogAccess := preload("res://scripts/systems/fog_access.gd")

const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")
const STABLE: BuildingDef = preload("res://data/buildings/stable.tres")
const MILL: BuildingDef = preload("res://data/buildings/mill.tres")
const LUMBER_CAMP: BuildingDef = preload("res://data/buildings/lumber_camp.tres")
const MINING_CAMP: BuildingDef = preload("res://data/buildings/mining_camp.tres")
const UiCatalogScript := preload("res://scripts/presentation/ui_catalog.gd")

var match_state: MatchState
var civ: CivDef
var build_system: Node
var selection: Node
var read_only := false
var _selected_building: Node2D
var _status_label: Label
var _command_page := "root"
var _hovered_command: BaseButton

@onready var _resources_label := %ResourcesLabel as Label
@onready var _wood_digits := %WoodDigits as Aoe2DigitRow
@onready var _food_digits := %FoodDigits as Aoe2DigitRow
@onready var _gold_digits := %GoldDigits as Aoe2DigitRow
@onready var _stone_digits := %StoneDigits as Aoe2DigitRow
@onready var _pop_digits := %PopDigits as Aoe2DigitRow
var _shown_wood := -1
var _shown_food := -1
var _shown_gold := -1
var _shown_pop_used := -1
var _shown_pop_cap := -1

@onready var _train_panel := %TrainPanel as VBoxContainer
@onready var _result_panel := %ResultPanel as Control
@onready var _result_label := %ResultLabel as Label
@onready var _return_button := %ReturnButton as Button
@onready var _stable_button := %StableButton as Button
@onready var _command_panel := %CommandPanel as Control
@onready var _portrait := %Portrait as TextureRect
@onready var _name_label := %NameLabel as Label
@onready var _hp_bar := %HpBar as ProgressBar
@onready var _hp_label := %HpLabel as Label
@onready var _count_label := %CountLabel as Label
@onready var _command_grid := %CommandGrid as GridContainer
@onready var _stats_label := %StatsLabel as Label
@onready var _queue_label := %QueueLabel as Label
@onready var _command_hint := %CommandHint as Label

func _ready() -> void:
	_style_health_bar()
	_sync_hud_layout()
	resized.connect(_on_hud_layout_dirty)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_hud_layout_dirty):
		vp.size_changed.connect(_on_hud_layout_dirty)

func setup(
	state: MatchState,
	player_civ: CivDef,
	system: Node,
	selection_controller: Node,
	read_only_mode := false
) -> void:
	match_state = state
	civ = player_civ
	build_system = system
	selection = selection_controller
	read_only = read_only_mode
	var minimap := get_node_or_null("Minimap")
	if minimap != null:
		minimap.setup(state, selection_controller, system, read_only_mode)
	_resources_label = get_node_or_null("%ResourcesLabel") as Label
	_wood_digits = get_node_or_null("%WoodDigits") as Aoe2DigitRow
	_food_digits = get_node_or_null("%FoodDigits") as Aoe2DigitRow
	_gold_digits = get_node_or_null("%GoldDigits") as Aoe2DigitRow
	_stone_digits = get_node_or_null("%StoneDigits") as Aoe2DigitRow
	_pop_digits = get_node_or_null("%PopDigits") as Aoe2DigitRow
	_train_panel = get_node_or_null("TrainPanel") as VBoxContainer
	_result_panel = get_node_or_null("ResultPanel") as Control
	_result_label = find_child("ResultLabel", true, false) as Label
	_return_button = find_child("ReturnButton", true, false) as Button
	_stable_button = get_node_or_null("%StableButton") as Button
	if _stable_button == null:
		_stable_button = find_child("StableButton", true, false) as Button
	_command_panel = get_node_or_null("%CommandPanel") as Control
	_portrait = get_node_or_null("%Portrait") as TextureRect
	_name_label = get_node_or_null("%NameLabel") as Label
	_hp_bar = get_node_or_null("%HpBar") as ProgressBar
	_hp_label = get_node_or_null("%HpLabel") as Label
	_count_label = get_node_or_null("%CountLabel") as Label
	_command_grid = get_node_or_null("%CommandGrid") as GridContainer
	_stats_label = get_node_or_null("%StatsLabel") as Label
	_queue_label = get_node_or_null("%QueueLabel") as Label
	_command_hint = get_node_or_null("%CommandHint") as Label
	_ensure_status_label()
	_sync_hud_layout()
	if selection != null:
		if not selection.is_connected("selection_changed", _on_selection_changed):
			selection.connect("selection_changed", _on_selection_changed)
	if match_state != null and not match_state.winner_decided.is_connected(_on_winner_decided):
		match_state.winner_decided.connect(_on_winner_decided)
	if _return_button != null and not _return_button.pressed.is_connected(_return_to_civ_select):
		_return_button.pressed.connect(_return_to_civ_select)
	if _return_button != null and PlayerCommands.is_online(self):
		_return_button.text = "返回联机大厅"
	if _stable_button != null:
		_stable_button.visible = _civ_allows_stable()
	_on_selection_changed([])
	_refresh()
	if match_state.winner != -1:
		_on_winner_decided(match_state.winner)

func _ensure_status_label() -> void:
	if _status_label != null and is_instance_valid(_status_label):
		return
	_status_label = get_node_or_null("%CommandHint") as Label

func _on_hud_layout_dirty() -> void:
	call_deferred("_sync_hud_layout")

func _sync_hud_layout() -> void:
	_sync_top_bar_layout()
	_sync_command_panel_layout()
	_sync_minimap_layout()

func _sync_minimap_layout() -> void:
	var minimap := get_node_or_null("Minimap") as Control
	if minimap == null:
		return
	var panel_scale := UiCatalogScript.panel_scale_for_width(size.x)
	var slot: Rect2 = UiCatalogScript.PANEL_MINIMAP_RECT
	minimap.position = Vector2(slot.position.x * panel_scale,
		size.y + (slot.position.y - UiCatalogScript.PANEL_DESIGN_HEIGHT) * panel_scale)
	minimap.size = slot.size * panel_scale

func _sync_top_bar_layout() -> void:
	var top_bar := get_node_or_null("%ResourceTopBar") as Control
	if top_bar == null:
		return
	var scale := UiCatalogScript.panel_scale_for_width(size.x)
	var band_h := UiCatalogScript.panel_scaled_top_band(size.x)
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top_bar.offset_top = 0.0
	top_bar.offset_bottom = band_h
	var slots: Array = UiCatalogScript.panel_resource_slots()
	var digit_rows: Array[Aoe2DigitRow] = [
		_wood_digits,
		_food_digits,
		_gold_digits,
		_stone_digits,
		_pop_digits,
	]
	for i in range(mini(digit_rows.size(), slots.size())):
		var row := digit_rows[i]
		if row == null:
			continue
		var slot: Dictionary = slots[i]
		var slot_w := float(slot.get("width", 40.0))
		var slot_top := float(slot.get("top", 8.0))
		row.position = Vector2(float(slot["left"]) * scale, slot_top * scale)
		row.size = Vector2(slot_w * scale, band_h - slot_top * scale)
		row.set_font_size(maxi(12, int(round(14.0 * scale))))

func _sync_command_panel_layout() -> void:
	if _command_panel == null:
		return
	var panel_scale := UiCatalogScript.panel_scale_for_width(size.x)
	_command_panel.offset_top = -UiCatalogScript.panel_scaled_bottom_band(size.x)
	var content := get_node_or_null("CommandPanel/Content") as Control
	if content != null:
		content.scale = Vector2.ONE * panel_scale
		content.size = Vector2(844, 205)

func _style_health_bar() -> void:
	var background := StyleBoxFlat.new()
	background.bg_color = Color("392a1a")
	background.border_color = Color("62492c")
	background.set_border_width_all(1)
	_hp_bar.add_theme_stylebox_override("background", background)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("438331")
	_hp_bar.add_theme_stylebox_override("fill", fill)

func _process(_delta: float) -> void:
	_ensure_selected_building_valid()
	_refresh()

func _request_build(building_def: BuildingDef) -> void:
	if not _can_build(building_def):
		return
	if build_system != null:
		build_system.call("begin_placement", building_def)

func _civ_allows_stable() -> bool:
	return civ != null and Enums.BuildingType.STABLE in civ.allowed_buildings

func _on_selection_changed(_selected: Array) -> void:
	_command_page = "root"
	_disconnect_selected_building()
	if selection == null:
		_selected_building = null
	else:
		_selected_building = selection.call("get_selected_building") as Node2D
	if _selected_building != null:
		_selected_building.connect("train_queue_changed", _on_train_queue_changed)
		if not _selected_building.is_connected("tree_exited", _on_selected_building_exited):
			_selected_building.connect("tree_exited", _on_selected_building_exited)
	_refresh_info_panel()
	_rebuild_command_grid()

func _disconnect_selected_building() -> void:
	if _selected_building == null or not is_instance_valid(_selected_building):
		return
	if _selected_building.is_connected("train_queue_changed", _on_train_queue_changed):
		_selected_building.disconnect("train_queue_changed", _on_train_queue_changed)
	if _selected_building.is_connected("tree_exited", _on_selected_building_exited):
		_selected_building.disconnect("tree_exited", _on_selected_building_exited)

func _on_selected_building_exited() -> void:
	_selected_building = null
	_refresh_info_panel()
	_rebuild_command_grid()

func _ensure_selected_building_valid() -> void:
	if _selected_building != null and not is_instance_valid(_selected_building):
		_selected_building = null
		_refresh_info_panel()
		_rebuild_command_grid()

func _refresh_info_panel() -> void:
	if _name_label == null:
		return
	var units: Array = selection.call("get_selected_units") if selection != null else []
	var building: Node2D = (
		selection.call("get_selected_building") as Node2D if selection != null else null
	)
	var primary: Node2D = (
		selection.call("get_primary_selection") as Node2D if selection != null else null
	)
	var total_count := _selected_count(units, building, primary)
	if total_count == 0:
		_clear_info_panel()
		return
	var focus := _pick_info_entity(units, building, primary)
	if focus == null:
		_clear_info_panel()
		return
	var max_hp := _entity_max_hp(focus)
	var current_hp := _entity_current_value(focus, max_hp)
	_name_label.text = _entity_display_name(focus)
	_hp_bar.max_value = maxf(max_hp, 1.0)
	_hp_bar.value = clampf(current_hp, 0.0, _hp_bar.max_value)
	_hp_label.text = "%d / %d" % [int(round(current_hp)), int(round(max_hp))]
	if _count_label != null:
		_count_label.text = "×%d" % total_count if total_count > 1 else ""
	if _portrait != null:
		_portrait.texture = _entity_portrait(focus)
	_hp_bar.visible = max_hp > 0
	_refresh_entity_details(focus, total_count)
	_refresh_status_label(focus, units)

func _refresh_entity_details(focus: Node2D, total_count: int) -> void:
	if _stats_label == null or _queue_label == null:
		return
	var definition: Variant = focus.get("def")
	_stats_label.text = ""
	_queue_label.text = ""
	_count_label.text = "已选择 %d 个单位" % total_count if total_count > 1 else ""
	if total_count == 1 and focus.get("team") != null:
		_count_label.text = "己方" if focus.get("team") == PlayerCommands.local_team(self) else "对手"
	if definition is UnitDef:
		_stats_label.text = "攻击 %d    护甲 %d / %d    射程 %.1f" % [definition.attack, focus.melee_armor, focus.pierce_armor, definition.attack_range]
		if focus.get("carry_amount") != null and focus.carry_amount > 0:
			_queue_label.text = "携带资源 %d / %d" % [focus.carry_amount, focus.carry_capacity]
	elif definition is BuildingDef:
		_stats_label.text = "护甲 %d / %d    人口上限 +%d" % [definition.melee_armor, definition.pierce_armor, definition.population_provided]
		var training: Array = focus.get("train_queue")
		if not focus.is_complete:
			_queue_label.text = "建造中  %d%%" % (100 * focus.build_progress / maxf(definition.build_time, 0.01))
		elif not training.is_empty():
			var trainee: UnitDef = training[0]
			_queue_label.text = "训练 %s  %d%%" % [UiCatalogScript.unit_display_name(trainee.id), 100 * focus.train_progress / maxf(trainee.train_time, 0.01)]
	elif focus.is_in_group("resource_nodes"):
		_stats_label.text = "采集速度  %.1f / 秒" % float(focus.get("gather_rate"))

func _refresh_status_label(focus: Node2D, units: Array) -> void:
	if _status_label == null:
		return
	if not read_only:
		if is_instance_valid(_hovered_command):
			_status_label.text = _hovered_command.tooltip_text.replace("\n", "  ")
		elif build_system != null and build_system.call("is_placing"):
			_status_label.text = "需要视野：先探索整个建筑占地" if build_system.get("placement_reason") == "need_vision" else "左键放置建筑；右键或 Esc 取消。"
		elif _command_page != "root":
			_status_label.text = "%s：选择建筑，再在地图上放置。Esc 返回。" % ("经济建筑" if _command_page == "economy" else "军事建筑")
		else:
			_status_label.text = "右键移动、采集或攻击；B 经济建筑 / V 军事建筑。" if not units.is_empty() and units[0].get("team") == PlayerCommands.local_team(self) and units[0].get("def").id == &"villager" else "右键下达指令。" if not units.is_empty() and units[0].get("team") == PlayerCommands.local_team(self) else ""
		return
	if focus == null:
		_status_label.text = ""
		return
	if focus.is_in_group("units") and focus.has_method("get_inspect_summary"):
		_status_label.text = focus.call("get_inspect_summary")
	elif focus.is_in_group("resource_nodes"):
		_status_label.text = "剩余 %.0f" % float(focus.get("amount"))
	elif focus.is_in_group("buildings"):
		var complete := bool(focus.get("is_complete"))
		if complete:
			_status_label.text = "建造完成"
		else:
			var building_def := focus.get("def") as BuildingDef
			var build_time := building_def.build_time if building_def != null else 1.0
			var pct := 100.0 * float(focus.get("build_progress")) / maxf(build_time, 0.001)
			_status_label.text = "建造中 %.0f%%" % pct
	elif units.size() > 1:
		_status_label.text = "已选 %d 个单位" % units.size()
	else:
		_status_label.text = ""

func _clear_info_panel() -> void:
	if _stats_label != null:
		_stats_label.text = ""
	if _queue_label != null:
		_queue_label.text = ""
	if _name_label != null:
		_name_label.text = ""
	if _hp_bar != null:
		_hp_bar.value = 0.0
		_hp_bar.visible = false
	if _hp_label != null:
		_hp_label.text = ""
	if _count_label != null:
		_count_label.text = ""
	if _portrait != null:
		_portrait.texture = null
	if _status_label != null:
		_status_label.text = ""

func _selected_count(units: Array, building: Node2D, primary: Node2D) -> int:
	if not units.is_empty():
		return units.size()
	if building != null:
		return 1
	if primary != null:
		return 1
	return 0

func _pick_info_entity(units: Array, building: Node2D, primary: Node2D) -> Node2D:
	if not units.is_empty():
		return units[0] as Node2D
	if building != null:
		return building
	return primary

func _entity_display_name(entity: Node2D) -> String:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return UiCatalogScript.unit_display_name(unit_def.id)
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		return _building_display_name(building_def)
	if entity.is_in_group("resource_nodes"):
		return _resource_display_name(int(entity.get("resource_type")))
	return entity.name

func _building_display_name(building_def: BuildingDef) -> String:
	match building_def.id:
		&"town_center":
			return "城镇中心"
		&"house":
			return "房屋"
		&"barracks":
			return "兵营"
		&"archery_range":
			return "靶场"
		&"stable":
			return "马厩"
		&"mill":
			return "磨坊"
		&"lumber_camp":
			return "伐木场"
		&"mining_camp":
			return "采矿营"
		_:
			return String(building_def.id)

func _resource_display_name(resource_type: int) -> String:
	match resource_type:
		Enums.ResourceType.FOOD:
			return "浆果"
		Enums.ResourceType.WOOD:
			return "树木"
		Enums.ResourceType.GOLD:
			return "金矿"
		_:
			return "资源"

func _entity_max_hp(entity: Node2D) -> float:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return float(unit_def.max_hp)
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		var entity_civ := entity.get("civ") as CivDef
		var hp_multiplier := entity_civ.building_hp_mul if entity_civ != null else 1.0
		return float(building_def.max_hp) * hp_multiplier
	if entity.is_in_group("resource_nodes"):
		return maxf(float(entity.get("amount")), 1.0)
	return 0.0

func _entity_current_value(entity: Node2D, max_hp: float) -> float:
	if entity.is_in_group("resource_nodes"):
		return clampf(float(entity.get("amount")), 0.0, max_hp)
	var health: Variant = entity.get("hp")
	return clampf(float(health), 0.0, max_hp) if health != null else 0.0

func _entity_portrait(entity: Node2D) -> Texture2D:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return UiCatalogScript.atlas_frame(
			UiCatalogScript.ICONS_UNITS_BASE,
			UiCatalogScript.unit_icon_frame(unit_def.id)
		)
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		var frame := _building_icon_frame(building_def)
		return UiCatalogScript.atlas_frame(UiCatalogScript.ICONS_BUILDINGS_BASE, frame)
	return null

func _building_icon_frame(building_def: BuildingDef) -> int:
	match building_def.id:
		&"town_center":
			return UiCatalogScript.FRAME_BUILD_TOWN_CENTER
		&"house":
			return UiCatalogScript.FRAME_BUILD_HOUSE
		&"barracks":
			return UiCatalogScript.FRAME_BUILD_BARRACKS
		&"archery_range":
			return UiCatalogScript.FRAME_BUILD_ARCHERY
		&"stable":
			return UiCatalogScript.FRAME_BUILD_STABLE
		&"mill":
			return UiCatalogScript.FRAME_BUILD_MILL
		&"lumber_camp":
			return UiCatalogScript.FRAME_BUILD_LUMBER
		&"mining_camp":
			return UiCatalogScript.FRAME_BUILD_MINING
		_:
			return 0

func _on_train_queue_changed() -> void:
	# Defer so we never free the TextureButton still handling `pressed`.
	call_deferred("_rebuild_command_grid")

func _commands_enabled() -> bool:
	return not read_only and not FogAccess.local_read_only(self) and match_state != null and not match_state.frozen and match_state.winner == -1

func _set_command_page(page: String) -> void:
	if not _commands_enabled() or page not in ["root", "economy", "military"]:
		return
	_command_page = page
	# A page button may still be delivering its pressed signal.
	call_deferred("_rebuild_command_grid")

func _rebuild_command_grid() -> void:
	if _command_grid == null:
		return
	_hovered_command = null
	for child in _command_grid.get_children():
		_command_grid.remove_child(child)
		child.queue_free()
	# Empty positions are intentional: commands never slide into another slot.
	for index in 15:
		var empty := Control.new()
		empty.custom_minimum_size = Vector2(46, 46)
		empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_command_grid.add_child(empty)
	if read_only or not is_instance_valid(selection):
		return
	var units: Array = selection.call("get_selected_units")
	var has_player_villager := false
	var has_player_units := false
	for unit in units:
		if not is_instance_valid(unit) or unit.get("team") != PlayerCommands.local_team(self):
			continue
		has_player_units = true
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"villager":
			has_player_villager = true
	if has_player_villager:
		if _command_page == "root":
			_add_command_button(0, "economy", "经济建筑", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_ECONOMY, KEY_B, _set_command_page.bind("economy"))
			_add_command_button(1, "military", "军事建筑", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_MILITARY, KEY_V, _set_command_page.bind("military"))
		else:
			_add_build_commands()
	if has_player_units and _command_page == "root":
		_add_command_button(9, "stop", "停止", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_STOP, KEY_S, _stop_selected_units)
	if is_instance_valid(_selected_building) and _selected_building.get("team") == PlayerCommands.local_team(self) and bool(_selected_building.get("is_complete")):
		var slot := 0
		for unit_def in _selected_building.call("get_trainable_units"):
			_add_command_button(slot, "train_%s" % unit_def.id, "训练 %s" % UiCatalogScript.unit_display_name(unit_def.id), UiCatalogScript.ICONS_UNITS_BASE, UiCatalogScript.unit_icon_frame(unit_def.id), UiCatalogScript.unit_train_hotkey(unit_def.id), _enqueue_train.bind(unit_def), "unit_def", unit_def)
			slot += 1
	_refresh_command_grid_states()

func _add_build_commands() -> void:
	var entries: Array = []
	if _command_page == "economy":
		entries = [[HOUSE, KEY_E], [MILL, KEY_I], [MINING_CAMP, KEY_G], [LUMBER_CAMP, KEY_Z]]
	else:
		entries = [[BARRACKS, KEY_B], [ARCHERY_RANGE, KEY_A], [STABLE, KEY_L]]
	for slot in entries.size():
		var definition: BuildingDef = entries[slot][0]
		if definition == STABLE and not _civ_allows_stable():
			continue
		_add_command_button(slot, "build_%s" % definition.id, _building_display_name(definition), UiCatalogScript.ICONS_BUILDINGS_BASE, _building_icon_frame(definition), entries[slot][1], _request_build.bind(definition), "building_def", definition)
	_add_command_button(14, "back", "返回单位指令", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_BACK, KEY_ESCAPE, _set_command_page.bind("root"))

func _add_command_button(slot: int, command_id: String, label: String, icon_base: String, frame_index: int, hotkey: Key, callback: Callable, meta_key: String = "", meta_value: Variant = null) -> void:
	var button := Button.new()
	button.name = command_id.to_pascal_case()
	button.custom_minimum_size = Vector2(46, 46)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.set_meta("command_id", command_id)
	button.set_meta("hotkey", hotkey)
	button.set_meta("label", label)
	button.set_meta("slot", slot)
	if meta_key != "":
		button.set_meta(meta_key, meta_value)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("292619") if state == "normal" else Color("48402a") if state == "hover" else Color("17180f")
		style.border_color = Color("e8c887") if state == "hover" else Color("9b8755") if state == "normal" else Color("514831")
		style.set_border_width_all(1)
		button.add_theme_stylebox_override(state, style)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = UiCatalogScript.atlas_frame(icon_base, frame_index)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 3
	icon.offset_top = 3
	icon.offset_right = -3
	icon.offset_bottom = -3
	var key_label := Label.new()
	key_label.name = "Hotkey"
	key_label.text = "Esc" if hotkey == KEY_ESCAPE else OS.get_keycode_string(hotkey)
	key_label.add_theme_font_size_override("font_size", 10)
	key_label.add_theme_color_override("font_color", Color("fff0b3"))
	key_label.add_theme_color_override("font_outline_color", Color.BLACK)
	key_label.add_theme_constant_override("outline_size", 3)
	key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(key_label)
	key_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	key_label.position = Vector2(43 - key_label.get_minimum_size().x, 1)
	button.pressed.connect(callback)
	button.mouse_entered.connect(func(): _hovered_command = button)
	button.mouse_exited.connect(func():
		if _hovered_command == button:
			_hovered_command = null)
	var placeholder := _command_grid.get_child(slot)
	_command_grid.remove_child(placeholder)
	placeholder.queue_free()
	_command_grid.add_child(button)
	_command_grid.move_child(button, slot)

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or event.ctrl_pressed or event.alt_pressed or event.meta_pressed or not _commands_enabled():
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	var key: Key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key == KEY_ESCAPE and build_system != null and build_system.call("is_placing"):
		build_system.call("cancel_placement")
		get_viewport().set_input_as_handled()
		return
	if key == KEY_H and _select_town_center():
		get_viewport().set_input_as_handled()
		return
	for child in _command_grid.get_children():
		if child is BaseButton and child.get_meta("hotkey", KEY_NONE) == key:
			if not child.disabled:
				child.pressed.emit()
			get_viewport().set_input_as_handled()
			return

func _select_town_center() -> bool:
	if not is_instance_valid(selection) or not selection.has_method("_add_selection"):
		return false
	for building in get_tree().get_nodes_in_group("buildings"):
		var definition := building.get("def") as BuildingDef
		if building.get("team") != PlayerCommands.local_team(self) or definition == null or definition.id != &"town_center" or building.is_queued_for_deletion():
			continue
		selection.call("_clear_selection", false)
		selection.call("_add_selection", building)
		var camera := get_viewport().get_camera_2d()
		if camera != null and camera.has_method("focus_on"):
			camera.call("focus_on", building.get("sim_pos"))
		return true
	return false

func _stop_selected_units() -> void:
	if not _commands_enabled():
		return
	if selection == null:
		return
	for unit in selection.call("get_selected_units"):
		if unit.get("team") == PlayerCommands.local_team(self) and unit.has_method("command_stop"):
			PlayerCommands.unit_order(self, unit, "stop")

func _enqueue_train(unit_def: UnitDef) -> void:
	if not _can_enqueue(unit_def):
		return
	if _selected_building != null and is_instance_valid(_selected_building):
		if PlayerCommands.is_online(self):
			PlayerCommands.submit(self, {
				"op": "train",
				"building_id": PlayerCommands.entity_id(self, _selected_building),
				"unit_def_id": String(unit_def.id),
			})
		else:
			_selected_building.call("enqueue_train", unit_def)

func _can_enqueue(unit_def: UnitDef) -> bool:
	return (
		_commands_enabled()
		and _selected_building != null
		and is_instance_valid(_selected_building)
		and _selected_building.get("team") == PlayerCommands.local_team(self)
		and bool(_selected_building.get("is_complete"))
		and (_selected_building.get("train_queue") as Array).is_empty()
		and match_state != null
		and match_state.winner == -1
		and match_state.can_train(PlayerCommands.local_team(self), unit_def)
	)

func _refresh_command_grid_states() -> void:
	if _command_grid == null:
		return
	for child in _command_grid.get_children():
		var button := child as BaseButton
		if button == null:
			continue
		var reason := ""
		button.disabled = not _commands_enabled()
		var definition: Variant = null
		if button.has_meta("building_def"):
			definition = button.get_meta("building_def")
			button.disabled = not _can_build(definition)
			if button.disabled:
				reason = "资源不足或当前无法建造"
		elif button.has_meta("unit_def"):
			definition = button.get_meta("unit_def")
			button.disabled = not _can_enqueue(definition)
			if button.disabled:
				reason = "正在训练" if is_instance_valid(_selected_building) and not _selected_building.train_queue.is_empty() else "资源或人口空间不足"
		var hotkey: Key = button.get_meta("hotkey")
		button.tooltip_text = "%s [%s]" % [button.get_meta("label"), "Esc" if hotkey == KEY_ESCAPE else OS.get_keycode_string(hotkey)]
		if definition != null:
			var costs: PackedStringArray = []
			if definition.cost_wood > 0: costs.append("木材 %d" % definition.cost_wood)
			if definition.cost_food > 0: costs.append("食物 %d" % definition.cost_food)
			if definition.cost_gold > 0: costs.append("黄金 %d" % definition.cost_gold)
			button.tooltip_text += "\n" + "  ".join(costs)
		if not reason.is_empty():
			button.tooltip_text += "\n" + reason
		button.get_node("Icon").modulate = Color(0.4, 0.4, 0.4, 0.8) if button.disabled else Color.WHITE

func _refresh() -> void:
	if match_state == null or match_state.resources.is_empty():
		return
	var food := match_state.get_resource(PlayerCommands.local_team(self), Enums.ResourceType.FOOD)
	var wood := match_state.get_resource(PlayerCommands.local_team(self), Enums.ResourceType.WOOD)
	var gold := match_state.get_resource(PlayerCommands.local_team(self), Enums.ResourceType.GOLD)
	var pop_used := int(match_state.population[PlayerCommands.local_team(self)])
	var pop_cap := int(match_state.population_cap[PlayerCommands.local_team(self)])
	if _wood_digits != null and wood != _shown_wood:
		_shown_wood = wood
		_wood_digits.set_number(wood)
	if _food_digits != null and food != _shown_food:
		_shown_food = food
		_food_digits.set_number(food)
	if _gold_digits != null and gold != _shown_gold:
		_shown_gold = gold
		_gold_digits.set_number(gold)
	if _stone_digits != null:
		_stone_digits.set_number(0)
	if _pop_digits != null and (pop_used != _shown_pop_used or pop_cap != _shown_pop_cap):
		_shown_pop_used = pop_used
		_shown_pop_cap = pop_cap
		_pop_digits.set_population(pop_used, pop_cap)
	var resources_text := "食物 %d   木材 %d   黄金 %d" % [food, wood, gold]
	if _resources_label != null and _resources_label.text != resources_text:
		_resources_label.text = resources_text
	_refresh_info_panel()
	_refresh_command_grid_states()

func _can_build(building_def: BuildingDef) -> bool:
	if not _commands_enabled() or selection == null or (building_def == STABLE and not _civ_allows_stable()):
		return false
	for unit in selection.call("get_selected_units"):
		if not is_instance_valid(unit) or unit.get("team") != PlayerCommands.local_team(self):
			continue
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"villager":
			return match_state.can_afford(
				PlayerCommands.local_team(self),
				building_def.cost_food,
				building_def.cost_wood,
				building_def.cost_gold
			)
	return false

func _on_winner_decided(winning_team: Enums.Team) -> void:
	if _result_panel != null:
		_result_panel.visible = true
	if _result_label != null:
		_result_label.text = "胜利" if winning_team == PlayerCommands.local_team(self) else "失败"
	if selection != null:
		selection.set_process_unhandled_input(false)
	if build_system != null:
		build_system.call("cancel_placement")
		build_system.set_process(false)
		build_system.set_process_unhandled_input(false)
	var match_root := _match_root()
	var ai_controller := (
		match_root.get_node_or_null("AiController") if match_root != null else null
	)
	if ai_controller != null and ai_controller.has_method("stop"):
		ai_controller.call("stop")
	var entities := match_root.get_node_or_null("Entities") if match_root != null else null
	if entities != null:
		for entity in entities.get_children():
			entity.set_physics_process(false)
	_refresh()

func _match_root() -> Node:
	var node: Node = self
	while node != null:
		if node.name == "Match" or node.name == "AiVsAi":
			return node
		node = node.get_parent()
	return get_parent()

func show_network_result(message: String) -> void:
	if _result_panel != null:
		_result_panel.visible = true
	if _result_label != null:
		_result_label.custom_minimum_size.x = minf(560, maxf(280, size.x - 64))
		_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_result_label.add_theme_font_size_override("font_size", 24)
		_result_label.text = message
	if selection != null:
		selection.read_only = true
	if build_system != null:
		build_system.cancel_placement()
	_refresh()

func _return_to_civ_select() -> void:
	if PlayerCommands.is_online(self):
		NetworkSession.leave()
		GameSession.online_active = false
		GameSession.online_return_to_lobby = true
	get_tree().change_scene_to_file("res://scenes/civ_select.tscn")
