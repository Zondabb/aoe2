extends Node

## Matchmaking transport. Simulation and scene ownership stay in NetworkMatch.
signal status_changed(message: String)
signal matched(info: Dictionary)
signal started()
signal message_received(message: Dictionary)
signal ended(info: Dictionary)
## Emitted just before ended for a delivered match result. Replicas execute the
## frames still queued ahead of it so every peer reports the final tick.
signal ending(info: Dictionary)

const CONNECT_TIMEOUT := 12.0
const RECEIVE_TIMEOUT := 25.0
const READY_TIMEOUT := 40.0
const PING_INTERVAL := 8.0
const PLAYING_PING_INTERVAL := 20.0
const PROTOCOL_VERSION := 10
const WireCodec := preload("res://scripts/network/wire_codec.gd")
const SnapshotCodec := preload("res://scripts/network/snapshot_codec.gd")
const TICK_RATE := 30
const FRAME_TICKS := 3
const MAX_FRAME_COMMANDS := 64
const MAX_COMMAND_BYTES := 16 * 1024
const MAX_MESSAGE_BYTES := 4 * 1024 * 1024
## A complete resumable keyframe is larger than a presentation snapshot.
const INBOUND_BUFFER_BYTES := MAX_MESSAGE_BYTES * 4
const MAX_PACKETS_PER_FRAME := 32
const RECEIVE_BUDGET_USEC := 4000

var state := "idle"
var team := -1
var host_team := -1
var match_info: Dictionary = {}
var server_url := "ws://127.0.0.1:8001/ws"
var last_status := ""
var last_result: Dictionary = {}
var spectator := false
var latest_snapshot: Dictionary = {}
var _peer: WebSocketPeer
var _join_message: Dictionary = {}
var _state_elapsed := 0.0
var _receive_elapsed := 0.0
var _ping_elapsed := 0.0
var _command_seq := 0
var _ready_sent := false
var _last_poll_usec := -1
var last_close_code := -1
var last_close_reason := ""


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
	_peer.inbound_buffer_size = INBOUND_BUFFER_BYTES
	_peer.outbound_buffer_size = MAX_MESSAGE_BYTES * 2
	var err := _peer.connect_to_url(server_url)
	if err != OK:
		_peer = null
		_set_status("无法连接联机服务器：%s" % error_string(err))
		return err
	_join_message = {"type": "join_queue", "protocol_version": PROTOCOL_VERSION, "name": name_text, "civ": civ}
	state = "connecting"
	_state_elapsed = 0.0
	_receive_elapsed = 0.0
	_ping_elapsed = 0.0
	_last_poll_usec = Time.get_ticks_usec()
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
	if state != "playing" or team not in [0, 1] or not _valid_command(command):
		return false
	_command_seq += 1
	return send_scheduled_command(command, _command_seq, 0, 30)


func send_scheduled_command(command: Dictionary, seq: int, source: int, target: int) -> bool:
	if state != "playing" or not _valid_command(command): return false
	return send_command_batch([command], seq, source, target)


func send_command_batch(commands: Array, seq: int, source: int, target: int) -> bool:
	if state != "playing" or team not in [0, 1] or not _valid_batch(commands): return false
	if not _wire_integer(seq, 1) or not _wire_integer(seq + commands.size() - 1, 1) or not _valid_tick(source) or not _valid_tick(target, false) or target <= source or target > source + 180: return false
	var message := {"type": "command_batch", "team": team, "seq": seq, "source_tick": source, "execute_tick": target, "commands": commands}
	var raw := WireCodec.encode_packet(message)
	if raw.is_empty(): return false
	_command_seq = maxi(_command_seq, seq + commands.size() - 1)
	return _send_binary(raw)


func send_fair_message(message: Dictionary) -> bool:
	if state != "playing" or team not in [0, 1]: return false
	var kind := str(message.get("type", ""))
	if kind in ["sync_init", "schedule", "heartbeat"] and not is_host(): return false
	if kind in ["schedule_ack", "heartbeat_ack"] and is_host(): return false
	if kind not in ["sync_init", "schedule", "schedule_ack", "heartbeat", "heartbeat_ack", "clock_probe", "clock_reply"]: return false
	var raw := WireCodec.encode_packet(message)
	if raw.is_empty(): return false
	return _send_binary(raw)


