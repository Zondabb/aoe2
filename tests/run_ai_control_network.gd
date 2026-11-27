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
	for private_order in [{"op":"ai_instruction","text":"private"}, {"op":"set_ai_control","enabled":true}, {"op":"ai_control_state","states":{}}]:
		check(not host._queue_command(private_order, 1), "private controls cannot enter the gameplay queue")
		check(not host.execute_team_command(private_order, 1), "network input cannot change local takeover")
	control.states["0"].message = "private diagnostic"
	host._begin_host_frame()
	check(not JSON.stringify(host._frame_commands).contains("private"), "status stays out of completed frames")
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(not packet.has("ai_control") and not JSON.stringify(packet).contains("private"), "snapshot contains only game state")
	check(guest.apply_snapshot(packet, 1) and replica.remote_updates == 0, "restoring the world preserves local controller")
	var transport := host.session as SessionStub
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
