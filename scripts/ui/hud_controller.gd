class_name HudController
extends Control

const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")

var match_state: MatchState
var civ: CivDef
var build_system: Node
var selection: Control
var _selected_building: Node3D

@onready var _resources_label := %ResourcesLabel as Label
@onready var _population_label := %PopulationLabel as Label
@onready var _train_panel := %TrainPanel as VBoxContainer

func setup(
	state: MatchState,
	player_civ: CivDef,
	system: Node,
	selection_controller: Control
) -> void:
	match_state = state
	civ = player_civ
	build_system = system
	selection = selection_controller
	_resources_label = get_node_or_null("TopBar/ResourcesLabel") as Label
	_population_label = get_node_or_null("TopBar/PopulationLabel") as Label
	_train_panel = get_node_or_null("TrainPanel") as VBoxContainer
	if not selection.is_connected("selection_changed", _on_selection_changed):
		selection.connect("selection_changed", _on_selection_changed)
	_connect_build_button(%HouseButton, HOUSE)
	_connect_build_button(%BarracksButton, BARRACKS)
	_connect_build_button(%ArcheryButton, ARCHERY_RANGE)
	_on_selection_changed([])
	_refresh()

func _process(_delta: float) -> void:
	_refresh()

func _request_build(building_def: BuildingDef) -> void:
	if build_system != null:
		build_system.call("begin_placement", building_def)

func _connect_build_button(button: Button, building_def: BuildingDef) -> void:
	var callback := _request_build.bind(building_def)
	if not button.pressed.is_connected(callback):
		button.pressed.connect(callback)

func _on_selection_changed(_selected: Array[Node3D]) -> void:
	if (
		_selected_building != null
		and _selected_building.is_connected(
			"train_queue_changed", _rebuild_train_buttons
		)
	):
		_selected_building.disconnect("train_queue_changed", _rebuild_train_buttons)
	_selected_building = selection.call("get_selected_building") as Node3D
	if _selected_building != null:
		_selected_building.connect("train_queue_changed", _rebuild_train_buttons)
	_rebuild_train_buttons()

func _rebuild_train_buttons() -> void:
	for child in _train_panel.get_children():
		child.queue_free()
	if _selected_building == null:
		return
	for unit_def in _selected_building.call("get_trainable_units"):
		var button := Button.new()
		button.text = "训练 %s" % unit_def.display_name
		button.set_meta("unit_def", unit_def)
		button.disabled = not _can_enqueue(unit_def)
		button.pressed.connect(_enqueue_train.bind(unit_def))
		_train_panel.add_child(button)

func _enqueue_train(unit_def: UnitDef) -> void:
	if _selected_building != null:
		_selected_building.call("enqueue_train", unit_def)

func _can_enqueue(unit_def: UnitDef) -> bool:
	return (
		_selected_building != null
		and bool(_selected_building.get("is_complete"))
		and (_selected_building.get("train_queue") as Array).is_empty()
		and match_state != null
		and match_state.can_train(Enums.Team.PLAYER, unit_def)
	)

func _refresh() -> void:
	if match_state == null or match_state.resources.is_empty():
		return
	var resources_text := "食物 %d   木材 %d   黄金 %d" % [
		match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD),
		match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.WOOD),
		match_state.get_resource(Enums.Team.PLAYER, Enums.ResourceType.GOLD),
	]
	var population_text := "人口 %d / %d" % [
		match_state.population[Enums.Team.PLAYER],
		match_state.population_cap[Enums.Team.PLAYER],
	]
	if _resources_label.text != resources_text:
		_resources_label.text = resources_text
	if _population_label.text != population_text:
		_population_label.text = population_text
	%HouseButton.disabled = not _can_build(HOUSE)
	%BarracksButton.disabled = not _can_build(BARRACKS)
	%ArcheryButton.disabled = not _can_build(ARCHERY_RANGE)
	for child in _train_panel.get_children():
		var button := child as Button
		if button != null and button.get_meta("unit_def", null) is UnitDef:
			button.disabled = not _can_enqueue(button.get_meta("unit_def") as UnitDef)

func _can_build(building_def: BuildingDef) -> bool:
	if selection == null or match_state == null:
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
