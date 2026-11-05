extends SceneTree
## Host authority and atomic JSON synchronization for external AI ownership.

const Runtime := preload("res://scripts/network/network_match.gd")
var checks := 0
var failures: Array[String] = []

class ControlStub extends Node:
	var states := {
		"0": {"enabled": false, "status": "idle", "message": "手动控制"},
		"1": {"enabled": false, "status": "idle", "message": "手动控制"},
	}
	var requests: Array = []
	var instructions: Array = []
	func accept_instruction(team: int, text: String) -> bool:
		instructions.append([team, text])
		return true
	var remote_updates := 0
	var stop_count := 0

	func set_team_enabled(team: int, enabled: bool) -> bool:
		requests.append({"team": team, "enabled": enabled})
		states[str(team)] = {"enabled": enabled, "status": "running" if enabled else "idle", "message": "外部 AI 托管" if enabled else "手动控制"}
		return true

	func capture_states() -> Dictionary:
		return states.duplicate(true)

	func apply_remote_states(value: Dictionary) -> void:
		remote_updates += 1
		states = value.duplicate(true)

	func stop_all() -> void:
		stop_count += 1
		for team in ["0", "1"]:
			states[team] = {"enabled": false, "status": "idle", "message": "手动控制"}

class SessionStub extends Node:
	var finished: Array = []

	func finish_match(winner: int) -> bool:
		finished.append(winner)
		return true

	func leave() -> void:
		pass

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func runtime(authority: bool) -> Node:
	var fixture := Node2D.new()
	root.add_child(fixture)
	var control := ControlStub.new()
	control.name = "PlayerAiControl"
	fixture.add_child(control)
	var session := SessionStub.new()
	fixture.add_child(session)
	var value := Runtime.new()
	value.name = "NetworkMatch"
	value.entities = Node2D.new()
	fixture.add_child(value.entities)
	value.match_state = MatchState.new()
	value.match_state.setup_defaults()
	value.is_host = authority
	value.local_team = 0 if authority else 1
	value._playing = true
	value.session = session
	fixture.add_child(value)
	value.set_process(false)
	return value

