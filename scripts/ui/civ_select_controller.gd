# scripts/ui/civ_select_controller.gd
extends Control

signal civ_chosen(civ_id: StringName)

const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const HttpAiClientScript := preload("res://scripts/ai_gateway/http_ai_client.gd")

@onready var _ai_url_edit: LineEdit = $VBoxContainer/AiServiceUrl
@onready var _embedded_check: CheckBox = $VBoxContainer/UseEmbeddedCheck
@onready var _ai_status: Label = $VBoxContainer/AiStatusLabel


func _ready() -> void:
	_ai_url_edit.text = String(GameSession.ai_service_url)
	_embedded_check.button_pressed = bool(GameSession.ai_use_local_embedded)
	_clear_status()


func _on_chinese_pressed() -> void:
	_choose_civ(&"chinese")


func _on_teutons_pressed() -> void:
	_choose_civ(&"teutons")


func _on_arena_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/combat_arena.tscn")


func _on_pathfinding_arena_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/pathfinding_arena.tscn")


func _choose_civ(civ_id: StringName) -> void:
	var config := _apply_ai_settings()
	if not await _validate_ai_service(config):
		return
	GameSession.player_civ_id = civ_id
	GameSession.ai_civ_id = &"teutons" if civ_id == &"chinese" else &"chinese"
	civ_chosen.emit(civ_id)
	get_tree().change_scene_to_file("res://scenes/match_2d.tscn")


func _apply_ai_settings() -> AiConfig:
	var config := AiConfigScript.from_civ_select(
		_ai_url_edit.text,
		_embedded_check.button_pressed,
	)
	config.save_to_game_session()
	return config


func _validate_ai_service(config: AiConfig) -> bool:
	_clear_status()
	if not config.requires_startup_probe():
		return true

	_set_status("正在检测 AI 服务…")
	var client := HttpAiClientScript.new()
	add_child(client)
	await _wait_frame()
	client.configure(config)
	var health := await client.get_health()
	client.cancel_requests()
	client.queue_free()

	if health.get("ok") == true:
		_clear_status()
		return true

	if config.allows_embedded_fallback():
		_set_status(
			"外部 AI 不可用（%s），对局中将使用内嵌本地服务。"
			% config.display_url(),
			false,
		)
		await get_tree().create_timer(1.2).timeout
		_clear_status()
		return true

	_set_status("AI 服务无法连接: %s" % config.display_url(), true)
	return false


func _wait_frame() -> void:
	var tree := get_tree()
	if tree != null:
		await tree.process_frame
	else:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _set_status(message: String, is_error: bool = false) -> void:
	_ai_status.text = message
	if is_error:
		_ai_status.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	else:
		_ai_status.add_theme_color_override("font_color", Color(0.85, 0.82, 0.55))


func _clear_status() -> void:
	_ai_status.text = ""
	_ai_status.add_theme_color_override("font_color", Color(0.75, 0.78, 0.72, 1))
