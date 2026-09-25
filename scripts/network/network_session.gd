extends Node

## Matchmaking transport. Simulation and scene ownership stay in NetworkMatch.
signal status_changed(message: String)
signal matched(info: Dictionary)
signal started()
signal message_received(message: Dictionary)
signal ended(info: Dictionary)

const CONNECT_TIMEOUT := 12.0
const RECEIVE_TIMEOUT := 25.0
const READY_TIMEOUT := 40.0
const PING_INTERVAL := 8.0
const MAX_MESSAGE_BYTES := 512 * 1024

var state := "idle"
var team := -1
var match_info: Dictionary = {}
var server_url := "ws://127.0.0.1:8001/ws"
var last_status := ""
var last_result: Dictionary = {}
var _peer: WebSocketPeer
var _join_message: Dictionary = {}
var _state_elapsed := 0.0
var _receive_elapsed := 0.0
var _ping_elapsed := 0.0
var _command_seq := 0
var _snapshot_seq := 0
var _ready_sent := false


func join_queue(url: String, player_name: String, civ: String) -> Error:
	leave()
	last_result = {}
	server_url = url.strip_edges()
	if not (server_url.begins_with("ws://") or server_url.begins_with("wss://")):
		_set_status("服务器地址必须以 ws:// 或 wss:// 开头")
		return ERR_INVALID_PARAMETER
	if civ not in ["chinese", "teutons"]:
		_set_status("不支持的文明")
		return ERR_INVALID_PARAMETER
	var name_text := player_name.strip_edges().left(24)
	if name_text.is_empty():
		name_text = "玩家"
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = MAX_MESSAGE_BYTES * 2
	_peer.outbound_buffer_size = MAX_MESSAGE_BYTES * 2
	var err := _peer.connect_to_url(server_url)
	if err != OK:
		_peer = null
		_set_status("无法连接联机服务器：%s" % error_string(err))
		return err
	_join_message = {"type": "join_queue", "protocol_version": 1, "name": name_text, "civ": civ}
	state = "connecting"
	_state_elapsed = 0.0
	_receive_elapsed = 0.0
	_ping_elapsed = 0.0
	_set_status("正在连接联机服务器…")
	return OK


func cancel_queue() -> void:
	# Closing also cancels a join whose response is still in flight.
	_send({"type": "cancel_queue"})
	leave()
	_set_status("已取消匹配")


func send_ready() -> void:
	if state == "matched" and not _ready_sent:
		_ready_sent = _send({"type": "ready"})
		_set_status("地图已载入，等待对手…")


func send_command(command: Dictionary) -> bool:
	if state != "playing" or team == 0:
		return false
	_command_seq += 1
	return _send({"type": "command", "seq": _command_seq, "command": command})


func send_snapshot(snapshot: Dictionary) -> void:
	if state != "playing" or team != 0:
		return
	_snapshot_seq += 1
	if not _send({"type": "snapshot", "seq": _snapshot_seq, "state": snapshot}):
		_fail("状态同步发送失败，请检查网络连接")


func finish_match(winner: int) -> void:
	if state == "playing" and team == 0:
		_send({"type": "finish_match", "winner": winner})


func leave() -> void:
	if _peer != null:
		_send({"type": "leave"})
		_peer.close(1000, "leaving")
		_peer = null
	state = "idle"
	team = -1
	match_info = {}
	_join_message = {}
	_command_seq = 0
	_snapshot_seq = 0
	_ready_sent = false


func _process(delta: float) -> void:
	if _peer == null:
		return
	_state_elapsed += delta
	_receive_elapsed += delta
	_ping_elapsed += delta
	_peer.poll()
	var ready_state := _peer.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN:
		if not _join_message.is_empty():
			_send(_join_message)
			_join_message = {}
		while _peer != null and _peer.get_available_packet_count() > 0:
			var packet := _peer.get_packet()
			if packet.size() > MAX_MESSAGE_BYTES:
				_fail("服务器消息超出大小限制")
				return
			var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if parsed is not Dictionary:
				_fail("服务器返回了无效消息")
				return
			_receive_elapsed = 0.0
			_handle_message(parsed)
		if _peer == null:
			return
		if _ping_elapsed >= PING_INTERVAL:
			_ping_elapsed = 0.0
			_send({"type": "ping"})
	elif ready_state == WebSocketPeer.STATE_CLOSED:
		_fail("与联机服务器的连接已断开")
		return
	if state == "connecting" and _state_elapsed > CONNECT_TIMEOUT:
		_fail("连接服务器超时，请检查服务器地址")
	elif state == "matched" and _state_elapsed > READY_TIMEOUT:
		_fail("等待对手载入超时")
	elif _receive_elapsed > RECEIVE_TIMEOUT:
		_fail("联机连接超时，对局已暂停")


func _handle_message(message: Dictionary) -> void:
	match String(message.get("type", "")):
		"queued":
			state = "queued"
			_state_elapsed = 0.0
			_set_status("正在匹配对手…")
		"queue_cancelled":
			leave()
			_set_status("匹配等待超时，请重试" if message.get("reason") == "queue_timeout" else "已取消匹配")
		"match_found":
			if state not in ["connecting", "queued"]:
				return
			team = int(message.get("team", -1))
			if team not in [0, 1] or int(message.get("host_team", -1)) != 0:
				_fail("服务器返回了无效的对局信息")
				return
			match_info = message.duplicate(true)
			state = "matched"
			_state_elapsed = 0.0
			_set_status("匹配成功，正在载入对局…")
			matched.emit(match_info)
		"start":
			if state != "matched":
				return
			state = "playing"
			_state_elapsed = 0.0
			_set_status("联机对战中")
			started.emit()
		"match_ended":
			state = "idle"
			var result := message.duplicate(true)
			if result.get("winner") == null:
				result["winner"] = -1
			var reason := String(message.get("reason", "finished"))
			var notice := "对局已结束"
			if reason in ["opponent_left", "disconnect", "opponent_disconnected"]:
				notice = "对手已离开，对局结束"
			elif reason == "ready_timeout":
				notice = "等待对手载入超时，对局结束"
			result["message"] = notice
			last_result = result.duplicate(true)
			_set_status(notice)
			ended.emit(result)
		"error":
			_fail("联机服务错误：%s" % String(message.get("message", "未知错误")))
		"command", "snapshot":
			if state == "playing":
				message_received.emit(message)


func _send(message: Dictionary) -> bool:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var payload := JSON.stringify(message)
	if payload.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return false
	return _peer.send_text(payload) == OK


func _fail(message: String) -> void:
	var was_active := state != "idle"
	leave()
	_set_status(message)
	if was_active:
		last_result = {"winner": -1, "reason": "connection_error", "message": message}
		ended.emit(last_result)


func _set_status(message: String) -> void:
	last_status = message
	status_changed.emit(message)
