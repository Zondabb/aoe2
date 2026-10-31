extends RefCounted
## The only gameplay clock in protocol v3. Rendering and transport are free to
## run at any rate; every participant consumes the same fixed simulation steps.
const State := preload("res://scripts/network/lockstep_state.gd")
const STEP := 1.0 / 30.0
var network: Node
var match_state: MatchState
var entities: Node2D
var root: Node
## Children that entered Entities since the last index pass, in tree order.
## Scanning ~1200 trees and blockers four times per step only to find the few
## new arrows/units cost as much as fog; entering nodes are queued instead.
var _unindexed: Array[Node] = []
var _prune_pending := false
## Units, buildings and projectiles in net_id order. Resources and terrain have
## no per-step logic, so they no longer have to be filtered and sorted each step.
var _order: Array[Node] = []
var _order_dirty := true

func setup(runtime: Node) -> void:
	network = runtime
	match_state = runtime.get("match_state")
	entities = runtime.get("entities")
	root = runtime.get_parent()
	match_state.lockstep_enabled = true
	match_state.lockstep_stepping = false
	var nav := root.get_node_or_null("NavService")
	if nav != null:
		nav.lockstep_enabled = true
		if nav.nav != null: nav.nav.deterministic = true
	for name in ["NavService", "AgeProgression", "TechnologyProgression", "LandSupport", "FogOfWar"]:
		var service := root.get_node_or_null(name)
		if service != null:
			service.set_process(false)
			service.set_physics_process(false)
	var fog := root.get_node_or_null("FogOfWar")
	if fog != null and fog.has_method("set_lockstep_presentation"):
		fog.call("set_lockstep_presentation", true)
	if not entities.child_entered_tree.is_connected(_on_entity_entered):
		entities.child_entered_tree.connect(_on_entity_entered)
		entities.child_exiting_tree.connect(_on_entity_exiting)
	reindex_all()

func _on_entity_entered(node: Node) -> void:
	_unindexed.append(node)

func _on_entity_exiting(node: Node) -> void:
	if node.has_meta("net_id"):
		_order_dirty = true
		_prune_pending = true

## Full pass in child order. Used at setup and after keyframe restoration.
func reindex_all() -> void:
	_unindexed.clear()
	for entity in entities.get_children():
		_index(entity)
	_order_dirty = true

## Assign net_id to entities added since the previous pass. Child order is
## add order, so ids are allocated in exactly the order a full scan would use.
func index_entities() -> void:
	if _prune_pending:
		_prune_pending = false
		var nodes: Dictionary = network.get("_net_entities")
		for id in nodes.keys():
			var node: Variant = nodes[id]
			if not is_instance_valid(node) or node.is_queued_for_deletion(): nodes.erase(id)
	if _unindexed.is_empty(): return
	var pending := _unindexed
	_unindexed = []
	for entity in pending:
		if is_instance_valid(entity) and entity.get_parent() == entities:
			_index(entity)

func _index(entity: Node) -> void:
	if entity.is_queued_for_deletion(): return
	var kind := String(network.call("_entity_kind", entity))
	if kind.is_empty(): return
	network.call("entity_id", entity)
	entity.set_meta("lockstep_entity", true)
	entity.set_physics_process(false)
	if entity is BuildingAgent: entity.set_process(false)
	if kind in ["unit", "building", "projectile"]: _order_dirty = true

func _ordered_entities() -> Array[Node]:
	if not _order_dirty: return _order
	_order_dirty = false
	var nodes: Dictionary = network.get("_net_entities")
	var ids: Array = []
	for id in nodes:
		var node: Variant = nodes[id]
		if is_instance_valid(node) and (node is UnitAgent or node is BuildingAgent or node is ProjectileAgent) and node.get_parent() == entities:
			ids.append(id)
	ids.sort()
	_order.clear()
	for id in ids: _order.append(nodes[id])
	return _order

func step(delta := STEP) -> void:
	if match_state.frozen: return
	index_entities()
	var vision := root.get_node_or_null("VisionService")
	if vision != null: vision.rebuild_from_scene()
	match_state.lockstep_stepping = true
	var nav := root.get_node_or_null("NavService")
	if nav != null: nav.lockstep_step()
	for name in ["AgeProgression", "TechnologyProgression"]:
		var service := root.get_node_or_null(name)
		if service != null: service.call("_process", delta)
	# Entities spawned during this step join the order at the next step, as
	# before: the list is a snapshot taken at the start of the step.
	for entity in _ordered_entities():
		if not is_instance_valid(entity) or entity.is_queued_for_deletion(): continue
		if entity is BuildingAgent: entity.call("_process", delta)
		entity.call("_physics_process", delta)
	var support := root.get_node_or_null("LandSupport")
	if support != null: support.call("_process", delta)
	# queue_free normally waits for a render frame. A frame may contain several
	# simulation steps, so retire dead objects at this shared step boundary.
	var net_entities: Dictionary = network.get("_net_entities")
	for entity in entities.get_children():
		if entity.is_queued_for_deletion() and entity.has_meta("net_id"):
			net_entities.erase(int(entity.get_meta("net_id")))
			entity.free()
	index_entities()
	# Visibility grids are simulation state (gather/attack use them) and stay
	# per step. Fog textures, memories and node visibility are presentation and
	# are refreshed by FogOfWar on render frames instead of three times a frame.
	var fog := root.get_node_or_null("FogOfWar")
	if fog != null:
		if fog.has_method("rebuild_simulation"): fog.call("rebuild_simulation")
		else: fog.rebuild_now()
	match_state.lockstep_stepping = false

## A physics tick without a simulation step must not keep replaying the last
## step's motion in the custom outline-mask interpolation.
## The cached order may still hold units freed since the last step: test
## validity before the type, because 'is' on a freed instance is an error.
func hold_interpolation() -> void:
	for entity: Variant in _order:
		if is_instance_valid(entity) and entity is UnitAgent:
			entity.previous_physics_position = entity.position

func capture() -> Dictionary:
	index_entities()
	return {"world": network.call("capture_snapshot"), "simulation": State.capture(network)}

func restore(payload: Dictionary, sequence := 0) -> bool:
	if payload.get("world") is not Dictionary or not State.validate(payload.get("simulation"), payload.world):
		push_warning("Invalid lockstep simulation keyframe schema")
		return false
	if not network.call("apply_snapshot", payload.world, sequence):
		push_warning("Invalid lockstep world keyframe")
		return false
	if not State.restore(network, payload.simulation):
		push_warning("Failed to restore lockstep simulation state")
		return false
	reindex_all()
	var fog := root.get_node_or_null("FogOfWar")
	if fog != null and fog.has_method("mark_presentation_dirty"): fog.call("mark_presentation_dirty")
	return true

## The digest exchanged with every frame, acknowledgement and keyframe. Frames
## carry the compact digest; frames ending on a whole simulated second (every
## 10th 3-tick frame) carry the exhaustive one, which also covers the hidden
## fields the compact digest leaves out. The kind depends on the tick alone,
## so every peer hashes a given tick the same way.
const FULL_DIGEST_TICKS := 30

func frame_checksum() -> String:
	index_entities()
	var tick: Variant = network.get("tick")
	if tick is int and tick % FULL_DIGEST_TICKS == 0: return State.full_digest(network)
	return State.digest(network)

## Exhaustive hidden-state checksum (keyframe round-trip tests, diagnostics).
func checksum() -> String:
	index_entities()
	return JSON.stringify(State.capture(network), "", true, true).sha256_text()
