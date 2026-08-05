# scripts/ui/civ_select_controller.gd
extends Control

signal civ_chosen(civ_id: StringName)

func _on_chinese_pressed() -> void:
	civ_chosen.emit(&"chinese")

func _on_teutons_pressed() -> void:
	civ_chosen.emit(&"teutons")

func _ready() -> void:
	# Temporary: just print until match scene exists (Task 10 wires change_scene).
	if not civ_chosen.is_connected(_temp_log):
		civ_chosen.connect(_temp_log)

func _temp_log(civ_id: StringName) -> void:
	print("Selected civ: ", civ_id)
