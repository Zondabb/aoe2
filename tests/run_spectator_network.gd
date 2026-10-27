extends SceneTree

const Transport := preload("res://scripts/network/network_session.gd")
const Runtime := preload("res://scripts/network/network_match.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")

class RecordingTransport extends Transport:
	var packets: Array = []
	func _send(message: Dictionary) -> bool:
		packets.append(message)
		return true

class FixtureSession extends Node:
	signal started
	signal message_received(message: Dictionary)
	signal ended(info: Dictionary)
	signal status_changed(message: String)
	var spectator := true
	var team := -1
	var state := "watching"
	var latest_snapshot: Dictionary
	var last_result := {}
	var sent: Array[String] = []
	func send_ready() -> void: sent.append("ready")
	func send_watch_ready() -> bool:
		sent.append("watch_ready")
		return true
	func send_command(_command: Dictionary) -> bool:
		sent.append("command")
		return true
	func send_snapshot(_snapshot: Dictionary) -> void: sent.append("snapshot")
	func finish_match(_winner: int) -> void: sent.append("finish")
	func leave() -> void: sent.append("leave")

class Bootstrap extends Node:
	var match_state: MatchState
	var map_bounds := Rect2(-60, -60, 120, 120)
	var player_civ: CivDef
	var ai_civ: CivDef

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)

