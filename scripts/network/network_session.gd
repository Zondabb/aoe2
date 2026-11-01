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
signal matches_received(matches: Array)

const CONNECT_TIMEOUT := 12.0
const RECEIVE_TIMEOUT := 25.0
const READY_TIMEOUT := 40.0
const PING_INTERVAL := 8.0
const PROTOCOL_VERSION := 3
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
## A spectator has no team or command authority, regardless of selected view.
var spectator := false
## Kept empty for old diagnostic scripts; protocol v3 never caches snapshots.
var latest_snapshot: Dictionary = {}
var _peer: WebSocketPeer
var _join_message: Dictionary = {}
var _state_elapsed := 0.0
var _receive_elapsed := 0.0
var _ping_elapsed := 0.0
var _command_seq := 0
var _ready_sent := false
var _watch_ready_sent := false
var _intent := "queue"
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
	_intent = "queue"
	state = "connecting"
	_state_elapsed = 0.0
	_receive_elapsed = 0.0
	_ping_elapsed = 0.0
	_last_poll_usec = Time.get_ticks_usec()
	_set_status("正在连接联机服务器…")
	return OK


func request_matches(url: String) -> Error:
	if state in ["queued", "matched", "playing", "watching"]:
		return ERR_BUSY
	if state == "connecting" and _intent == "watch": return ERR_BUSY
	var requested := url.strip_edges()
	if state == "browsing" and requested == server_url:
		return OK if _send({"type": "list_matches"}) else ERR_CONNECTION_ERROR
	if state == "connecting" and _intent == "browse" and requested == server_url:
		return OK
	return _connect_request(requested, {"type": "list_matches"}, "browse")


func watch_match(url: String, match_id: String) -> Error:
	if state in ["queued", "matched", "playing", "watching"]:
		return ERR_BUSY
	if match_id.strip_edges().is_empty() or match_id.length() > 128:
		return ERR_INVALID_PARAMETER
	var requested := url.strip_edges()
	var message := {"type": "watch_match", "match_id": match_id}
	if state == "browsing" and requested == server_url:
		_intent = "watch"
		_state_elapsed = 0.0
		if _send(message):
			state = "connecting"
			_set_status("正在加入观战…")
			return OK
		return ERR_CONNECTION_ERROR
	return _connect_request(requested, message, "watch")


func _connect_request(url: String, message: Dictionary, intent: String) -> Error:
	leave()
	last_result = {}
	server_url = url
	if not (server_url.begins_with("ws://") or server_url.begins_with("wss://")):
		_set_status("服务器地址必须以 ws:// 或 wss:// 开头")
		return ERR_INVALID_PARAMETER
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = INBOUND_BUFFER_BYTES
	_peer.outbound_buffer_size = MAX_MESSAGE_BYTES * 2
	var error := _peer.connect_to_url(server_url)
	if error != OK:
		_peer = null
		_set_status("无法连接联机服务器：%s" % error_string(error))
		return error
	_join_message = message
	_intent = intent
	state = "connecting"
	_state_elapsed = 0.0
	_receive_elapsed = 0.0
	_ping_elapsed = 0.0
	_last_poll_usec = Time.get_ticks_usec()
	_set_status("正在连接观战服务…")
	return OK


func cancel_queue() -> void:
	# Closing also cancels a join whose response is still in flight.
	_send({"type": "cancel_queue"})
	leave()
	_set_status("已取消匹配")


func send_ready() -> void:
	if not spectator and _intent == "queue" and state == "matched" and not _ready_sent:
		_ready_sent = _send({"type": "ready"})
		_set_status("地图已载入，等待对手…")


func send_watch_ready() -> bool:
	if not spectator or state != "watching" or _intent != "watch": return false
	if _watch_ready_sent: return true
	_watch_ready_sent = _send({"type": "watch_ready"})
	return _watch_ready_sent


func send_command(command: Dictionary) -> bool:
	if spectator or _intent != "queue" or state != "playing" or team not in [0, 1] or not _valid_command(command):
		return false
	_command_seq += 1
	return _send({"type": "command", "seq": _command_seq, "command": command})


func is_host() -> bool:
	return not spectator and team in [0, 1] and team == host_team


func send_frame(tick: int, commands: Array, checksum: String) -> bool:
	if not is_host() or state != "playing" or not _valid_tick(tick, false) or not _valid_commands(commands) or not _valid_checksum(checksum):
		return false
	# Delta frames are ordered and indispensable. A failed send is reported to
	# NetworkMatch; neither buffering pressure nor a newer frame may discard one.
	return _send({"type": "frame", "tick": tick, "commands": commands, "checksum": checksum})


func send_ack(tick: int, checksum: String) -> bool:
	if state not in ["playing", "watching"] or is_host() or not _valid_tick(tick) or not _valid_checksum(checksum):
		return false
	return _send({"type": "ack", "tick": tick, "checksum": checksum})


func request_keyframe() -> bool:
	if state not in ["playing", "watching"] or is_host(): return false
	if spectator and not _watch_ready_sent: return false
	return _send({"type": "request_keyframe"})


func send_keyframe(request_id: String, tick: int, full_state: Dictionary, checksum: String) -> bool:
	if not is_host() or state != "playing" or not _valid_request_id(request_id) or not _valid_tick(tick) or full_state.is_empty() or not _valid_checksum(checksum):
		return false
	return _send({"type": "keyframe", "request_id": request_id, "tick": tick, "state": full_state, "checksum": checksum})


