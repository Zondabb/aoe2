extends Node

const GameSettingsScript := preload("res://scripts/core/game_settings.gd")

var player_civ_id: StringName = &"chinese"
var ai_civ_id: StringName = &"teutons"
## Empty snapshot selects the generated classic land map. A match never rereads the file.
var match_map_data: Dictionary = {}
var selected_map_path := ""
var match_ai_mode := "gateway"
var menu_notice := ""
## Online matches keep world teams stable; this client's team can be either side.
var online_active := false
var online_team := 0
var online_server_url := "ws://127.0.0.1:8001/ws"
var online_player_name := "玩家"
var online_civ_id: StringName = &"chinese"
var online_return_to_lobby := false
## AI HTTP 服务根地址；空则使用内嵌 LocalAiServer 默认端口。
var ai_service_url := ""
## Chat Completions 完整 URL；空则由 service_url 拼接 /v1/chat/completions。
var ai_chat_url := ""
var ai_service_timeout_sec := 2.0
var ai_tick_interval_sec := 0.5
var ai_use_local_embedded := true
## v1_tick | v2_chat
var ai_protocol := "v1_tick"
## 与 ai_protocol 同步的整数版本（tick 载荷 protocol_version）。
var ai_protocol_version := 1
## Bearer token（cfg api_token / AOE2_AI_TOKEN / UI）。
var ai_service_token := ""
var ai_backend := "rules_compat"
var ai_model := "aoe2-rules-v1"
var ai_max_tokens := 2048
var ai_use_tick_batch := true
## Recent assistant summaries kept per team (0 = off).
var ai_history_turns := 0
var ai_log_observation := false
var ai_llm_base_url := ""


func _ready() -> void:
	GameSettingsScript.apply_from_config()

func local_team() -> int:
	return online_team if online_active else Enums.Team.PLAYER
