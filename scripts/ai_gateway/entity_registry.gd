class_name EntityRegistry
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")

static var _next_id := 1
static var _id_to_entity: Dictionary = {}
static var _entity_to_id: Dictionary = {}
static var _progress_samples: Dictionary = {}
static var manual_revision := 0


static func register(entity: Node2D) -> int:
	if entity == null or not is_instance_valid(entity):
		return -1
	var instance_id := entity.get_instance_id()
	if _entity_to_id.has(instance_id):
		return int(_entity_to_id[instance_id])
	var entity_id := _next_id
	_next_id += 1
	entity.set_meta(AiProtocolScript.META_ENTITY_ID, entity_id)
	_id_to_entity[entity_id] = entity
	_entity_to_id[instance_id] = entity_id
	AiEventBufferScript.push_for_entity({
		"type": AiProtocolScript.EVENT_ENTITY_SPAWNED,
		"entity": ObservationBuilderScript.serialize_entity(entity, entity_id),
	}, entity)
	return entity_id


static func unregister(entity: Node2D, reason: String = "removed") -> void:
	if entity == null:
		return
	var entity_id := id_of(entity)
	if entity_id < 0:
		return
	_id_to_entity.erase(entity_id)
	_progress_samples.erase(entity_id)
	_entity_to_id.erase(entity.get_instance_id())
	if entity.has_meta(AiProtocolScript.META_ENTITY_ID):
		entity.remove_meta(AiProtocolScript.META_ENTITY_ID)
	AiEventBufferScript.push_for_entity({
		"type": AiProtocolScript.EVENT_ENTITY_DESTROYED,
		"entity_id": entity_id,
		"reason": reason,
	}, entity)


static func resolve(entity_id: int) -> Node2D:
	if entity_id < 0:
		return null
	var entity: Variant = _id_to_entity.get(entity_id)
	if entity == null or not is_instance_valid(entity):
		_id_to_entity.erase(entity_id)
		return null
	return entity as Node2D


static func id_of(entity: Node2D) -> int:
	if entity == null or not is_instance_valid(entity):
		return -1
	if entity.has_meta(AiProtocolScript.META_ENTITY_ID):
		return int(entity.get_meta(AiProtocolScript.META_ENTITY_ID))
	var instance_id := entity.get_instance_id()
	if _entity_to_id.has(instance_id):
		return int(_entity_to_id[instance_id])
	return -1


static func clear() -> void:
	_next_id = 1
	_id_to_entity.clear()
	_entity_to_id.clear()
	_progress_samples.clear()
	manual_revision = 0


## Sample owned execution, not enemy state. The full observation is the source
## of truth; these transitions explain stalled orders and production promptly.
static func sample_owned_state(entities: Node2D, team: int, time_sec: float) -> void:
	if entities == null:
		return
	for child in entities.get_children():
		var entity := child as Node2D
		if entity == null or entity.is_queued_for_deletion() or entity.get("team") != team or entity.get("is_placement_ghost") == true:
			continue
		if not (entity.get("def") is UnitDef or entity.get("def") is BuildingDef):
			continue
		var entity_id := register(entity)
		var previous: Dictionary = _progress_samples.get(entity_id, {})
		var position: Vector2 = entity.get("sim_pos")
		var sample := {"position": position, "hp": float(entity.get("hp")), "time_sec": time_sec, "last_progress_time": time_sec, "last_stall_time": -1000.0}
		if not previous.is_empty():
			sample.last_progress_time = previous.get("last_progress_time", time_sec)
			sample.last_stall_time = previous.get("last_stall_time", -1000.0)
			if sample.hp < float(previous.hp):
				_push_private(entity, team, time_sec, {"type": "own_entity_damaged", "hp": sample.hp, "damage": float(previous.hp) - sample.hp})
		if entity.get("def") is UnitDef:
			var signature := order_signature(entity)
			var order := int(entity.get("order"))
			var progress := _unit_progress(entity, team)
			sample["order_signature"] = signature
			sample["order"] = order
			sample["progress"] = progress
			var lineage: Dictionary = entity.get_meta("ai_command_lineage", {})
			if not lineage.is_empty() and lineage.get("order_signature") != signature:
				entity.remove_meta("ai_command_lineage")
			if not previous.is_empty():
				if signature != previous.get("order_signature", ""):
					sample.last_progress_time = time_sec
					_push_private(entity, team, time_sec, {"type": "unit_order_finished" if order == Enums.OrderType.NONE else "unit_order_changed", "previous_order": AiProtocolScript.order_name(int(previous.get("order", 0))), "order": AiProtocolScript.order_name(order), "previous_lineage": previous.get("lineage", {})})
				elif position.distance_to(previous.position) >= 0.05 or progress != previous.get("progress"):
					sample.last_progress_time = time_sec
				elif order != Enums.OrderType.NONE and time_sec - float(sample.last_progress_time) >= 8.0 and time_sec - float(sample.last_stall_time) >= 8.0:
					sample.last_stall_time = time_sec
					_push_private(entity, team, time_sec, {"type": "unit_stalled", "order": AiProtocolScript.order_name(order), "stalled_for_sec": time_sec - float(sample.last_progress_time), "pos": AiProtocolScript.vec2_to_array(position), "reason": "no_observed_progress"})
			sample["lineage"] = entity.get_meta("ai_command_lineage", {}).duplicate(true)
		elif entity.has_method("production_status"):
			var production: Dictionary = entity.call("production_status")
			sample["production"] = production.duplicate(true)
			var old: Dictionary = previous.get("production", {})
			if not old.is_empty() and (old.get("state") != production.get("state") or old.get("queue_ids") != production.get("queue_ids") or old.get("active_queue_id") != production.get("active_queue_id")):
				var queue_lineage: Dictionary = entity.get_meta("ai_queue_lineage", {})
				_push_private(entity, team, time_sec, {"type": "production_state_changed", "production": production, "previous_state": old.get("state", ""), "queue_lineage": queue_lineage.duplicate(true)})
				# Completed/cancelled queue lineage is delivered in the transition,
				# then removed so a long match never grows this map indefinitely.
				for queue_id in queue_lineage.keys():
					if queue_id not in production.get("queue_ids", []):
						queue_lineage.erase(queue_id)
				entity.set_meta("ai_queue_lineage", queue_lineage)
		_progress_samples[entity_id] = sample


