extends SceneTree

const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const MapDataScript := preload("res://scripts/world/map_data.gd")
const MapCatalog := preload("res://scripts/world/map_catalog.gd")
var checks := 0
var failures: Array[String] = []
var world: Node2D
var state: MatchState
var entities: Node2D

## The waiter survives removing the sampled scene. It retains only counters and
## an optional test action; all work and waits remain on the main thread.
class FrameWaiter extends RefCounted:
	var waits := 0
	var cancel_after := -1
	var action := Callable()
	func wait_frame() -> bool:
		waits += 1
		if action.is_valid(): action.call(waits)
		await (Engine.get_main_loop() as SceneTree).process_frame
		return cancel_after < 0 or waits < cancel_after

class CountedBuilding extends BuildingAgent:
	var unlock_queries := 0
	func get_trainable_units() -> Array[UnitDef]:
		unlock_queries += 1
		return super.get_trainable_units()

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture() -> void:
	if is_instance_valid(world): world.free()
	Registry.clear()
	var session := root.get_node("GameSession")
	var map: Dictionary = MapDataScript.create(120, 120, "Budgeted observation")
	for spec in [
		["building", "town_center", Vector2(-18, -18), "player"],
		["building", "town_center", Vector2(24, 24), "ai"],
		["unit", "villager", Vector2(-14, -18), "player"],
		["unit", "scout_cavalry", Vector2(-10, -16), "player"],
		["unit", "militia", Vector2(-10, -10), "ai"],
		["resource", "wood", Vector2(-14, -10), "player"],
	]:
		var record: Dictionary = MapCatalog.make_record(spec[0], spec[1], spec[2], spec[3])
		record.id = "budgeted_%d" % map.entities.size()
		map.entities.append(record)
	session.match_map_data = map
	session.match_ai_mode = "sandbox"
	session.online_active = false
	world = load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	world.process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	await process_frame
	state = world.get_node("Bootstrap").match_state
	entities = world.get_node("Entities")
	state.fog_enabled = true
	state.fog.rebuild(entities.get_children())
	for team in 2:
		state.set_age(team, 1)
		for type in 4: state.resources[team][type] = 10000

func _json(observation: Dictionary) -> String:
	return JSON.stringify(Protocol.json_safe(observation), "", true)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	await _fixture()
	# Default callers must not need await or receive a function-state object.
	var direct: Variant = Observation.build(state, entities, 0, 1, 25.0)
	check(direct is Dictionary and not direct.is_empty(), "default build immediately returns a Dictionary")
	for team in 2:
		for defense_only in [false, true]:
			var synchronous: Dictionary = Observation.build(state, entities, team, 1 - team, 25.0, 20.0, defense_only)
			var waiter := FrameWaiter.new()
			var budgeted: Dictionary = await Observation.build_budgeted(state, entities, team, 1 - team, 25.0, 20.0, defense_only, waiter.wait_frame, 100)
			check(waiter.waits > 0, "team %d defense=%s: bounded build actually yields" % [team, defense_only])
			check(_json(synchronous) == _json(budgeted), "team %d defense=%s: frozen synchronous and budgeted JSON match byte for byte" % [team, defense_only])
	var idle_waiter := FrameWaiter.new()
	var nonbudgeted: Variant = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, idle_waiter.wait_frame, 0)
	check(nonbudgeted is Dictionary and idle_waiter.waits == 0, "zero budget preserves the immediate synchronous path")
	await _test_dynamic_removal()
	await _test_scene_exit(false)
	await _test_scene_exit(true)
	await _test_scene_exit(false, 3)
	await _test_scene_exit(true, 3)
	await _test_fog_holder_removed()
	await _test_cancellation()
	await _test_unlock_changes_between_slices()
	await _fixture()
	var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	var actual_waiter: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, true, client._wait_frame, 100)
	check(not actual_waiter.is_empty(), "existing HTTP client frame waiter can drive the budgeted build")
	client.free()
	if is_instance_valid(world): world.free()
	print("BUDGETED OBSERVATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_dynamic_removal() -> void:
	await _fixture()
	var removed := ResourceNode.new()
	removed.resource_type = Enums.ResourceType.WOOD
	removed.sim_pos = Vector2(-12, -16)
	entities.add_child(removed)
	var removed_id := Registry.id_of(removed)
	var queued := ResourceNode.new()
	queued.resource_type = Enums.ResourceType.GOLD
	queued.sim_pos = Vector2(-10, -16)
	entities.add_child(queued)
	var queued_id := Registry.id_of(queued)
	var removed_ref: WeakRef = weakref(removed)
	var queued_ref: WeakRef = weakref(queued)
	var changed := ResourceNode.new()
	changed.resource_type = Enums.ResourceType.WOOD
	changed.sim_pos = Vector2(-16, -16)
	entities.add_child(changed)
	var changed_id := Registry.id_of(changed)
	var worker: UnitAgent
	for node in entities.get_children():
		if node is UnitAgent and node.team == 0 and node.def.id == &"villager": worker = node
	var waiter := FrameWaiter.new()
	waiter.action = func(count):
		if count != 1: return
		var removed_node: Variant = removed_ref.get_ref()
		var queued_node: Variant = queued_ref.get_ref()
		if is_instance_valid(removed_node): removed_node.free()
		if is_instance_valid(queued_node): queued_node.queue_free()
		changed.resource_type = Enums.ResourceType.GOLD
		changed.amount = 37.0
		worker.team = 1
	var observation: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, waiter.wait_frame, 1)
	check(not observation.is_empty(), "deleting retained scene children during a frame wait completes safely")
	var snapshots: Array = observation.get("entities", [])
	check(not snapshots.any(func(item): return item.id in [removed_id, queued_id]), "freed and queued-for-deletion children are skipped before any typed access")
	var changed_snapshots := snapshots.filter(func(item): return item.id == changed_id)
	check(changed_snapshots.size() == 1 and changed_snapshots[0].resource_type == "GOLD" and changed_snapshots[0].amount == 37.0, "not-yet-sampled resource changes are read after resuming")
	check(snapshots.any(func(item): return item.id == Registry.id_of(worker) and item.team == 1), "a changed unit team is sampled from its resumed live state")