func send_heartbeat_ack(ack_tick: int, csum32: int, echo_usec32: int) -> bool:
	if state != "playing" or is_host() or not _valid_tick(ack_tick): return false
	return send_fair_message({"type": "heartbeat_ack", "ack_tick": ack_tick, "checksum32": csum32, "echo_usec32": echo_usec32})


func is_host() -> bool:
	return team in [0, 1] and team == host_team


func request_keyframe() -> bool:
	if state != "playing" or is_host(): return false
	return _send({"type": "request_keyframe"})


func send_keyframe(request_id: String, tick: int, full_state: Dictionary, checksum: String) -> bool:
	if not is_host() or state != "playing" or not _valid_request_id(request_id) or not _valid_tick(tick) or full_state.is_empty() or not _valid_checksum(checksum):
		return false
	var message := {"type": "keyframe", "request_id": request_id, "tick": tick, "checksum": checksum}
	var compressed := SnapshotCodec.encode(full_state)
	if compressed.is_empty(): return false
	message.merge(compressed)
	return _send(message)


func send_snapshot(_snapshot: Dictionary) -> void:
	pass


func finish_match(winner: int, at_tick := -1) -> void:
	if is_host() and state == "playing" and winner in [0, 1]:
		var message := {"type": "finish_match", "winner": winner}
		if at_tick >= 0 and _valid_tick(at_tick):
			message["tick"] = at_tick
		_send(message)


func leave() -> void:
	if _peer != null:
		_send({"type": "leave"})
		_peer.close(1000, "leaving")
		_peer = null
	state = "idle"
	team = -1
	host_team = -1
	match_info = {}
	_join_message = {}
	_command_seq = 0
	_ready_sent = false
	spectator = false
	latest_snapshot = {}
	_last_poll_usec = -1


func _process(_delta: float) -> void:
	if _peer == null:
		return
	var now := Time.get_ticks_usec()
	var wall_delta := maxf(0.0, float(now - _last_poll_usec) / 1000000.0) if _last_poll_usec >= 0 else 0.0
	_last_poll_usec = now
	_state_elapsed += wall_delta
	_receive_elapsed += wall_delta
	_ping_elapsed += wall_delta
	_peer.poll()
	var ready_state := _peer.get_ready_state()
	if ready_state == WebSocketPeer.STATE_OPEN:
		if not _join_message.is_empty():
			_send(_join_message)
			_join_message = {}
		var receive_started := Time.get_ticks_usec()
		var processed := 0
		while _peer != null and _peer.get_available_packet_count() > 0 and processed < MAX_PACKETS_PER_FRAME:
			if processed > 0 and Time.get_ticks_usec() - receive_started >= RECEIVE_BUDGET_USEC: break
			var packet := _peer.get_packet()
			var is_text := _peer.was_string_packet()
			processed += 1
			if packet.size() > MAX_MESSAGE_BYTES:
				_fail("服务器消息超出大小限制")
				return
			if is_text:
				var parsed: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if parsed is not Dictionary:
					_fail("服务器返回了无效消息")
					return
				_receive_elapsed = 0.0
				_handle_message(parsed)
			else:
				if state != "playing":
					_fail("服务器返回了未预期的二进制消息")
					return
				var decoded := WireCodec.decode_packet(packet, team)
				if decoded.is_empty() or not _valid_binary_message(decoded):
					_fail("服务器返回了无效的同步数据包")
					return
				_receive_elapsed = 0.0
				message_received.emit(decoded)
		if _peer == null:
			return
		var ping_interval := PLAYING_PING_INTERVAL if state == "playing" else PING_INTERVAL
		if _ping_elapsed >= ping_interval:
			_ping_elapsed = 0.0
			_send({"type": "ping"})
	elif ready_state == WebSocketPeer.STATE_CLOSED:
		last_close_code = _peer.get_close_code()
		last_close_reason = _peer.get_close_reason()
		var detail := "关闭码 %d" % last_close_code
		if not last_close_reason.is_empty(): detail += "，" + last_close_reason
		_fail("与联机服务器的连接已断开（%s）" % detail)
		return
	if state == "connecting" and _state_elapsed > CONNECT_TIMEOUT:
		_fail("连接服务器超时，请检查服务器地址")
	elif state == "matched" and _state_elapsed > READY_TIMEOUT:
		_fail("等待对手载入超时")
	elif _receive_elapsed > RECEIVE_TIMEOUT:
		_fail("联机连接超时，对局已暂停")


