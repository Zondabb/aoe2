class_name ArenaSetupPanel
extends Control

signal battle_requested(config)

const ArenaConfigScript := preload("res://scripts/data/arena_config.gd")

const UNIT_ROWS := [
	{"id": &"villager", "label": "村民"},
	{"id": &"swordsman", "label": "剑士"},
	{"id": &"archer", "label": "弓箭手"},
	{"id": &"chu_ko_nu", "label": "诸葛弩"},
	{"id": &"teutonic_knight", "label": "条顿骑士"},
]

@onready var _player_civ_option := %PlayerCivOption as OptionButton
@onready var _ai_civ_option := %AiCivOption as OptionButton
@onready var _auto_attack_check := %AutoAttackCheck as CheckBox
@onready var _player_auto_attack_check := %PlayerAutoAttackCheck as CheckBox
@onready var _count_grid := %CountGrid as GridContainer

var _spinboxes: Dictionary = {}

func _ready() -> void:
	_setup_civ_options()
	_setup_count_spinboxes()
	_apply_preset_two_each()

func _setup_civ_options() -> void:
	for option: OptionButton in [_player_civ_option, _ai_civ_option]:
		option.clear()
		option.add_item("中国", 0)
		option.set_item_metadata(0, &"chinese")
		option.add_item("条顿", 1)
		option.set_item_metadata(1, &"teutons")
	_player_civ_option.select(0)
	_ai_civ_option.select(1)

func _setup_count_spinboxes() -> void:
	for row in UNIT_ROWS:
		var label := Label.new()
		label.text = row["label"]
		_count_grid.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = 0
		spin.max_value = 30
		spin.value = 0
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_count_grid.add_child(spin)
		_spinboxes[row["id"]] = spin

func _apply_preset_two_each() -> void:
	for unit_id: StringName in _spinboxes:
		(_spinboxes[unit_id] as SpinBox).value = 2

func restore_from_config(config: ArenaConfigScript) -> void:
	_select_civ(_player_civ_option, config.player_civ_id)
	_select_civ(_ai_civ_option, config.ai_civ_id)
	_auto_attack_check.button_pressed = config.ai_auto_attack
	_player_auto_attack_check.button_pressed = config.player_auto_attack
	for unit_id: StringName in _spinboxes:
		(_spinboxes[unit_id] as SpinBox).value = int(config.unit_counts.get(unit_id, 0))

func _select_civ(option: OptionButton, civ_id: StringName) -> void:
	for index in option.item_count:
		if option.get_item_metadata(index) == civ_id:
			option.select(index)
			return

func _build_config() -> ArenaConfigScript:
	var config := ArenaConfigScript.new()
	config.player_civ_id = _player_civ_option.get_item_metadata(_player_civ_option.selected)
	config.ai_civ_id = _ai_civ_option.get_item_metadata(_ai_civ_option.selected)
	config.ai_auto_attack = _auto_attack_check.button_pressed
	config.player_auto_attack = _player_auto_attack_check.button_pressed
	config.unit_counts.clear()
	for unit_id: StringName in _spinboxes:
		config.unit_counts[unit_id] = int((_spinboxes[unit_id] as SpinBox).value)
	return config

func _on_preset_pressed() -> void:
	_apply_preset_two_each()

func _on_start_pressed() -> void:
	var config := _build_config()
	if config.total_units() <= 0:
		return
	visible = false
	battle_requested.emit(config)

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/civ_select.tscn")

func _on_reconfigure_pressed() -> void:
	var reconfigure := get_node_or_null("../ReconfigureButton") as Control
	if reconfigure != null:
		reconfigure.visible = false
	var bootstrap := get_node_or_null("../../Bootstrap") as Node
	if bootstrap != null and bootstrap.has_method("reopen_setup"):
		bootstrap.call("reopen_setup")
