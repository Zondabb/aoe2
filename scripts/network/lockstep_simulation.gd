extends RefCounted
## The only gameplay clock in protocol v3. Rendering and transport are free to
## run at any rate; every participant consumes the same fixed simulation steps.
const State := preload("res://scripts/network/lockstep_state.gd")
const STEP := 1.0 / 30.0
var network: Node
var match_state: MatchState
var entities: Node2D
var root: Node

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
	index_entities()

func index_entities() -> void:
	for entity in entities.get_children():
		if entity.is_queued_for_deletion() or String(network.call("_entity_kind", entity)).is_empty(): continue
		network.call("entity_id", entity)
		entity.set_meta("lockstep_entity", true)
		entity.set_physics_process(false)
		if entity is BuildingAgent: entity.set_process(false)

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
	var ordered: Array = entities.get_children().filter(func(node: Node): return node.has_meta("net_id") and not node.is_queued_for_deletion())
	ordered.sort_custom(func(a: Node, b: Node): return int(a.get_meta("net_id")) < int(b.get_meta("net_id")))
	for entity in ordered:
		if not is_instance_valid(entity) or entity.is_queued_for_deletion(): continue
		if entity is BuildingAgent: entity.call("_process", delta)
		if entity is UnitAgent or entity is BuildingAgent or entity is ProjectileAgent:
			entity.call("_physics_process", delta)
	var support := root.get_node_or_null("LandSupport")
	if support != null: support.call("_process", delta)
	# queue_free normally waits for a render frame. A frame may contain several
	# simulation steps, so retire dead objects at this shared step boundary.
	for entity in entities.get_children():
		if entity.is_queued_for_deletion() and entity.has_meta("net_id"):
			network.get("_net_entities").erase(int(entity.get_meta("net_id")))
			entity.free()
	index_entities()
	var fog := root.get_node_or_null("FogOfWar")
	if fog != null: fog.rebuild_now()
	match_state.lockstep_stepping = false

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
	index_entities()
	return true

func checksum() -> String:
	index_entities()
	return JSON.stringify(State.capture(network), "", true, true).sha256_text()
