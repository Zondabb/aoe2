extends SceneTree
## Regression for simulation-speed traffic amplification and fog cache churn.

const Runtime := preload("res://scripts/network/network_match.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")

class Session extends Node:
	var snapshots: Array = []
	var leaves := 0
	func send_snapshot(value: Dictionary) -> void: snapshots.append(value)
	func leave() -> void: leaves += 1

class CountingGate extends BuildingAgent:
	var visual_refreshes := 0
	func _configure_visuals() -> void: visual_refreshes += 1

var checks := 0
var failures := 0
var fixture: Node2D

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func runtime(host: bool) -> Node:
	var node := Runtime.new()
	node.entities = Node2D.new()
	fixture.add_child(node.entities)
	node.match_state = MatchState.new()
	node.match_state.setup_defaults()
	node.map_bounds = Rect2(-60, -60, 120, 120)
	node.is_host = host
	node.local_team = 0 if host else 1
	fixture.add_child(node)
	node.set_process(false)
	return node

func _run() -> void:
	await process_frame
	fixture = Node2D.new()
	root.add_child(fixture)
	var session := Session.new()
	fixture.add_child(session)
	var host := runtime(true)
	host.session = session
	host._on_started()
	check(session.snapshots.size() == 1, "start publishes an immediate complete snapshot")
	host._process(1000.0)
	check(session.snapshots.size() == 1, "large simulated delta cannot emit an early network frame")
	var old_speed := Engine.time_scale
	Engine.time_scale = 8.0
	OS.delay_msec(120)
	host._process(0.0)
	check(session.snapshots.size() == 2, "wall-clock deadline publishes even with zero simulation delta")
	host._process(1000.0)
	check(session.snapshots.size() == 2, "accelerated simulation cannot flood catch-up snapshots")
	Engine.time_scale = old_speed
	var guest := runtime(false)
	guest.session = session
	guest._on_started()
	guest._process(1000.0)
	check(not guest._terminal and session.leaves == 0, "simulation acceleration cannot expire the receive deadline")
	guest.match_state.fog = Fog.new()
	guest.match_state.fog.setup(-60, 60)
	guest.match_state.fog_enabled = true
	var source := ResourceNode.new()
	source.amount = 90.0
	source.sim_pos = Vector2(5, 5)
	host.entities.add_child(source)
	var source_id: int = host.entity_id(source)
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(guest.apply_snapshot(packet, 1), "initial authoritative resource is replicated")
	var replica := guest._resolve(source_id) as ResourceNode
	replica.hide()
	var changed := {"count": 0}
	replica.visibility_changed.connect(func(): changed.count += 1)
	check(guest.apply_snapshot(packet, 2), "unchanged full snapshots remain valid")
	check(not replica.visible and changed.count == 0, "unchanged snapshots never re-show fog-hidden resources")
	source.amount = 73.0
	packet = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(guest.apply_snapshot(packet, 3) and replica.amount == 73.0, "changed resource quantities still update authoritatively")
	check(not replica.visible and changed.count == 0, "quantity changes do not invalidate hidden resource visuals")
	source.amount = 0.0
	packet = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(guest.apply_snapshot(packet, 4) and replica.amount == 0.0 and not replica.visible, "resource depletion remains hidden and synchronized")
	replica.free()
	check(guest.apply_snapshot(packet, 5) and guest._resolve(source_id).amount == 0.0, "static cache cannot skip initialization of a replacement entity")
	var bad := packet.duplicate(true)
	bad.entities[0].gather_rate = "invalid"
	check(not guest.apply_snapshot(bad, 6), "static cache never bypasses incoming record validation")
	var gate := CountingGate.new()
	gate.def = Catalog.get_building(&"gate")
	gate.match_state = host.match_state
	gate.civ = load("res://data/civs/chinese.tres")
	gate.is_complete = true
	gate.sim_pos = Vector2(20, 20)
	host.entities.add_child(gate)
	var gate_record: Dictionary
	for record in host.capture_snapshot().entities:
		if record.get("kind") == "building": gate_record = record
	var before: int = gate.visual_refreshes
	guest._apply_record(gate, gate_record)
	check(gate.visual_refreshes == before, "unchanged fortifications do not rebuild visual children")
	gate_record.gate_open = true
	guest._apply_record(gate, gate_record)
	check(gate.visual_refreshes == before + 1, "gate state changes still refresh their visual")
	fixture.free()
	await process_frame
	print("NETWORK SNAPSHOT BUDGET: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