func _handle_message(message: Dictionary) -> void:
	if message.get("type") is not String:
		_fail("服务器返回了无效消息")
		return
	match String(message.get("type", "")):
		"queued":
			if state != "connecting": return
			state = "queued"
			_state_elapsed = 0.0
			_set_status("正在匹配对手…")
		"queue_cancelled":
			leave()
			_set_status("匹配等待超时，请重试" if message.get("reason") == "queue_timeout" else "已取消匹配")
		"match_found":
			if state not in ["connecting", "queued"]:
				return
			if not _valid_wire_team(message.get("team")) or not _valid_match(message):
				_fail("服务器返回了无效的对局信息")
				return
			team = int(message.team)
			host_team = int(message.host_team)
			match_info = message.duplicate(true)
			state = "matched"
			_state_elapsed = 0.0
			_set_status("匹配成功，正在载入对局…")
			matched.emit(match_info)
		"start":
			if state != "matched":
				return
			if message.get("match_id") != match_info.get("match_id") or not _same_match_parameters(message):
				_fail("开局消息与当前对局不一致")
				return
			state = "playing"
			_state_elapsed = 0.0
			_set_status("联机对战中")
			started.emit()
		"match_ended":
			if state not in ["matched", "playing"] or message.get("match_id") != match_info.get("match_id"):
				return
			if message.get("winner") != null and not _valid_wire_team(message.winner):
				_fail("服务器返回了无效的对局结果")
				return
			if message.has("tick") and not _valid_tick(message.get("tick")):
				_fail("服务器返回了无效的终局 tick")
				return
			state = "idle"
			var result := message.duplicate(true)
			if result.get("winner") == null:
				result["winner"] = -1
			var reason := String(message.get("reason", "finished"))
			var notice := "对局已结束"
			if reason in ["opponent_left", "disconnect", "opponent_disconnected"]:
				notice = "对手已离开，对局结束"
				var cause := String(message.get("disconnect_reason", ""))
				if not cause.is_empty(): notice = "对局因连接中断而结束：" + _connection_reason(cause)
			elif reason == "ready_timeout":
				notice = "等待对手载入超时，对局结束"
			result["message"] = notice
			last_result = result.duplicate(true)
			_set_status(notice)
			ending.emit(result)
			ended.emit(result)
		"error":
			if state == "playing" and message.get("code") in ["keyframe_timeout", "keyframe_rate_limited"]:
				_set_status("正在重试关键帧同步…")
				message_received.emit(message)
				return
			var code := String(message.get("code", ""))
			var text := _connection_reason(code) if code in ["rate_limited", "slow_consumer", "idle_timeout", "send_timeout"] else String(message.get("message", "未知错误"))
			_fail("联机服务错误：%s" % text)
		"keyframe_request", "keyframe":
			if state != "playing": return
			if message.type == "keyframe" and message.has("codec"):
				var decoded := SnapshotCodec.decode(message)
				if decoded.is_empty():
					_fail("服务器返回了无效的压缩关键帧")
					return
				message = {"type": "keyframe", "request_id": message.get("request_id"), "tick": message.get("tick"), "checksum": message.get("checksum"), "state": decoded}
			if not _valid_incremental_message(message):
				_fail("服务器返回了无效的增量同步消息")
				return
			message_received.emit(message)
		"snapshot":
			if state in ["matched", "playing"]:
				_fail("联机协议版本不兼容，请更新游戏客户端和联机服务")


func _same_match_parameters(message: Dictionary) -> bool:
	for key in ["protocol_version", "host_team", "seed", "tick_rate", "frame_ticks"]:
		if not message.has(key) or message[key] != match_info.get(key): return false
	return true


