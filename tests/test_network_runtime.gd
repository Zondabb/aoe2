extends RefCounted

const Runtime := preload("res://scripts/network/network_match.gd")
const Transport := preload("res://scripts/network/network_session.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const VILLAGER := preload("res://data/units/villager.tres")
const HOUSE := preload("res://data/buildings/house.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_snapshot_and_commands(failures)
	_test_production_queue(failures)
	_test_transport_transitions(failures)
	return failures


func _test_snapshot_and_commands(failures: Array[String]) -> void:
	Registry.clear()
	var root := Node2D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	# Deliberately offset process-local IDs: wire IDs must never be passed through.
	var decoy := UNIT.instantiate() as UnitAgent
	decoy.def = VILLAGER
	root.add_child(decoy)
	Registry.register(decoy)
	var host := _runtime(root, true)
	var guest := _runtime(root, false)
	var mine := _unit(host, 0, Vector2(1, 1))
	var theirs := _unit(host, 1, Vector2(5, 5))
	var house := BUILDING.instantiate() as BuildingAgent
	house.def = HOUSE
	house.match_state = host.match_state
	house.sim_pos = Vector2(10, 10)
	host.entities.add_child(house)
	var resource := ResourceNode.new()
	resource.sim_pos = Vector2(12, 10)
	resource.amount = 73.0
	host.entities.add_child(resource)
	var mine_id: int = host.entity_id(mine)
	var theirs_id: int = host.entity_id(theirs)
	if mine_id == Registry.id_of(mine):
		failures.append("network fixture must use distinct registry and wire IDs")
	if not host.execute_team_command({"op": "move", "unit_id": theirs_id, "pos": [8.0, 8.0]}, 1):
		failures.append("guest must be able to command its unit using a wire ID")
	if theirs.order != Enums.OrderType.MOVE or mine.order != Enums.OrderType.NONE:
		failures.append("wire ID translation must command only the intended unit")
	if host.execute_team_command({"op": "stop", "unit_id": mine_id}, 1):
		failures.append("guest must not be able to command host units")
	if host.execute_team_command({"op": "move", "unit_id": theirs_id, "pos": [INF, 0]}, 1):
		failures.append("non-finite command positions must be rejected")
	if host.execute_team_command({"op": "move", "unit_id": theirs_id, "pos": [1000, 0]}, 1):
		failures.append("out-of-bounds command positions must be rejected")
	if host.execute_team_command({"op": "stop", "unit_id": "2"}, 1):
		failures.append("wire IDs with invalid types must be rejected")
	if host.execute_team_command({"op": "place_building", "building_def_id": "house", "pos": [20, 20]}, 1):
		failures.append("building placement must require a real builder")
	host._civs[1] = load("res://data/civs/chinese.tres")
	if host.execute_team_command({"op": "place_building", "builder_id": theirs_id, "building_def_id": "stable", "pos": [20, 20]}, 1):
		failures.append("wire commands must enforce civilization building restrictions")
	if host.execute_team_command({"op": "place_building", "builder_id": theirs_id, "building_def_id": "town_center", "pos": [20, 20]}, 1):
		failures.append("wire commands must not allow free town centers")
	host.match_state.frozen = true
	if host.execute_team_command({"op": "stop", "unit_id": theirs_id}, 1):
		failures.append("frozen games must reject commands")
	host.match_state.frozen = false
	mine.hp = 11.0
	host.match_state.resources[1][0] = 333
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	if not guest.apply_snapshot(packet, 1):
		failures.append("first complete JSON snapshot must apply")
	var copy := guest._resolve(mine_id) as UnitAgent
	if copy == null or copy.hp != 11.0 or copy.sim_pos != mine.sim_pos:
		failures.append("snapshot must spawn entities and restore health and positions")
	if guest.match_state.resources[1][0] != 333:
		failures.append("snapshot must restore the guest economy")
	if copy != null:
		copy.order = Enums.OrderType.MOVE
		copy._move_target = Vector2(30, 30)
		var before := copy.sim_pos
		copy._physics_process(3.0)
		if copy.sim_pos != before:
			failures.append("replicas must not run local unit simulation")
	var before_count: int = guest.entities.get_child_count()
	var invalid: Dictionary = packet.duplicate(true)
	invalid.entities[0].pos = [NAN, 0]
	if guest.apply_snapshot(invalid, 2) or guest.entities.get_child_count() != before_count:
		failures.append("malformed snapshots must be rejected before mutating the world")
	invalid = packet.duplicate(true)
	invalid.entities[0].presentation.frame = []
	if guest.apply_snapshot(invalid, 2):
		failures.append("malformed animation fields must be rejected before rendering")
	invalid = packet.duplicate(true)
	invalid.entities[0].def = "archer"
	if guest.apply_snapshot(invalid, 2):
		failures.append("an existing network ID must not change its unit definition")
	invalid = packet.duplicate(true)
	invalid.entities[0].team = 0.5
	if guest.apply_snapshot(invalid, 2):
		failures.append("fractional JSON enum values must not be silently truncated")
	mine.sim_pos = Vector2(3, 4)
	var second: Dictionary = host.capture_snapshot()
	if not guest.apply_snapshot(second, 2):
		failures.append("a newer snapshot must apply")
	if guest.apply_snapshot(packet, 1) or guest._resolve(mine_id).get("sim_pos") != Vector2(3, 4):
		failures.append("stale snapshots must not roll back state")
	var house_id: int = host.entity_id(house)
	house.free()
	var newborn := _unit(host, 1, Vector2(9, 9))
	var newborn_id: int = host.entity_id(newborn)
	guest.apply_snapshot(host.capture_snapshot(), 3)
	if guest._resolve(house_id) != null or guest._resolve(newborn_id) == null:
		failures.append("snapshot must remove destroyed entities and spawn trained entities")
	var expected_pop: Dictionary = host.match_state.population.duplicate()
	if guest.match_state.population != expected_pop:
		failures.append("replica birth/death must not double-count population")
	root.free()
	Registry.clear()


func _test_production_queue(failures: Array[String]) -> void:
	Registry.clear()
	var root := Node2D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	var host := _runtime(root, true)
	var guest := _runtime(root, false)
	var building := BUILDING.instantiate() as BuildingAgent
	building.team = Enums.Team.AI
	building.def = load("res://data/buildings/town_center.tres")
	building.civ = load("res://data/civs/chinese.tres")
	building.match_state = host.match_state
	host.entities.add_child(building)
	if building.hp <= 0: building._ready()
	host.match_state.resources[1][Enums.ResourceType.FOOD] = 10000
	host.match_state.population_cap[1] = 100
	var id: int = host.entity_id(building)
	for i in 3:
		if not host.execute_team_command({"op":"train", "building_id":id, "unit_def_id":"villager"}, 1):
			failures.append("wire command must append production item %d" % i)
	if building.train_queue_ids.size() != 3:
		failures.append("host must assign each queued unit a stable ID")
		root.free()
		return
	building._physics_process(2.0)
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	if not guest.apply_snapshot(packet, 1):
		failures.append("multi-item production snapshot must survive JSON transport")
	else:
		var replica := guest._resolve(id) as BuildingAgent
		if replica.train_queue.size() != 3 or replica.train_queue_ids != building.train_queue_ids or replica.train_progress != 2.0:
			failures.append("guest must receive full queue identities and active progress")
	var cancel := {"op":"cancel_train", "building_id":id, "queue_id":building.train_queue_ids[1]}
	if host.execute_team_command(cancel, 0):
		failures.append("opponent cannot cancel another player's queue")
	var invalid := cancel.duplicate()
	invalid.queue_id = 1.5
	if host.execute_team_command(invalid, 1):
		failures.append("fractional queue IDs must be rejected")
	var food: int = host.match_state.resources[1][Enums.ResourceType.FOOD]
	if not host.execute_team_command(cancel, 1) or host.execute_team_command(cancel, 1):
		failures.append("network cancellation must succeed exactly once")
	if host.match_state.resources[1][Enums.ResourceType.FOOD] != food + VILLAGER.cost_food or building.train_progress != 2.0:
		failures.append("host cancellation refunds once and preserves head progress")
	var completed_id: int = building.train_queue_ids[0]
	building._physics_process(building._train_time(VILLAGER) - building.train_progress)
	if host.execute_team_command({"op":"cancel_train", "building_id":id, "queue_id":completed_id}, 1) or building.train_queue.size() != 1:
		failures.append("delayed cancellation of completed item cannot remove its successor")
	if not guest.apply_snapshot(host.capture_snapshot(), 2) or guest._resolve(id).train_queue_ids != building.train_queue_ids:
		failures.append("snapshot after completion and cancellation updates the guest queue")
	var bad: Dictionary = packet.duplicate(true)
	bad.entities[0].train_queue_ids[1] = bad.entities[0].train_queue_ids[0]
	if guest.apply_snapshot(bad, 3):
		failures.append("duplicate production IDs must reject a snapshot")
	bad = packet.duplicate(true)
	for i in 16:
		bad.entities[0].train_queue.append("villager")
		bad.entities[0].train_queue_ids.append(i + 100)
	if guest.apply_snapshot(bad, 3):
		failures.append("oversized production queues must reject a snapshot")
	root.free()
	Registry.clear()

func _runtime(root: Node, authority: bool) -> Node:
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	root.add_child(runtime.entities)
	runtime.match_state = MatchState.new()
	runtime.match_state.setup_defaults()
	runtime.is_host = authority
	runtime.local_team = 0 if authority else 1
	runtime._playing = true
	root.add_child(runtime)
	return runtime


func _unit(runtime: Node, side: int, position: Vector2) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.team = side as Enums.Team
	unit.match_state = runtime.match_state
	unit.sim_pos = position
	runtime.entities.add_child(unit)
	if unit.hp <= 0:
		unit.hp = VILLAGER.max_hp
	Registry.register(unit)
	return unit


func _test_transport_transitions(failures: Array[String]) -> void:
	var transport := Transport.new()
	transport.state = "connecting"
	transport.cancel_queue()
	if transport.state != "idle":
		failures.append("cancelling while connecting must return to idle")
	transport.state = "queued"
	transport._handle_message({"type": "match_found", "team": 1, "host_team": 0, "match_id": "test", "players": []})
	if transport.state != "matched" or transport.team != 1:
		failures.append("match_found must assign the canonical guest team")
	transport._handle_message({"type": "start"})
	if transport.state != "playing":
		failures.append("start must transition the session to playing")
	var results: Array = []
	transport.ended.connect(func(info: Dictionary): results.append(info))
	transport._handle_message({"type": "match_ended", "winner": null, "reason": "ready_timeout"})
	if results.size() != 1 or results[0].winner != -1:
		failures.append("unfinished matches must not declare a winner")
	transport.leave()
	if not transport.match_info.is_empty() or transport.team != -1:
		failures.append("leaving must release the previous room and team")
	transport.free()