func _test_scene_exit(free_scene: bool, after_wait: int = 1) -> void:
	await _fixture()
	var waiter := FrameWaiter.new()
	waiter.action = func(count):
		if count != after_wait: return
		if free_scene: world.free()
		else: root.remove_child(world)
	var observation: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, waiter.wait_frame, 1)
	check(observation.is_empty(), "freeing the scene cancels without a dangling Node" if free_scene else "detaching the scene cancels without accessing exited entities")
	if is_instance_valid(world): world.free()

func _test_fog_holder_removed() -> void:
	await _fixture()
	var holder_ref: WeakRef = weakref(world.get_meta("fog_holder"))
	var waiter := FrameWaiter.new()
	waiter.action = func(count):
		if count != 1: return
		var holder: Variant = holder_ref.get_ref()
		if is_instance_valid(holder): holder.free()
	var observation: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, waiter.wait_frame, 1)
	check(not observation.is_empty(), "removing the cached fog holder during a wait uses the live fog fallback safely")

func _test_cancellation() -> void:
	await _fixture()
	var waiter := FrameWaiter.new()
	waiter.cancel_after = 1
	var observation: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, waiter.wait_frame, 1)
	check(observation.is_empty() and waiter.waits == 1, "a false frame callback cancels immediately and returns no partial observation")
	await _fixture()
	var later := FrameWaiter.new()
	later.cancel_after = 2
	observation = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, later.wait_frame, 1)
	check(observation.is_empty() and later.waits == 2, "cancellation after a partial entity slice discards the partial result")

func _test_unlock_changes_between_slices() -> void:
	await _fixture()
	state.set_age(0, 0)
	var definition := Catalog.get_building(&"barracks").duplicate() as BuildingDef
	var civ := load("res://data/civs/chinese.tres") as CivDef
	var buildings: Array[CountedBuilding] = []
	for index in 2:
		var building := CountedBuilding.new()
		building.def = definition
		building.civ = civ
		building.team = 0
		building.match_state = state
		building.sim_pos = Vector2(-8 + index * 6, -22)
		entities.add_child(building)
		buildings.append(building)
	for building in buildings: building.unlock_queries = 0
	var waiter := FrameWaiter.new()
	var changed := [false]
	waiter.action = func(_count):
		if changed[0] or buildings[0].unlock_queries == 0: return
		state.set_age(0, 1)
		changed[0] = true
	var observation: Dictionary = await Observation.build_budgeted(state, entities, 0, 1, 25.0, 20.0, false, waiter.wait_frame, 1)
	var first: Array = observation.get("entities", []).filter(func(item): return item.id == Registry.id_of(buildings[0]))
	var second: Array = observation.get("entities", []).filter(func(item): return item.id == Registry.id_of(buildings[1]))
	check(changed[0] and first.size() == 1 and second.size() == 1, "an age change between production snapshots completes safely")
	if first.size() == 1 and second.size() == 1:
		check("spearman" not in first[0].trainable and "spearman" in second[0].trainable, "per-slice unlock cache never carries a stale age across a frame wait")
