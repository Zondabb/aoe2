class_name HudController
extends Control

const Catalog := preload("res://scripts/data/game_catalog.gd")
const GRID_KEYS := [KEY_Q,KEY_W,KEY_E,KEY_R,KEY_T,KEY_A,KEY_S,KEY_D,KEY_F,KEY_G,KEY_Z,KEY_X]
var _command_offset := 0
var _age_label: Label

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
var _production_queue: GridContainer
var _production_progress: ProgressBar
var _shown_production_key := ""

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
	_setup_production_queue()
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
	if match_state != null and match_state.progression_enabled:
		if _age_label == null:
			_age_label = Label.new()
			_age_label.name = "AgeLabel"
			_age_label.position = Vector2(405, 2)
			_age_label.size = Vector2(160,28)
			_age_label.z_index = 50
			_age_label.add_theme_color_override("font_outline_color",Color.BLACK)
			_age_label.add_theme_constant_override("outline_size",5)
			_age_label.add_theme_font_size_override("font_size", 15)
			_age_label.add_theme_color_override("font_color", Color("f1d395"))
			_age_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(_age_label)
		if not match_state.age_changed.is_connected(_on_progression_changed): match_state.age_changed.connect(_on_progression_changed)
		if not match_state.technology_changed.is_connected(_on_progression_changed): match_state.technology_changed.connect(_on_progression_changed)
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
	if match_state != null and match_state.progression_enabled: return true
	return civ != null and Enums.BuildingType.STABLE in civ.allowed_buildings

func _on_selection_changed(_selected: Array) -> void:
	_command_offset = 0
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
	# Selection signals refresh details before the next HUD process tick. Keep
	# queue visibility in sync before reading it for the contextual help text.
	_refresh_production_queue()
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
	if not is_instance_valid(focus) or focus.is_queued_for_deletion() or not FogAccess.view_can_see(focus):
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
	var show_private_details: bool = read_only or focus.get("team") == PlayerCommands.local_team(self)
	_count_label.text = "已选择 %d 个单位" % total_count if total_count > 1 else ""
	if total_count == 1 and focus.get("team") != null:
		_count_label.text = "己方" if focus.get("team") == PlayerCommands.local_team(self) else "对手"
	if definition is UnitDef:
		_stats_label.text = "攻击 %d    护甲 %d / %d    射程 %.1f" % [definition.attack, focus.melee_armor, focus.pierce_armor, definition.attack_range]
		if show_private_details and focus.get("carry_amount") != null and focus.carry_amount > 0:
			_queue_label.text = "携带资源 %d / %d" % [focus.carry_amount, focus.carry_capacity]
	elif definition is BuildingDef:
		_stats_label.text = "护甲 %d / %d    人口上限 +%d" % [focus.melee_armor, focus.pierce_armor, definition.population_provided]
		if not show_private_details:
			return
		var training: Array = focus.get("train_queue")
		if not focus.is_complete:
			_queue_label.text = "建造中  %d%%" % (100 * focus.build_progress / maxf(definition.build_time, 0.01))
		elif focus.is_age_researching():
			var job: Dictionary = match_state.age_progression.progress_for(focus.team)
			_queue_label.text = "升级%s  %d%%" % [Catalog.AGE_NAMES[job.target_age], 100 * float(job.progress)]
		elif focus.is_technology_researching():
			var job: Dictionary = match_state.technology_progression.progress_for(focus)
			_queue_label.text = "研究%s  %d%%" % [Catalog.display_name(job.technology_id), 100 * float(job.progress)]
		elif not training.is_empty() and focus.team == PlayerCommands.local_team(self):
			var trainee: UnitDef = training[0]
			_queue_label.text = "%s %s  %d%%  · 队列 %d/%d" % ["等待人口" if focus.is_training_population_blocked() else "训练", UiCatalogScript.unit_display_name(trainee.id), 100 * focus.training_progress_ratio(), training.size(), BuildingAgent.MAX_TRAIN_QUEUE]
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
		elif is_instance_valid(_selected_building) and focus == _selected_building and _production_queue != null and _production_queue.visible:
			_status_label.text = "人口已满：建造房屋或腾出人口后自动继续。点击队列图标可取消并退款。" if _selected_building.is_training_population_blocked() else "重复点击训练可排队；从左到右依次生产。点击队列图标可取消并退款。"
		elif is_instance_valid(focus) and focus.get("team") != null and focus.get("team") != PlayerCommands.local_team(self):
			_status_label.text = "敌方%s：仅可查看信息。" % ("建筑" if focus.is_in_group("buildings") else "单位")
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
	if not building_def.display_name.is_empty(): return building_def.display_name
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
		Enums.ResourceType.STONE:
			return "石矿"
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
		return entity._max_hp() if entity.has_method("_max_hp") else float(building_def.max_hp) * hp_multiplier
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
		if match_state != null and match_state.progression_enabled and entity.get("civ") != null:
			var base := Catalog.building_sheet(building_def.id, entity.civ.id, match_state.age_of(entity.team))
			if not base.is_empty(): return UiCatalogScript.atlas_frame(base,0)
		var frame := _building_icon_frame(building_def)
		return UiCatalogScript.atlas_frame(UiCatalogScript.ICONS_BUILDINGS_BASE, frame)
	return null

