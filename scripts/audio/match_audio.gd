extends Node
## Local presentation observer. Authoritative hooks cover short-lived events;
## replicas use animation/health differences without changing network state.

const SAMPLE_MSEC := 100
const WORK_INTERVAL_MSEC := 900
const EVENT_INTERVALS := {&"melee": 65, &"arrow": 80, &"death": 100, &"building_destroyed": 150,
	&"siege_fire_stone": 150, &"siege_fire_cannon": 150, &"siege_fire_trebuchet": 150,
	&"siege_fire_onager": 150, &"siege_fire_bolt": 150,
	&"chop": 130, &"mine": 130, &"farm": 180, &"hammer": 130,
	&"attack_warning": 8000, &"unit_ready": 300, &"construction_complete": 400}

## May be supplied by a fixture; otherwise uses the local GameAudio autoload.
var audio_service: Node
var _root: Node
var _state: MatchState
var _network: Node
var _tracked: Dictionary = {}
var _last_events: Dictionary = {}
var _last_sample := 0
var _active := false


func setup(match_root: Node, match_state: MatchState) -> void:
	_disconnect()
	_root = match_root
	_state = match_state
	if not is_inside_tree() or not is_instance_valid(_root) or _state == null:
		return
	if audio_service == null:
		audio_service = get_node_or_null("/root/GameAudio")
	for candidate in get_tree().get_nodes_in_group("network_match"):
		if _root.is_ancestor_of(candidate):
			_network = candidate
			break
	# Existing map entities and restored saves establish a silent baseline.
	_collect(_root)
	_state.age_changed.connect(_on_age_changed)
	_state.winner_decided.connect(_on_winner)
	get_tree().node_added.connect(_on_node_added)
	_root.tree_exiting.connect(_stop)
	_last_sample = Time.get_ticks_msec()
	_active = true


func _collect(node: Node) -> void:
	if node is UnitAgent or node is BuildingAgent:
		_track(weakref(node))
		return
	for child in node.get_children():
		_collect(child)


func _on_node_added(node: Node) -> void:
	if not _active or not is_instance_valid(_root) or not _root.is_ancestor_of(node):
		return
	if node is UnitAgent or node is BuildingAgent:
		# Capture this before deferring: the first snapshot sets its sequence only
		# after spawning all entities, so its initial army must remain silent.
		var produced_replica := node is UnitAgent and node.has_meta("network_replica") and not _network_initializing()
		call_deferred("_track", weakref(node), produced_replica)


func _track(reference: WeakRef, produced_replica := false) -> void:
	var node := reference.get_ref() as Node
	if not is_instance_valid(node) or not is_instance_valid(_root) or not _root.is_ancestor_of(node):
		return
	if node.is_queued_for_deletion() or node.get("is_placement_ghost") == true or node.has_meta("fog_memory"):
		return
	var id := node.get_instance_id()
	if _tracked.has(id): return
	var connections: Array = []
	if node is UnitAgent:
		_connect_entity(node, &"audio_cue", _on_unit_audio.bind(node), connections)
		_connect_entity(node, &"damaged", _on_damaged, connections)
	else:
		_connect_entity(node, &"damaged", _on_damaged, connections)
		_connect_entity(node, &"construction_completed", _on_construction_completed, connections)
		_connect_entity(node, &"destroyed", _on_building_destroyed, connections)
		_connect_entity(node, &"unit_trained", _on_unit_trained, connections)
	var exit_callback := _untrack.bind(id)
	node.tree_exiting.connect(exit_callback)
	connections.append([&"tree_exiting", exit_callback])
	_tracked[id] = {"ref": reference, "sample": _snapshot(node), "work_at": -1000,
		"death_reported": float(node.get("hp")) <= 0.0, "connections": connections}
	if produced_replica and _can_play() and int(node.get("team")) == _local_team() and float(node.get("hp")) > 0.0:
		_notify(_ready_event(node))


func _connect_entity(node: Node, signal_name: StringName, callback: Callable, connections: Array) -> void:
	if node.has_signal(signal_name):
		node.connect(signal_name, callback)
		connections.append([signal_name, callback])