func _run() -> void:
	var host := runtime(true)
	var guest := runtime(false)
	var control := host.get_parent().get_node("PlayerAiControl") as ControlStub
	var replica := guest.get_parent().get_node("PlayerAiControl") as ControlStub
	check(host._queue_command({"op": "ai_instruction", "text": "多生产一些骑士"}, 1), "guest instruction reaches host queue")
	check(not host._queue_command({"op": "ai_instruction", "text": "采粮", "team": 0}, 1), "guest cannot choose the team")
	host._begin_host_frame()
	check(control.instructions == [[1, "多生产一些骑士"]], "private instruction routed to sender's team")
	check(not JSON.stringify(host._frame_commands).contains("多生产一些骑士"), "instruction stays out of player and spectator frames")
	check(host.execute_team_command({"op": "set_ai_control", "enabled": true}, 1), "guest may enable its own AI on the host")
	check(control.requests == [{"team": 1, "enabled": true}] and control.states["1"].enabled and not control.states["0"].enabled, "sender identity selects only the guest team")
	check(host.execute_team_command({"op": "set_ai_control", "enabled": true}, 0), "host may enable its own AI independently")
	check(control.states["0"].enabled and control.states["1"].enabled, "both players can use external AI concurrently")
	check(host.execute_team_command({"op": "set_ai_control", "enabled": false}, 1), "guest may cancel its own AI")
	check(control.states["0"].enabled and not control.states["1"].enabled, "guest cancellation preserves host AI")
	var count := control.requests.size()
	for command in [
		{"op": "set_ai_control"}, {"op": "set_ai_control", "enabled": 1},
		{"op": "set_ai_control", "enabled": "true"}, {"op": "set_ai_control", "enabled": null},
		{"op": "set_ai_control", "enabled": true, "team": 0},
		{"op": "set_ai_control", "enabled": true, "unit_id": 1},
	]:
		check(not host.execute_team_command(command, 1), "malformed or identity-spoofed AI control is rejected")
	check(not host.execute_team_command({"op": "set_ai_control", "enabled": true}, -1), "unassigned sender cannot change AI control")
	check(not host.execute_team_command({"op": "set_ai_control", "enabled": true}, 2), "unknown team cannot change AI control")
	check(control.requests.size() == count, "rejected controls never reach the AI controller")
	check(not guest.execute_team_command({"op": "set_ai_control", "enabled": true}, 1), "replica cannot execute AI controls locally")
	host.match_state.frozen = true
	check(not host.execute_team_command({"op": "set_ai_control", "enabled": false}, 0), "frozen match rejects controls")
	host.match_state.frozen = false
	host._playing = false
	check(not host.execute_team_command({"op": "set_ai_control", "enabled": false}, 0), "match must be playing to change AI control")
	host._playing = true
	host._terminal = true
	check(not host.execute_team_command({"op": "set_ai_control", "enabled": false}, 0), "ended match rejects controls")
	host._terminal = false
	host._begin_host_frame()
	var transport := host.session as SessionStub
	check(host._frame_commands.any(func(item): return item.command.op == "ai_control_state" and item.command.states == control.states), "accepted control is acknowledged on the next frame")
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(guest.apply_snapshot(packet, 1), "AI control snapshot survives JSON transport")
	check(replica.remote_updates == 1 and replica.states == control.states, "guest UI receives canonical states for both teams")
	var configured := packet.duplicate(true)
	configured.ai_control["0"]["service_url"] = "http://127.0.0.1:8765"
	configured.ai_control["1"]["service_url"] = "http://127.0.0.1:8766"
	var configured_guest := runtime(false)
	check(configured_guest.apply_snapshot(configured, 1), "independent team service URLs survive snapshot validation")
	check(configured_guest.get_parent().get_node("PlayerAiControl").states["1"].service_url == "http://127.0.0.1:8766", "guest receives its host-selected AI service URL")
	configured_guest.get_parent().free()
	var food: int = guest.match_state.resources[0][0]
	var malformed: Array = [
		[], {}, {"0": packet.ai_control["0"]},
		{0: packet.ai_control["0"], 1: packet.ai_control["1"]},
	]
	for field in ["enabled", "status", "message"]:
		var bad: Dictionary = packet.ai_control.duplicate(true)
		bad["1"].erase(field)
		malformed.append(bad)
	for field_value in [["enabled", 1], ["status", []], ["message", []], ["status", "x".repeat(65)], ["message", "x".repeat(257)], ["team", 0]]:
		var bad: Dictionary = packet.ai_control.duplicate(true)
		bad["1"][field_value[0]] = field_value[1]
		malformed.append(bad)
	var extra_team: Dictionary = packet.ai_control.duplicate(true)
	extra_team["2"] = packet.ai_control["0"]
	malformed.append(extra_team)
	for invalid_url in [null, 8766, "http://user:secret@example.com", "file:///etc/passwd", "http://localhost:8766/#fragment", "x".repeat(2049)]:
		var bad: Dictionary = configured.ai_control.duplicate(true)
		bad["1"].service_url = invalid_url
		malformed.append(bad)
	var with_token: Dictionary = configured.ai_control.duplicate(true)
	with_token["1"]["api_token"] = "must-not-sync"
	malformed.append(with_token)
	for value in malformed:
		var invalid := packet.duplicate(true)
		invalid.ai_control = value
		invalid.economies[0].food = food + 99
		check(not guest.apply_snapshot(invalid, 2), "invalid AI state is rejected before world updates")
		check(guest.match_state.resources[0][0] == food and replica.remote_updates == 1 and guest._last_snapshot_sequence == 1, "invalid AI state preserves economy, ownership and sequence")
	check(not guest.apply_snapshot(packet, 1) and replica.remote_updates == 1, "stale snapshots cannot roll back AI ownership")
	var legacy := packet.duplicate(true)
	legacy.erase("ai_control")
	check(guest.apply_snapshot(legacy, 2) and replica.remote_updates == 1, "older snapshots without AI ownership remain compatible")
	host._on_winner(0)
	check(control.stop_count == 1 and not control.states["0"].enabled and not control.states["1"].enabled, "victory stops both external AIs")
	check(transport.finished == [0], "host sends match completion after stopping AI")
	host._on_ended({"winner": -1, "message": "测试断线"})
	check(control.stop_count == 2 and host.match_state.frozen and not host._playing, "disconnect stops AI and freezes the match")
	host.get_parent().free()
	guest.get_parent().free()
	_test_instruction_gateway()
	print("AI CONTROL NETWORK: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_instruction_gateway() -> void:
	var controller = load("res://scripts/ai_gateway/player_ai_control.gd").new()
	root.add_child(controller)
	controller.match_state = MatchState.new()
	controller.match_state.setup_defaults()
	var gateway = load("res://scripts/ai_gateway/ai_gateway.gd").new()
	controller.add_child(gateway)
	gateway._teams.assign([{"team": 0}])
	gateway.service_status = "online"
	controller._gateways[0] = gateway
	controller._set_state(0, true, "active", "")
	check(controller.request_local_instruction("  多生产一些骑士  "), "real player controller accepts active-team text")
	check(not controller.request_local_instruction(" ") and not controller.request_local_instruction("x".repeat(241)), "real controller rejects empty and oversized text")
	check(not controller.accept_instruction(1, "增加食物采集"), "other team has no access to this gateway")
	for message in ["增加食物采集", "防守基地", "升级城堡时代", "优先采金"]:
		check(controller.request_local_instruction(message), "active player may revise plans")
	var expected := ["增加食物采集", "防守基地", "升级城堡时代", "优先采金"]
	var payload: Dictionary = gateway._assemble_tick_payload({}, 1, [], {"team": 0, "civ": null, "time_sec": 1.0, "enemy_team": 1}, {})
	check(payload.observation.player_instructions == expected, "recent four instructions survive ordinary tick assembly")
	check(gateway._assemble_multi_agent_payload(payload, 1).observation.player_instructions == expected, "v3 HTTP payload carries exact player text")
	check(gateway._assemble_chat_payload(payload, 1).observation.player_instructions == expected, "v2 HTTP payload carries exact player text")
	var other: Dictionary = gateway._assemble_tick_payload({}, 1, [], {"team": 1, "civ": null, "time_sec": 1.0, "enemy_team": 0}, {})
	check(not other.observation.has("player_instructions"), "observations keep team instructions separate")
	gateway.stop()
	check(gateway._player_instructions.is_empty() and not controller.request_local_instruction("继续采金"), "stopping a gateway clears directions and prevents late text")
	var network := Runtime.new()
	network.name = "NetworkMatch"
	controller.add_child(network)
	network._playing = true
	controller.online = true
	check(not controller.local_state().available and not controller.request_local_enabled(true), "initial synchronization keeps online takeover unavailable")
	network.synchronized = true
	check(controller.local_state().available, "synchronized peer can request AI takeover")
	controller.free()