func _building_icon_frame(building_def: BuildingDef) -> int:
	if building_def.icon_id >= 0: return building_def.icon_id
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
	_command_offset = 0
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
		if match_state.progression_enabled:
			_add_production_commands()
		else:
			var slot := 0
			for unit_def in _selected_building.call("get_trainable_units"):
				_add_command_button(slot, "train_%s" % unit_def.id, "训练 %s" % UiCatalogScript.unit_display_name(unit_def.id), UiCatalogScript.ICONS_UNITS_BASE, UiCatalogScript.unit_icon_frame(unit_def.id), UiCatalogScript.unit_train_hotkey(unit_def.id), _enqueue_train.bind(unit_def), "unit_def", unit_def)
				slot += 1
	_refresh_command_grid_states()

func _add_build_commands() -> void:
	if match_state.progression_enabled:
		var economic := ["house","mill","mining_camp","lumber_camp","farm","market","blacksmith","town_center","monastery","university","wonder"]
		var ids: Array = economic if _command_page == "economy" else ["barracks","archery_range","stable","siege_workshop","castle","outpost","palisade_wall","stone_wall","gate","watch_tower","guard_tower","fortified_wall","keep","bombard_tower"]
		var keys := [KEY_E,KEY_I,KEY_G,KEY_Z,KEY_F,KEY_M,KEY_S,KEY_C,KEY_Y,KEY_U,KEY_O] if _command_page == "economy" else [KEY_B,KEY_A,KEY_L,KEY_W,KEY_C,KEY_O,KEY_P,KEY_T,KEY_G,KEY_Q,KEY_R,KEY_F,KEY_K,KEY_D]
		var available: Array = []
		for id in ids:
			var d := Catalog.get_building(id)
			if d != null and (d.civilizations.is_empty() or civ.id in d.civilizations): available.append(d)
		for i in mini(12, available.size()-_command_offset):
			var d: BuildingDef = available[_command_offset+i]
			_add_command_button(i, "build_%s" % d.id, _building_display_name(d), UiCatalogScript.ICONS_BUILDINGS_BASE, _building_icon_frame(d), keys[ids.find(String(d.id))], _request_build.bind(d), "building_def", d)
		_add_pagination(available.size(), true)
		_add_command_button(14, "back", "返回单位指令", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_BACK, KEY_ESCAPE, _set_command_page.bind("root"))
		return
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
	key_label.text = "Esc" if hotkey == KEY_ESCAPE else "PgUp" if hotkey == KEY_PAGEUP else "PgDn" if hotkey == KEY_PAGEDOWN else OS.get_keycode_string(hotkey)
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

func _setup_production_queue() -> void:
	_production_queue = get_node_or_null("%ProductionQueue") as GridContainer
	_production_progress = get_node_or_null("%ProductionProgress") as ProgressBar
	if _production_queue == null or _production_queue.get_child_count() > 0:
		return
	for index in BuildingAgent.MAX_TRAIN_QUEUE:
		var button := Button.new()
		button.name = "QueueSlot%d" % index
		button.custom_minimum_size = Vector2(28, 28)
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		for state in ["normal", "hover", "pressed", "disabled"]:
			var style := StyleBoxFlat.new()
			style.bg_color = Color("3c3324") if state == "hover" else Color("272318")
			style.border_color = Color("ffe0a0") if index == 0 or state == "hover" else Color("92794c")
			style.set_border_width_all(2 if index == 0 else 1)
			button.add_theme_stylebox_override(state, style)
		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 2
		icon.offset_top = 2
		icon.offset_right = -2
		icon.offset_bottom = -2
		button.pressed.connect(func(): _cancel_queued_train(int(button.get_meta("queue_id", -1))))
		_production_queue.add_child(button)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("d0a544")
	_production_progress.add_theme_stylebox_override("fill", fill)
	var background := StyleBoxFlat.new()
	background.bg_color = Color("463621")
	_production_progress.add_theme_stylebox_override("background", background)