func _untrack(id: int) -> void:
	var entry: Dictionary = _tracked.get(id, {})
	if not entry.is_empty():
		var node := entry.ref.get_ref() as Node
		if _can_play() and node is BuildingAgent and node.has_meta("network_replica") and not bool(entry.death_reported) and float(node.hp) <= 0.0 and bool(entry.sample.replica_ready):
			# A snapshot may delete a confirmed dead building before the next scan.
			# Capture visibility while it exists, then wait until scene teardown has
			# finished. A direct scene free also exits its children before the root.
			if is_instance_valid(audio_service) and audio_service.has_method("source_audible") and audio_service.call("source_audible", node):
				call_deferred("_removed_building_audio", weakref(_root))
	_tracked.erase(id)


func _removed_building_audio(match_reference: WeakRef) -> void:
	if _can_play() and match_reference.get_ref() == _root:
		_play(&"building_destroyed", &"world")


func _process(_delta: float) -> void:
	# Use wall time: 20x simulation speed must not produce 200 audio scans/s.
	var now := Time.get_ticks_msec()
	if not _active or now - _last_sample < SAMPLE_MSEC: return
	_last_sample = now
	_sample(now)


func _sample(now: int) -> void:
	for id in _tracked.keys():
		var entry: Dictionary = _tracked[id]
		var node := entry.ref.get_ref() as Node
		if not is_instance_valid(node):
			_tracked.erase(id)
			continue
		var current := _snapshot(node)
		var previous: Dictionary = entry.sample
		entry.sample = current
		if not _can_play() or node.is_queued_for_deletion(): continue
		if bool(current.replica) and not bool(previous.replica_ready): continue
		if bool(current.replica):
			if float(current.hp) < float(previous.hp): _on_damaged(node)
			if float(previous.hp) > 0.0 and float(current.hp) <= 0.0:
				entry.death_reported = true
				_world(&"building_destroyed" if node is BuildingAgent else &"death", node)
			if node is BuildingAgent and not bool(previous.complete) and bool(current.complete):
				if int(node.get("team")) == _local_team(): _notify(&"construction_complete", node)
			if node is UnitAgent and current.action == &"attack" and (previous.action != &"attack" or int(current.frame) < int(previous.frame)):
				_world(_projectile_event(node) if node.def != null and node.def.is_ranged else &"melee", node)
		if float(current.hp) <= 0.0 or now < int(entry.work_at): continue
		var work := _work_event(node, current)
		if work != &"":
			entry.work_at = now + WORK_INTERVAL_MSEC
			_world(work, node)


func _snapshot(node: Node) -> Dictionary:
	var replica := node.has_meta("network_replica")
	var sample := {"hp": float(node.get("hp")), "replica": replica,
		"replica_ready": replica and not _network_initializing(), "complete": true,
		"action": &"", "frame": 0, "animation": &""}
	if node is BuildingAgent:
		sample.complete = node.is_complete
	elif node is UnitAgent:
		sample.action = node._combat_action
		var sprite := node.get_node_or_null("Billboard") as AnimatedSprite2D
		if sprite != null:
			sample.frame = sprite.frame
			sample.animation = sprite.animation
	return sample


func _work_event(node: Node, sample: Dictionary) -> StringName:
	if not node is UnitAgent or node.def == null or node.def.id != &"villager": return &""
	if bool(sample.replica):
		var animation := String(sample.animation)
		if animation.begins_with("build_"): return &"hammer"
		if node._gather_state != "gathering": return &""
	else:
		if node.order == Enums.OrderType.BUILD and node._is_in_build_range(): return &"hammer"
		if node.order != Enums.OrderType.GATHER or node._gather_state != "gathering": return &""
	var resource: int = node.carry_type
	if resource < 0:
		resource = node._gather_resource_type
	if resource < 0 and is_instance_valid(node._gather_target):
		resource = int(node._gather_target.get("resource_type"))
	match resource:
		Enums.ResourceType.WOOD: return &"chop"
		Enums.ResourceType.GOLD, Enums.ResourceType.STONE: return &"mine"
		Enums.ResourceType.FOOD: return &"farm"
	return &""


func _on_unit_audio(event: StringName, source: Node) -> void:
	if _can_play(): _world(_projectile_event(source) if event == &"arrow" else event, source)