func _valid_match(message: Dictionary) -> bool:
	if not _valid_request_id(message.get("match_id")) or not _valid_wire_team(message.get("host_team")):
		return false
	if not _wire_integer(message.get("protocol_version"), PROTOCOL_VERSION, PROTOCOL_VERSION) or not _wire_integer(message.get("tick_rate"), TICK_RATE, TICK_RATE) or not _wire_integer(message.get("frame_ticks"), FRAME_TICKS, FRAME_TICKS) or not _wire_integer(message.get("seed")):
		return false
	var roster: Variant = message.get("players")
	if roster is not Array or roster.size() != 2: return false
	var teams := {}
	for player in roster:
		if player is not Dictionary or not _valid_wire_team(player.get("team")) or player.get("name") is not String or player.get("civ") not in ["chinese", "teutons"]: return false
		teams[int(player.team)] = true
	return teams.size() == 2


func _valid_binary_message(message: Dictionary) -> bool:
	match message.type:
		"clock_probe", "clock_reply":
			return _valid_wire_team(message.get("team")) and int(message.team) != team and _wire_integer(message.get("nonce"), 1) and _wire_integer(message.get("sent_usec")) and (message.type == "clock_probe" or _wire_integer(message.get("received_usec")))
		"sync_init", "schedule", "heartbeat":
			return not is_host()
		"command_batch":
			return is_host() and _valid_wire_team(message.get("team")) and _valid_batch(message.get("commands"))
		"schedule_ack", "heartbeat_ack":
			return is_host() and _valid_wire_team(message.get("team")) and int(message.team) != host_team
	return false


func _valid_incremental_message(message: Dictionary) -> bool:
	match message.type:
		"keyframe_request":
			return is_host() and _valid_request_id(message.get("request_id"))
		"keyframe":
			return not is_host() and _valid_request_id(message.get("request_id")) and _valid_tick(message.get("tick")) and message.get("state") is Dictionary and not message.state.is_empty() and _valid_checksum(message.get("checksum"))
	return _valid_binary_message(message)


func _valid_batch(value: Variant) -> bool:
	if value is not Array or value.is_empty() or value.size() > 64: return false
	for command in value:
		if not _valid_command(command): return false
	return true


func _wire_integer(value: Variant, minimum := 0, maximum := 9007199254740991) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and float(value) >= minimum and float(value) <= maximum


func _valid_tick(value: Variant, allow_zero := true) -> bool:
	return _wire_integer(value, 0 if allow_zero else FRAME_TICKS) and int(value) % FRAME_TICKS == 0


func _valid_checksum(value: Variant) -> bool:
	return _valid_hex(value, 64)


func _valid_request_id(value: Variant) -> bool:
	return _valid_hex(value, 32)


func _valid_hex(value: Variant, length: int) -> bool:
	if value is not String or value.length() != length: return false
	for character in value:
		if character not in "0123456789abcdef": return false
	return true


func _valid_command(value: Variant) -> bool:
	if value is not Dictionary or value.is_empty() or value.size() > 10 or value.get("op") is not String: return false
	if value.op.is_empty() or value.op.length() > 64: return false
	for key in ["team", "player_id", "match_id", "host_team"]:
		if value.has(key): return false
	if value.op in ["set_ai_control", "ai_control_state", "ai_instruction"]: return false
	return JSON.stringify(value, "", true, true).to_utf8_buffer().size() <= MAX_COMMAND_BYTES


func _valid_wire_team(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and int(value) in [0, 1]


func _connection_reason(code: String) -> String:
	return {
		"rate_limited": "状态同步发送过快，超过服务流量限制",
		"slow_consumer": "接收端处理过慢，状态同步队列已满",
		"idle_timeout": "连接心跳超时",
		"send_timeout": "服务发送状态超时",
		"connection_closed": "客户端连接断开",
	}.get(code, code)


func _send(message: Dictionary) -> bool:
	if message.get("type") == "snapshot": return false
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var payload := JSON.stringify(message, "", true, true)
	if payload.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return false
	if _peer.send_text(payload) == OK:
		_ping_elapsed = 0.0
		return true
	return false


func _send_binary(payload: PackedByteArray) -> bool:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	if payload.is_empty() or payload.size() > MAX_MESSAGE_BYTES:
		return false
	if _peer.send(payload, WebSocketPeer.WRITE_MODE_BINARY) == OK:
		_ping_elapsed = 0.0
		return true
	return false


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