func _refresh_production_queue() -> void:
	if _production_queue == null:
		return
	var building := _selected_building as BuildingAgent
	var active := is_instance_valid(building) and building.team == PlayerCommands.local_team(self) and not building.train_queue.is_empty()
	_production_queue.visible = active
	_production_progress.visible = active
	_command_hint.offset_top = 149 if active else 116
	_command_hint.offset_bottom = 177 if active else 166
	_command_hint.add_theme_font_size_override("font_size", 11 if active else 13)
	if not active:
		_shown_production_key = ""
		return
	_production_progress.value = 100.0 * building.training_progress_ratio()
	var key := str(building.get_instance_id()) + str(building.train_queue_ids) + str(building.train_queue)
	for index in _production_queue.get_child_count():
		var button := _production_queue.get_child(index) as Button
		button.visible = index < building.train_queue.size()
		if not button.visible:
			continue
		button.disabled = not _commands_enabled() or index >= building.train_queue_ids.size()
		if key == _shown_production_key:
			continue
		var definition := building.train_queue[index]
		button.set_meta("queue_id", building.train_queue_ids[index] if index < building.train_queue_ids.size() else -1)
		button.get_node("Icon").texture = UiCatalogScript.atlas_frame(UiCatalogScript.ICONS_UNITS_BASE, UiCatalogScript.unit_icon_frame(definition.id))
		button.tooltip_text = "%d. %s%s\n点击取消，退还全部训练资源" % [index + 1, UiCatalogScript.unit_display_name(definition.id), "（当前生产）" if index == 0 else "（等待）"]
	_shown_production_key = key

func _cancel_queued_train(queue_id: int) -> void:
	if not _commands_enabled() or not is_instance_valid(_selected_building) or _selected_building.team != PlayerCommands.local_team(self):
		return
	if PlayerCommands.is_online(self):
		PlayerCommands.submit(self, {"op": "cancel_train", "building_id": PlayerCommands.entity_id(self, _selected_building), "queue_id": queue_id})
	else:
		if _selected_building.cancel_train(queue_id):
			PlayerCommands.Registry.report_manual_command({"op": "cancel_train", "building_id": PlayerCommands.Registry.id_of(_selected_building), "queue_id": queue_id}, PlayerCommands.local_team(self))

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
			if _selected_building.call("enqueue_train", unit_def):
				PlayerCommands.Registry.report_manual_command({"op": "train", "building_id": PlayerCommands.Registry.id_of(_selected_building), "unit_def_id": String(unit_def.id), "queue_id": _selected_building.train_queue_ids[-1]}, PlayerCommands.local_team(self))

