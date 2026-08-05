# scripts/ui/civ_select_controller.gd
extends Control

signal civ_chosen(civ_id: StringName)

func _on_chinese_pressed() -> void:
	_choose_civ(&"chinese")

func _on_teutons_pressed() -> void:
	_choose_civ(&"teutons")

func _choose_civ(civ_id: StringName) -> void:
	GameSession.player_civ_id = civ_id
	GameSession.ai_civ_id = &"teutons" if civ_id == &"chinese" else &"chinese"
	civ_chosen.emit(civ_id)
	get_tree().change_scene_to_file("res://scenes/match_3d.tscn")