func _run() -> void:
	_test_transport()
	_test_runtime()
	print("SPECTATOR NETWORK: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _test_transport() -> void:
	var transport := RecordingTransport.new()
	root.add_child(transport)
	var listed: Array = []
	var matches: Array = []
	var snapshots: Array = []
	var endings: Array = []
	transport.matches_received.connect(func(value: Array): listed.append(value))
	transport.matched.connect(func(value: Dictionary): matches.append(value))
	transport.message_received.connect(func(value: Dictionary): snapshots.append(value))
	transport.ended.connect(func(value: Dictionary): endings.append(value))
	transport.state = "connecting"
	transport._intent = "browse"
	transport._handle_message({"type": "matches", "matches": [{"match_id": "one"}]})
	check(transport.state == "browsing" and listed.size() == 1, "match listing enters browsing without joining the player queue")
	check(transport.team == -1 and not transport.spectator, "browsing assigns neither a player team nor an active spectator")
	check(not transport.send_watch_ready(), "browsing cannot acknowledge readiness for an unjoined match")
	check(transport.request_matches(transport.server_url) == OK and transport.packets.back().type == "list_matches", "refresh reuses the browser connection")
	check(transport.watch_match(transport.server_url, "one") == OK, "browse can request a specific match")
	check(transport.state == "connecting" and transport.packets.back() == {"type": "watch_match", "match_id": "one"}, "watch request carries only the selected match identity")
	transport._handle_message(JSON.parse_string(JSON.stringify({"type": "spectate_started", "host_team": 0, "match_id": "one", "players": [
		{"team": 0, "name": "Host", "civ": "chinese"}, {"team": 1, "name": "Guest", "civ": "teutons"}]})))
	check(transport.state == "watching" and transport.spectator and transport.team == -1, "spectate acknowledgement grants a read-only role with no team")
	check(matches.size() == 1 and matches[0].role == "spectator", "lobby receives explicit spectator scene-entry information")
	transport.packets.clear()
	check(transport.send_watch_ready(), "spectator can acknowledge a fully loaded observer scene")
	check(transport.send_watch_ready() and transport.packets == [{"type": "watch_ready"}], "watch ready handshake is idempotent")
	var bad_info: Dictionary = matches[0].duplicate(true)
	bad_info.players[0].team = 0.5
	check(not transport._valid_spectator_match(bad_info), "fractional spectator roster teams cannot be truncated into authority")
	bad_info = matches[0].duplicate(true)
	bad_info.players[0].team = false
	check(not transport._valid_spectator_match(bad_info), "boolean spectator roster teams are rejected")
	bad_info = matches[0].duplicate(true)
	bad_info.players[1].team = 0
	check(not transport._valid_spectator_match(bad_info), "spectator rosters require two distinct canonical teams")
	transport._handle_message({"type": "snapshot", "seq": 7, "state": {"marker": "newest"}})
	check(transport.latest_snapshot.seq == 7 and snapshots.size() == 1, "initial snapshot is cached even before the match scene binds")
	transport._handle_message({"type": "snapshot", "seq": 6, "state": {"marker": "old"}})
	check(transport.latest_snapshot.seq == 7 and snapshots.size() == 1, "stale snapshots cannot replace the scene-entry cache")
	transport._handle_message({"type": "command", "seq": 8, "command": {"op": "stop"}})
	check(snapshots.size() == 1, "spectators never receive executable player commands")
	transport.packets.clear()
	transport.send_ready()
	check(not transport.send_command({"op": "stop"}), "spectator command submission is denied")
	transport.send_snapshot({})
	transport.finish_match(0)
	check(transport.packets.is_empty(), "spectators cannot ready, publish snapshots or settle a result")
	transport.team = 0
	transport.state = "playing"
	transport.send_snapshot({})
	transport.finish_match(0)
	check(not transport.send_command({"op": "stop"}) and transport.packets.is_empty(), "changing a spectator's view/team fields cannot grant transport authority")
	check(transport.request_matches(transport.server_url) == ERR_BUSY, "an active session cannot silently switch into browsing")
	transport.state = "watching"
	transport._handle_message({"type": "match_ended", "match_id": "one", "winner": 1, "reason": "completed"})
	var final_result := transport.last_result.duplicate(true)
	var final_status := transport.last_status
	transport._handle_message({"type": "error", "code": "forbidden", "message": "Only spectators may finish loading"})
	check(transport.last_result == final_result and transport.last_status == final_status and endings.size() == 1, "late ready rejection cannot replace an already delivered spectator result")
	transport.leave()
	endings.clear()
	check(not transport.spectator and transport.team == -1 and transport.latest_snapshot.is_empty(), "leave releases the role and cached private match state")
	transport.state = "connecting"
	transport._intent = "watch"
	transport._handle_message({"type": "error", "code": "match_not_found", "message": "Match has ended"})
	check(transport.state == "browsing" and endings.is_empty(), "a vanished match leaves the browser recoverable")
	transport.free()

func _state() -> MatchState:
	var value := MatchState.new()
	value.setup_defaults()
	value.fog = Fog.new()
	value.fog.setup(-60, 60)
	return value

func _test_runtime() -> void:
	var fixture := Node2D.new()
	root.add_child(fixture)
	var host := Runtime.new()
	host.entities = Node2D.new()
	fixture.add_child(host.entities)
	host.match_state = _state()
	host.is_host = true
	host.local_team = 0
	host._playing = true
	fixture.add_child(host)
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = load("res://data/units/villager.tres")
	unit.match_state = host.match_state
	unit.sim_pos = Vector2(1, 2)
	host.entities.add_child(unit)
	var wire_id: int = host.entity_id(unit)
	host.match_state.fog.explored[0][3] = 255
	host.match_state.fog.explored[1][99] = 255
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(packet.has("fog_explored"), "host snapshots include the teams' historical exploration")
	var real_session := root.get_node("NetworkSession")
	root.remove_child(real_session)
	var session := FixtureSession.new()
	session.name = "NetworkSession"
	session.latest_snapshot = {"type": "snapshot", "seq": 5, "state": packet}
	root.add_child(session)
	var world := Node2D.new()
	fixture.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var bootstrap := Bootstrap.new()
	bootstrap.match_state = _state()
	bootstrap.player_civ = load("res://data/civs/chinese.tres")
	bootstrap.ai_civ = load("res://data/civs/teutons.tres")
	world.add_child(bootstrap)
	var observer := Runtime.new()
	world.add_child(observer)
	observer.setup(bootstrap)
	check(observer.spectator and not observer.is_host and observer.local_team == -1, "runtime never gives the observer a player identity")
	check(observer._last_snapshot_sequence == 5 and observer._resolve(wire_id) != null, "runtime applies the cached snapshot immediately after scene load")
	check(session.sent == ["watch_ready"], "cached initial snapshot is applied before acknowledging spectator load, with no player readiness")
	check(observer.match_state.fog.explored[0][3] == 255 and observer.match_state.fog.explored[1][99] == 255, "late join restores each team's separate explored mask")
	var replica := observer._resolve(wire_id) as UnitAgent
	check(replica.has_meta("network_replica") and not replica.is_physics_processing(), "observer entities are passive network replicas")
	check(not observer.submit_command({"op": "stop", "unit_id": wire_id}), "spectator runtime blocks unit orders")
	observer.is_host = true
	check(not observer.execute_team_command({"op": "stop", "unit_id": wire_id}, 0), "role guard remains authoritative even if is_host is modified")
	observer.is_host = false
	var malformed: Dictionary = packet.duplicate(true)
	malformed.fog_explored[0] = Marshalls.raw_to_base64(PackedByteArray([255]))
	check(not observer.apply_snapshot(malformed, 6), "incorrect fog mask dimensions reject the whole snapshot")
	malformed = packet.duplicate(true)
	var invalid_mask: PackedByteArray = Marshalls.base64_to_raw(malformed.fog_explored[0])
	invalid_mask[0] = 1
	malformed.fog_explored[0] = Marshalls.raw_to_base64(invalid_mask)
	check(not observer.apply_snapshot(malformed, 6), "fog masks reject unknown byte values")
	malformed = packet.duplicate(true)
	malformed.fog_explored[0] = "!".repeat(String(malformed.fog_explored[0]).length())
	check(not observer.apply_snapshot(malformed, 6), "noncanonical base64 fog masks cannot enter presentation state")
	check(observer._last_snapshot_sequence == 5 and observer.match_state.fog.explored[0][3] == 255, "invalid fog data does not partially mutate the world")
	var legacy: Dictionary = packet.duplicate(true)
	legacy.erase("fog_explored")
	check(observer.apply_snapshot(legacy, 6), "legacy snapshots without exploration remain compatible")
	session.sent.clear()
	session.latest_snapshot = {}
	var delayed_world := Node2D.new()
	fixture.add_child(delayed_world)
	var delayed_entities := Node2D.new()
	delayed_entities.name = "Entities"
	delayed_world.add_child(delayed_entities)
	var delayed_bootstrap := Bootstrap.new()
	delayed_bootstrap.match_state = _state()
	delayed_bootstrap.player_civ = bootstrap.player_civ
	delayed_bootstrap.ai_civ = bootstrap.ai_civ
	delayed_world.add_child(delayed_bootstrap)
	var delayed_observer := Runtime.new()
	delayed_world.add_child(delayed_observer)
	delayed_observer.setup(delayed_bootstrap)
	check(session.sent.is_empty() and delayed_observer._last_snapshot_sequence == -1, "observer without an initial snapshot must not open continuous fanout")
	delayed_observer._on_message({"type": "snapshot", "seq": 20, "state": packet})
	check(session.sent == ["watch_ready"] and delayed_observer._resolve(wire_id) != null, "delayed first snapshot acknowledges load only after entities are instantiated")
	fixture.free()
	session.free()
	root.add_child(real_session)