func _projectile_event(source: Node) -> StringName:
	var definition := source.get("def") as UnitDef
	if definition == null: return &"arrow"
	match definition.id:
		&"trebuchet": return &"siege_fire_trebuchet"
		&"onager", &"siege_onager": return &"siege_fire_onager"
		&"scorpion", &"heavy_scorpion": return &"siege_fire_bolt"
		&"bombard_cannon": return &"siege_fire_cannon"
	match definition.projectile_kind:
		&"stone": return &"siege_fire_stone"
		&"cannon": return &"siege_fire_cannon"
		&"bolt": return &"siege_fire_bolt"
	return &"arrow"


func _on_damaged(entity: Node) -> void:
	if _can_play() and int(entity.get("team")) == _local_team():
		# An owned entity under attack is actionable even outside the camera.
		_notify(&"attack_warning")


func _on_construction_completed(building: Node) -> void:
	if not _can_play() or not is_instance_valid(building): return
	var id := building.get_instance_id()
	if _tracked.has(id):
		var entry: Dictionary = _tracked[id]
		# _ready emits this too for existing completed buildings.
		if bool(entry.sample.complete): return
		entry.sample.complete = true
	if int(building.get("team")) == _local_team(): _notify(&"construction_complete", building)


func _on_building_destroyed(building: Node) -> void:
	if _can_play():
		if _tracked.has(building.get_instance_id()): _tracked[building.get_instance_id()].death_reported = true
		_world(&"building_destroyed", building)


func _on_unit_trained(unit: Node) -> void:
	if _can_play() and is_instance_valid(unit) and int(unit.get("team")) == _local_team():
		_notify(_ready_event(unit))


func _ready_event(unit: Node) -> StringName:
	var definition := unit.get("def") as UnitDef
	return &"villager_ready" if definition != null and definition.id == &"villager" else &"unit_ready"


func _on_age_changed(team: int, _age: int) -> void:
	if _can_play() and not _network_initializing() and team == _local_team():
		_notify(&"age_up")


func _on_winner(team: int) -> void:
	if _active and is_instance_valid(_root) and _root.is_inside_tree() and not _root.is_queued_for_deletion():
		_notify(&"victory" if team == _local_team() else &"defeat")


func _world(event: StringName, source: Node) -> void:
	if is_instance_valid(source) and source.is_inside_tree(): _play(event, &"world", source)


func _notify(event: StringName, source: Node = null) -> void:
	_play(event, &"alert", source)


func _play(event: StringName, category: StringName, source: Node = null) -> void:
	if not is_instance_valid(audio_service): return
	var now := Time.get_ticks_msec()
	if now - int(_last_events.get(event, -100000)) < int(EVENT_INTERVALS.get(event, 0)): return
	if audio_service.call("play_event", event, category, source, "match:" + String(event)):
		_last_events[event] = now


func _local_team() -> int:
	var session := get_node_or_null("/root/GameSession")
	return int(session.call("local_team")) if session != null else Enums.Team.PLAYER


func _network_initializing() -> bool:
	return is_instance_valid(_network) and not bool(_network.get("is_host")) and int(_network.get("_last_snapshot_sequence")) < 0


func _can_play() -> bool:
	return _active and is_instance_valid(_root) and _root.is_inside_tree() and not _root.is_queued_for_deletion() and _state != null and not _state.frozen


func _stop() -> void:
	_active = false


func _disconnect() -> void:
	_active = false
	if is_inside_tree() and get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)
	if is_instance_valid(_root) and _root.tree_exiting.is_connected(_stop): _root.tree_exiting.disconnect(_stop)
	if _state != null:
		if _state.age_changed.is_connected(_on_age_changed): _state.age_changed.disconnect(_on_age_changed)
		if _state.winner_decided.is_connected(_on_winner): _state.winner_decided.disconnect(_on_winner)
	for entry in _tracked.values():
		var node := entry.ref.get_ref() as Node
		if not is_instance_valid(node): continue
		for connection in entry.connections:
			if node.is_connected(connection[0], connection[1]): node.disconnect(connection[0], connection[1])
	_tracked.clear()
	_last_events.clear()
	_network = null


func _exit_tree() -> void:
	_disconnect()