func _can_enqueue(unit_def: UnitDef) -> bool:
	return (
		_commands_enabled()
		and _selected_building != null
		and is_instance_valid(_selected_building)
		and _selected_building.get("team") == PlayerCommands.local_team(self)
		and bool(_selected_building.get("is_complete"))
		and match_state != null
		and match_state.winner == -1
		and _selected_building.train_blocked_reason(unit_def).is_empty()
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
				reason = Catalog.building_reason(match_state, PlayerCommands.local_team(self), civ, definition, _match_root().get_node("Entities"))
		elif button.has_meta("unit_def"):
			definition = button.get_meta("unit_def")
			button.disabled = not _can_enqueue(definition)
			if button.disabled:
				reason = _selected_building.train_blocked_reason(definition) if is_instance_valid(_selected_building) else "请选择生产建筑"
		elif button.has_meta("age_upgrade"):
			var target_age := match_state.age_of(PlayerCommands.local_team(self)) + 1
			reason = match_state.age_progression.blocked_reason(_selected_building) if is_instance_valid(match_state.age_progression) else "正在初始化对局"
			button.disabled = not reason.is_empty() or not _commands_enabled()
			button.set_meta("label", "升级" + Catalog.AGE_NAMES[mini(target_age,3)])
		elif button.has_meta("technology_id"):
			reason = match_state.technology_progression.blocked_reason(_selected_building, button.get_meta("technology_id")) if is_instance_valid(match_state.technology_progression) else "正在初始化对局"
			button.disabled = not reason.is_empty() or not _commands_enabled()
		var hotkey: Key = button.get_meta("hotkey")
		button.tooltip_text = "%s [%s]" % [button.get_meta("label"), "Esc" if hotkey == KEY_ESCAPE else OS.get_keycode_string(hotkey)]
		if definition != null:
			var costs: PackedStringArray = []
			if definition.cost_wood > 0: costs.append("木材 %d" % definition.cost_wood)
			if definition.cost_food > 0: costs.append("食物 %d" % definition.cost_food)
			if definition.cost_gold > 0: costs.append("黄金 %d" % definition.cost_gold)
			if definition.cost_stone > 0: costs.append("石料 %d" % definition.cost_stone)
			button.tooltip_text += "\n" + "  ".join(costs)
		if button.has_meta("age_upgrade"):
			var req: Dictionary = preload("res://scripts/systems/age_progression.gd").requirements_for(match_state.age_of(PlayerCommands.local_team(self))+1)
			button.tooltip_text += "\n食物 %d  黄金 %d  时间 %d 秒" % [req.get("food",0),req.get("gold",0),req.get("duration",0)]
		elif button.has_meta("technology_id"):
			var tech: Dictionary = Catalog.technologies()[button.get_meta("technology_id")]
			button.tooltip_text += "\n食物 %d  木材 %d  黄金 %d  时间 %d 秒" % [tech.cost.get("food",0),tech.cost.get("wood",0),tech.cost.get("gold",0),tech.get("time",0)]
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
		_stone_digits.set_number(match_state.get_resource(PlayerCommands.local_team(self), Enums.ResourceType.STONE))
	if _age_label != null:
		_age_label.text = Catalog.AGE_NAMES[match_state.age_of(PlayerCommands.local_team(self))]
		_age_label.position.x = 405 * UiCatalogScript.panel_scale_for_width(size.x)
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
			if match_state.progression_enabled: return Catalog.building_reason(match_state, PlayerCommands.local_team(self), civ, building_def, _match_root().get_node("Entities")).is_empty()
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

func _on_progression_changed(_team: int, _value: Variant) -> void:
	_command_offset = 0
	call_deferred("_rebuild_command_grid")

func _page_commands(delta: int) -> void:
	_command_offset = maxi(0, _command_offset + delta * 12)
	call_deferred("_rebuild_command_grid")

func _add_pagination(count: int, building_page := false) -> void:
	if _command_offset > 0:
		_add_command_button(13, "previous", "上一页", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_BACK, KEY_PAGEUP, _page_commands.bind(-1))
	if _command_offset + 12 < count:
		_add_command_button(12 if building_page else 14, "next", "下一页", UiCatalogScript.ICONS_COMMANDS_BASE, UiCatalogScript.FRAME_ECONOMY, KEY_PAGEDOWN, _page_commands.bind(1))

func _add_production_commands() -> void:
	var entries: Array = []
	for unit_def in _selected_building.get_trainable_units(): entries.append({"unit":unit_def})
	if match_state.technology_progression != null:
		for id in match_state.technology_progression.available(_selected_building): entries.append({"technology":id})
	_command_offset = mini(_command_offset, maxi(0, (entries.size()-1)/12) * 12)
	for i in mini(12, entries.size()-_command_offset):
		var entry: Dictionary = entries[i+_command_offset]
		if entry.has("unit"):
			var u: UnitDef = entry.unit
			_add_command_button(i,"train_%s" % u.id,"训练 " + u.display_name,UiCatalogScript.ICONS_UNITS_BASE,u.icon_id,KEY_C if u.id == &"villager" else GRID_KEYS[i],_enqueue_train.bind(u),"unit_def",u)
		else:
			var id: String = entry.technology
			var tech: Dictionary = Catalog.technologies()[id]
			_add_command_button(i,"research_"+id,"研究 "+tech.display_name,"res://assets/sprites/ui/icons_technologies",int(tech.get("icon_id",0)),GRID_KEYS[i],_research_technology.bind(id),"technology_id",id)
	_add_pagination(entries.size())
	if _selected_building.def.id == &"town_center" and match_state.age_of(_selected_building.team) < 3:
		if _selected_building.is_age_researching():
			_add_command_button(10,"cancel_age","取消时代升级",UiCatalogScript.ICONS_COMMANDS_BASE,UiCatalogScript.FRAME_STOP,KEY_U,_research_age.bind(true))
		else:
			_add_command_button(10,"research_age","升级时代","res://assets/sprites/ui/icons_technologies",30+match_state.age_of(_selected_building.team),KEY_U,_research_age.bind(false),"age_upgrade",true)
	if _selected_building.is_technology_researching():
		_add_command_button(12,"cancel_technology","取消研究",UiCatalogScript.ICONS_COMMANDS_BASE,UiCatalogScript.FRAME_STOP,KEY_ESCAPE,_research_technology.bind("",true))

func _research_age(cancel: bool) -> void:
	if is_instance_valid(_selected_building): PlayerCommands.research_age(self,_selected_building,cancel)

func _research_technology(id: String, cancel := false) -> void:
	if is_instance_valid(_selected_building): PlayerCommands.research_technology(self,_selected_building,id,cancel)
