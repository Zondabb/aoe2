extends Node

## Player opt-in control. Each player connects their own external service.
signal state_changed
## Lines the premier of `team` has just said (see AiGateway.premier_spoke). A player is shown only their own team's.
signal premier_spoke(team: int, lines: Array)

const Gateway := preload("res://scripts/ai_gateway/ai_gateway.gd")
const Config := preload("res://scripts/ai_gateway/ai_config.gd")
const Commands := preload("res://scripts/input/player_commands.gd")
const Settings := preload("res://scripts/core/game_settings.gd")

var match_state: MatchState
var entities: Node2D
var local_team := 0
var online := false
var _civs: Dictionary = {}
var _gateways: Dictionary = {}
var _states: Dictionary = {
	"0": {"enabled": false, "status": "off", "message": "手动操作"},
	"1": {"enabled": false, "status": "off", "message": "手动操作"},
}
var _elapsed := 0.0
var _ended := false
var _last_available := false


func setup(bootstrap: Node) -> void:
	match_state = bootstrap.match_state
	entities = bootstrap.get_parent().get_node("Entities")
	local_team = Commands.local_team(self)
	online = Commands.is_online(self)
	_civs = {0: bootstrap.player_civ, 1: bootstrap.ai_civ}
	match_state.winner_decided.connect(func(_winner: int): stop_all())
	state_changed.emit()


func local_state() -> Dictionary:
	var result: Dictionary = _states[str(local_team)].duplicate(true)
	result["available"] = _available()
	return result


func request_local_enabled(value: bool) -> bool:
	return set_team_enabled(local_team, value)


func request_local_instruction(message: String) -> bool:
	var state := local_state()
	if not state.available or not state.enabled or state.status != "active": return false
	var instruction := message.strip_edges()
	if instruction.is_empty() or message.length() > AiProtocol.MAX_PLAYER_INSTRUCTION_LENGTH: return false
	return accept_instruction(local_team, instruction)

func accept_instruction(team: int, message: String) -> bool:
	if team != local_team or not _available() or not _gateways.has(team): return false
	var gateway: AiGateway = _gateways[team]
	return gateway.add_player_instruction(team, message)

func set_team_enabled(team: int, value: bool) -> bool:
	if team not in [0, 1] or team != local_team:
		return false
	if value and not _available():
		return false
	if not value:
		_remove_gateway(team)
		_set_state(team, false, "ended" if _ended else "off", "对局已结束" if _ended else "手动操作")
		return true
	if _gateways.has(team):
		return true
	var config := external_config(team)
	var gateway := Gateway.new()
	# Unique nodes prevent a cancelled, queued-for-deletion instance from being reused.
	add_child(gateway)
	gateway.premier_spoke.connect(_on_premier_spoke)
	_gateways[team] = gateway
	_set_state(team, true, "connecting", "正在连接 Python LLM…")
	gateway.setup(match_state, entities, [{
		"team": team, "enemy_team": 1 - team, "civ": _civs[team],
		"label": "玩家 %d 托管" % (team + 1),
	}], config)
	gateway.match_time = _elapsed
	return true


static func external_config(team: int = -1) -> AiConfig:
	var config := Config.from_game_session()
	config.use_local_embedded = false
	config.protocol = Config.PROTOCOL_V2_CHAT
	config.protocol_version = 2
	config.use_tick_batch = false
	if config.service_url.is_empty():
		config.service_url = Config.default_service_url()
	if team in [0, 1]:
		var team_url := Settings.normalize_ai_service_url(str(GameSession.ai_team_service_urls.get(team, "")))
		var shared_url := Settings.normalize_ai_service_url(config.service_url)
		config.service_url = team_url if not team_url.is_empty() else shared_url
		if config.service_url.is_empty():
			config.service_url = Config.default_service_url()
		var token := str(GameSession.ai_team_service_tokens.get(team, "")).strip_edges()
		if not token.is_empty():
			config.api_token = token
		# A shared legacy chat endpoint must not redirect a team's selected service.
		config.chat_url = ""
	config.finalize_urls()
	return config


func team_service_url(team: int) -> String:
	if team not in [0, 1]:
		return ""
	if online and team != local_team: return ""
	return external_config(team).service_url


func request_team_service_url(team: int, url: String) -> bool:
	if team not in [0, 1] or team != local_team or _ended: return false
	var normalized := Settings.normalize_ai_service_url(url)
	if normalized.is_empty():
		return false
	if normalized == team_service_url(team):
		return true
	var was_enabled := bool(_states[str(team)].enabled)
	# Stop cancels requests and invalidates callbacks before the replacement is started.
	_remove_gateway(team)
	GameSession.ai_team_service_urls[team] = normalized
	_set_state(team, false, "off", "手动操作")
	if was_enabled:
		if not set_team_enabled(team, true):
			_set_state(team, false, "error", "服务地址已更新，请重新开启托管")
	state_changed.emit()
	return true


func stop_all() -> void:
	_ended = true
	for team in _gateways.keys():
		_remove_gateway(team)
	for team in [0, 1]:
		_set_state(team, false, "ended", "对局已结束")


func _exit_tree() -> void:
	for gateway in _gateways.values():
		if is_instance_valid(gateway):
			gateway.stop()
	_gateways.clear()


func _process(delta: float) -> void:
	_elapsed += delta
	var available := _available()
	if available != _last_available:
		_last_available = available
		state_changed.emit()
	if match_state == null or _ended:
		return
	if match_state.winner != -1:
		stop_all()
		return
	for team in _gateways.keys():
		var gateway: AiGateway = _gateways[team]
		if not gateway.enabled:
			var status := gateway.service_status
			_remove_gateway(team)
			var message := "Python 服务连接失败，请启动服务后重试"
			if status == "unauthorized":
				message = "Python 服务认证失败，请检查 AI 服务 token"
			_set_state(team, false, "error", message)
		elif gateway.service_status == "online":
			_set_state(team, true, "active", "Python LLM 托管中")


func _available() -> bool:
	if match_state == null or _ended or match_state.frozen or match_state.winner != -1:
		return false
	if online:
		var network := Commands.runtime(self)
		return network != null and not bool(network.get("spectator")) and bool(network.get("_playing")) and bool(network.get("synchronized")) and not bool(network.get("_terminal"))
	return true


func _on_premier_spoke(team: int, lines: Array) -> void:
	if _ended or (online and team != local_team): return
	premier_spoke.emit(team, lines)


func _remove_gateway(team: int) -> void:
	var gateway: Node = _gateways.get(team)
	_gateways.erase(team)
	if is_instance_valid(gateway):
		gateway.stop()
		gateway.queue_free()


func _set_state(team: int, enabled: bool, status: String, message: String) -> void:
	var value := {"enabled": enabled, "status": status, "message": message}
	if _states[str(team)] == value:
		return
	_states[str(team)] = value
	state_changed.emit()