func send_snapshot(_snapshot: Dictionary) -> void:
	# Protocol v1 diagnostics may still reference this method. It deliberately
	# cannot publish a legacy snapshot into a deterministic match.
	pass


func finish_match(winner: int) -> void:
	if is_host() and _intent == "queue" and state == "playing" and winner in [0, 1]:
		_send({"type": "finish_match", "winner": winner})


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
	_watch_ready_sent = false
	spectator = false
	latest_snapshot = {}
	_intent = "queue"
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
			processed += 1
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
		"matches":
			if state not in ["connecting", "browsing"] or _intent != "browse": return
			var matches: Variant = message.get("matches")
			if matches is not Array or matches.size() > 128:
				_fail("服务器返回了无效的对局列表")
				return
			state = "browsing"
			_state_elapsed = 0.0
			_set_status("找到 %d 场正在进行的对局" % matches.size())
			matches_received.emit(matches.duplicate(true))
		"spectate_started":
			if state not in ["connecting", "browsing"] or _intent != "watch": return
			if not _valid_spectator_match(message):
				_fail("服务器返回了无效的观战信息")
				return
			spectator = true
			team = -1
			host_team = int(message.host_team)
			match_info = message.duplicate(true)
			match_info["role"] = "spectator"
			latest_snapshot = {}
			state = "watching"
			_state_elapsed = 0.0
			_set_status("观战连接成功，正在载入对局…")
			matched.emit(match_info)
		"queued":
			if state != "connecting" or _intent != "queue" or spectator: return
			state = "queued"
			_state_elapsed = 0.0
			_set_status("正在匹配对手…")
		"queue_cancelled":
			leave()
			_set_status("匹配等待超时，请重试" if message.get("reason") == "queue_timeout" else "已取消匹配")
		"match_found":
			if spectator or _intent != "queue" or state not in ["connecting", "queued"]:
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
			if state not in ["matched", "playing", "watching"] or message.get("match_id") != match_info.get("match_id"):
				return
			if message.get("winner") != null and not _valid_wire_team(message.winner):
				_fail("服务器返回了无效的对局结果")
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
			# A room can end while its observer finishes loading and sends ready.
			# That stale reply must not replace an already delivered match result.
			if state == "idle" and spectator and not last_result.is_empty(): return
			if state in ["playing", "watching"] and message.get("code") in ["keyframe_timeout", "keyframe_rate_limited"]:
				_set_status("正在重试关键帧同步…")
				message_received.emit(message)
				return
			if _intent in ["browse", "watch"] and not spectator:
				_intent = "browse"
				state = "browsing"
				_state_elapsed = 0.0
				_set_status("观战服务：%s" % String(message.get("message", "无法加入该对局，请刷新列表")))
			else:
				var code := String(message.get("code", ""))
				var text := _connection_reason(code) if code in ["rate_limited", "slow_consumer", "idle_timeout", "send_timeout"] else String(message.get("message", "未知错误"))
				_fail("联机服务错误：%s" % text)
		"command", "frame", "ack", "keyframe_request", "keyframe":
			if state not in ["playing", "watching"]: return
			if not _valid_incremental_message(message):
				_fail("服务器返回了无效的增量同步消息")
				return
			message_received.emit(message)
		"snapshot":
			if state in ["matched", "playing", "watching"]:
				_fail("联机协议版本不兼容，请更新游戏客户端和联机服务")


func _valid_spectator_match(message: Dictionary) -> bool:
	return message.get("role") == "spectator" and _valid_match(message)


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


func _valid_incremental_message(message: Dictionary) -> bool:
	match message.type:
		"command":
			return is_host() and _valid_wire_team(message.get("team")) and _wire_integer(message.get("seq"), 1) and _valid_command(message.get("command"))
		"frame":
			return not is_host() and _valid_tick(message.get("tick"), false) and _valid_commands(message.get("commands")) and _valid_checksum(message.get("checksum"))
		"ack":
			return is_host() and _valid_wire_team(message.get("team")) and int(message.team) != host_team and _valid_tick(message.get("tick")) and _valid_checksum(message.get("checksum"))
		"keyframe_request":
			return is_host() and _valid_request_id(message.get("request_id"))
		"keyframe":
			return not is_host() and _valid_request_id(message.get("request_id")) and _valid_tick(message.get("tick")) and message.get("state") is Dictionary and not message.state.is_empty() and _valid_checksum(message.get("checksum"))
	return false


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
	if value.op == "set_ai_control" and (value.size() != 2 or value.get("enabled") is not bool): return false
	return JSON.stringify(value, "", true, true).to_utf8_buffer().size() <= MAX_COMMAND_BYTES


func _valid_commands(value: Variant) -> bool:
	if value is not Array or value.size() > MAX_FRAME_COMMANDS: return false
	for entry in value:
		if entry is not Dictionary or entry.size() != 2 or not _valid_wire_team(entry.get("team")) or not _valid_command(entry.get("command")): return false
	return true


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
	if (spectator or _intent == "watch") and message.get("type") in ["command", "frame", "keyframe", "ready", "finish_match", "join_queue"]:
		return false
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var payload := JSON.stringify(message, "", true, true)
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
