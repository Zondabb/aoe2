class_name HudController
extends Control

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
var _selected_building: Node2D

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

func setup(
	state: MatchState,
	player_civ: CivDef,
	system: Node,
	selection_controller: Node
) -> void:
	match_state = state
	civ = player_civ
	build_system = system
	selection = selection_controller
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
	_sync_hud_layout()
	resized.connect(_on_hud_layout_dirty)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_hud_layout_dirty):
		vp.size_changed.connect(_on_hud_layout_dirty)
	if selection != null:
		if not selection.is_connected("selection_changed", _on_selection_changed):
			selection.connect("selection_changed", _on_selection_changed)
	if match_state != null and not match_state.winner_decided.is_connected(_on_winner_decided):
		match_state.winner_decided.connect(_on_winner_decided)
	if _return_button != null and not _return_button.pressed.is_connected(_return_to_civ_select):
		_return_button.pressed.connect(_return_to_civ_select)
	if _stable_button != null:
		_stable_button.visible = _civ_allows_stable()
	_on_selection_changed([])
	_refresh()
	if match_state.winner != -1:
		_on_winner_decided(match_state.winner)

func _on_hud_layout_dirty() -> void:
	call_deferred("_sync_hud_layout")

func _sync_hud_layout() -> void:
	_sync_top_bar_layout()
	_sync_command_panel_layout()

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
	var frame := get_node_or_null("GamePanelFrame") as GamePanelFrame
	var band := frame.bottom_band_height if frame != null else 150.0
	if band <= 0.0:
		band = UiCatalogScript.panel_scaled_bottom_band(size.x)
	_command_panel.offset_top = -band

func _process(_delta: float) -> void:
	_ensure_selected_building_valid()
	_refresh()

func _request_build(building_def: BuildingDef) -> void:
	if build_system != null:
		build_system.call("begin_placement", building_def)

func _civ_allows_stable() -> bool:
	return civ != null and Enums.BuildingType.STABLE in civ.allowed_buildings

func _on_selection_changed(_selected: Array) -> void:
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
	var total_count := units.size() + (1 if building != null else 0)
	if total_count == 0:
		_clear_info_panel()
		return
	var focus := _pick_info_entity(units, building)
	if focus == null:
		_clear_info_panel()
		return
	var max_hp := _entity_max_hp(focus)
	var current_hp := float(focus.get("hp"))
	_name_label.text = _entity_display_name(focus)
	_hp_bar.max_value = maxf(max_hp, 1.0)
	_hp_bar.value = clampf(current_hp, 0.0, _hp_bar.max_value)
	_hp_label.text = "%d / %d" % [int(round(current_hp)), int(round(max_hp))]
	if _count_label != null:
		_count_label.text = "×%d" % total_count if total_count > 1 else ""
	if _portrait != null:
		_portrait.texture = _entity_portrait(focus)

func _clear_info_panel() -> void:
	if _name_label != null:
		_name_label.text = ""
	if _hp_bar != null:
		_hp_bar.value = 0.0
	if _hp_label != null:
		_hp_label.text = ""
	if _count_label != null:
		_count_label.text = ""
	if _portrait != null:
		_portrait.texture = null

func _pick_info_entity(units: Array, building: Node2D) -> Node2D:
	if not units.is_empty():
		return units[0] as Node2D
	return building

func _entity_display_name(entity: Node2D) -> String:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return unit_def.display_name
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		return _building_display_name(building_def)
	return ""

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

func _entity_max_hp(entity: Node2D) -> float:
	var unit_def := entity.get("def") as UnitDef
	if unit_def != null:
		return float(unit_def.max_hp)
	var building_def := entity.get("def") as BuildingDef
	if building_def != null:
		var entity_civ := entity.get("civ") as CivDef
		var hp_multiplier := entity_civ.building_hp_mul if entity_civ != null else 1.0
		return float(building_def.max_hp) * hp_multiplier
	return 0.0

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

func _rebuild_command_grid() -> void:
	if _command_grid == null:
		_command_grid = get_node_or_null("%CommandGrid") as GridContainer
	if _command_grid == null:
		return
	for child in _command_grid.get_children():
		_command_grid.remove_child(child)
		child.free()
	if selection == null:
		return
	var units: Array = selection.call("get_selected_units")
	var has_player_villager := false
	var has_player_units := false
	for unit in units:
		if unit.get("team") != Enums.Team.PLAYER:
			continue
		has_player_units = true
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"villager":
			has_player_villager = true
	if has_player_villager:
		_add_build_commands()
	if (
		_selected_building != null
		and is_instance_valid(_selected_building)
		and bool(_selected_building.get("is_complete"))
	):
		for unit_def in _selected_building.call("get_trainable_units"):
			_add_command_button(
				"训练 %s" % unit_def.display_name,
				UiCatalogScript.ICONS_UNITS_BASE,
				UiCatalogScript.unit_icon_frame(unit_def.id),
				_enqueue_train.bind(unit_def),
				not _can_enqueue(unit_def),
				"unit_def",
				unit_def
			)
	if has_player_units:
		_add_command_button(
			"停止",
			UiCatalogScript.ICONS_COMMANDS_BASE,
			UiCatalogScript.FRAME_STOP,
			_stop_selected_units,
			false
		)