static func order_signature(entity: Node2D) -> String:
	var target: Variant = _order_target(entity)
	var target_id := id_of(target) if is_instance_valid(target) and target is Node2D else -1
	var goal: Variant = entity.get("_requested_move_target") if entity.get("order") == Enums.OrderType.MOVE else null
	return "%s/%s/%s" % [str(entity.get("order")), str(target_id), str(goal)]


static func _order_target(entity: Node2D) -> Variant:
	match entity.get("order"):
		Enums.OrderType.GATHER: return entity.get("_last_resource")
		Enums.OrderType.BUILD: return entity.get("_build_target")
		Enums.OrderType.ATTACK: return entity.get("_attack_target")
	return null


static func _unit_progress(entity: Node2D, team: int) -> String:
	var target: Variant = _order_target(entity)
	var target_progress := ""
	# Even owned attack orders may retain an enemy pointer outside current sight.
	var state: Variant = entity.get("match_state")
	if is_instance_valid(target) and target is Node2D and preload("res://scripts/systems/fog_access.gd").state_can_see(state, team, target):
		target_progress = "%s/%s" % [str(target.get("hp")), str(target.get("build_progress"))]
	return "%s/%s" % [str(entity.get("carry_amount")), target_progress]


static func _push_private(entity: Node2D, team: int, time_sec: float, event: Dictionary) -> void:
	event["entity_id"] = id_of(entity)
	event["team"] = team
	event["time_sec"] = time_sec
	event["_visible_to"] = [team]
	var lineage: Dictionary = entity.get_meta("ai_command_lineage", {})
	for key in ["command_id", "task_id", "session_epoch"]:
		if lineage.has(key):
			event[key] = lineage[key]
	AiEventBufferScript.push(event)


## Called by local UI and the authoritative online command handler only.
## Wire network IDs must already have been translated to registry IDs.
static func report_manual_command(command: Dictionary, team: int, result: Dictionary = {}) -> void:
	var actor_id := int(command.get("unit_id", command.get("builder_id", command.get("building_id", -1))))
	var actor := resolve(actor_id)
	if actor == null or actor.get("team") != team:
		return
	manual_revision += 1
	actor.set_meta("manual_command_revision", manual_revision)
	# Gateway sampling and execution share simulation time. A short local guard
	# bridges receipt delivery; revision comparison also blocks an arbitrarily
	# late response whose observation predates this manual command.
	var sample: Dictionary = _progress_samples.get(actor_id, {})
	if not sample.is_empty():
		actor.set_meta("manual_control_until_sim_time", float(sample.get("time_sec", 0.0)) + 2.0)
	if actor.has_meta("ai_command_lineage"):
		actor.remove_meta("ai_command_lineage")
	var event := {"type": "human_command", "team": team, "entity_id": actor_id, "manual_revision": manual_revision,
		"op": String(command.get("op", "")), "command": command.duplicate(true), "_visible_to": [team]}
	for key in ["unit_id", "builder_id", "building_id", "target_id", "queue_id"]:
		if command.has(key): event[key] = command[key]
	for key in ["queue_id", "created_entity_id", "created_entity_ids"]:
		if result.has(key): event[key] = result[key]
	AiEventBufferScript.push(event)