func _add_build_commands() -> void:
	var build_entries: Array[Dictionary] = [
		{"def": HOUSE, "label": "房屋", "frame": UiCatalogScript.FRAME_BUILD_HOUSE},
		{"def": BARRACKS, "label": "兵营", "frame": UiCatalogScript.FRAME_BUILD_BARRACKS},
		{"def": ARCHERY_RANGE, "label": "靶场", "frame": UiCatalogScript.FRAME_BUILD_ARCHERY},
		{"def": MILL, "label": "磨坊", "frame": UiCatalogScript.FRAME_BUILD_MILL},
		{"def": LUMBER_CAMP, "label": "伐木场", "frame": UiCatalogScript.FRAME_BUILD_LUMBER},
		{"def": MINING_CAMP, "label": "采矿营", "frame": UiCatalogScript.FRAME_BUILD_MINING},
	]
	if _civ_allows_stable():
		build_entries.insert(
			3,
			{"def": STABLE, "label": "马厩", "frame": UiCatalogScript.FRAME_BUILD_STABLE}
		)
	for entry in build_entries:
		var building_def: BuildingDef = entry["def"]
		_add_command_button(
			entry["label"],
			UiCatalogScript.ICONS_BUILDINGS_BASE,
			int(entry["frame"]),
			_request_build.bind(building_def),
			not _can_build(building_def),
			"building_def",
			building_def
		)

func _add_command_button(
	label: String,
	icon_base: String,
	frame_index: int,
	callback: Callable,
	disabled: bool = false,
	meta_key: String = "",
	meta_value: Variant = null
) -> void:
	var button: BaseButton
	var icon: Texture2D = UiCatalogScript.atlas_frame(icon_base, frame_index)
	if icon != null:
		var texture_button := TextureButton.new()
		texture_button.texture_normal = icon
		texture_button.custom_minimum_size = Vector2(48, 48)
		texture_button.tooltip_text = label
		texture_button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		button = texture_button
	else:
		var text_button := Button.new()
		text_button.text = label
		button = text_button
	button.disabled = disabled
	if meta_key != "":
		button.set_meta(meta_key, meta_value)
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)
	_command_grid.add_child(button)

func _stop_selected_units() -> void:
	if selection == null:
		return
	for unit in selection.call("get_selected_units"):
		if unit.get("team") == Enums.Team.PLAYER and unit.has_method("command_stop"):
			unit.call("command_stop")

func _enqueue_train(unit_def: UnitDef) -> void:
	if _selected_building != null and is_instance_valid(_selected_building):
		_selected_building.call("enqueue_train", unit_def)

func _can_enqueue(unit_def: UnitDef) -> bool:
	return (
		_selected_building != null
		and is_instance_valid(_selected_building)
		and bool(_selected_building.get("is_complete"))
		and (_selected_building.get("train_queue") as Array).is_empty()
		and match_state != null
		and match_state.winner == -1
		and match_state.can_train(Enums.Team.PLAYER, unit_def)
	)

func _refresh_command_grid_states() -> void:
	if _command_grid == null:
		return
	for child in _command_grid.get_children():
		var button := child as BaseButton
		if button == null:
			continue
		if button.has_meta("building_def"):
			var building_def: Variant = button.get_meta("building_def")
			if building_def is BuildingDef:
				button.disabled = not _can_build(building_def)
			continue
		if button.has_meta("unit_def"):
			var unit_def: Variant = button.get_meta("unit_def")
			if unit_def is UnitDef:
				button.disabled = not _can_enqueue(unit_def)

func _refresh() -> void:
	if match_state == null or match_state.resources.is_empty():
		return
	var food := match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD)
	var wood := match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.WOOD)
	var gold := match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.GOLD)
	var pop_used := int(match_state.population[Enums.Team.PLAYER])
	var pop_cap := int(match_state.population_cap[Enums.Team.PLAYER])
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
	if selection == null or match_state == null or match_state.winner != -1:
		return false
	for unit in selection.call("get_selected_units"):
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"villager":
			return match_state.can_afford(
				Enums.Team.PLAYER,
				building_def.cost_food,
				building_def.cost_wood,
				building_def.cost_gold
			)
	return false

func _on_winner_decided(winning_team: Enums.Team) -> void:
	if _result_panel != null:
		_result_panel.visible = true
	if _result_label != null:
		_result_label.text = "胜利" if winning_team == Enums.Team.PLAYER else "失败"
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
		if node.name == "Match":
			return node
		node = node.get_parent()
	return get_parent()

func _return_to_civ_select() -> void:
	get_tree().change_scene_to_file("res://scenes/civ_select.tscn")
