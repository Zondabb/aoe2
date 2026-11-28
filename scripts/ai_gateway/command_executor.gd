class_name CommandExecutor
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const CommandValidatorScript := preload("res://scripts/ai_gateway/command_validator.gd")
const AiBuildPlacementScript := preload("res://scripts/ai_gateway/build_placement.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const UnitFormationScript := preload("res://scripts/input/unit_formation.gd")


static func execute(cmd: Dictionary, ctx: CommandExecutionContext) -> Dictionary:
	if ctx == null:
		return _result(false, "missing_context")
	ctx.last_execution_details.clear()
	if ctx.require_session_epoch and not cmd.has("session_epoch"):
		return _result(false, "missing_session_epoch")
	if cmd.has("session_epoch") and str(cmd.session_epoch) != ctx.session_epoch:
		return _result(false, "stale_session_epoch")
	if cmd.has("expires_at_sim_time") and (not (cmd.expires_at_sim_time is float or cmd.expires_at_sim_time is int) or not is_finite(float(cmd.expires_at_sim_time)) or ctx.sim_time > float(cmd.expires_at_sim_time)):
		return _result(false, "command_expired")
	var command_id := String(cmd.get("command_id", ""))
	if not command_id.is_empty() and ctx.executed_command_ids.has(command_id):
		return _result(true, "duplicate_skipped")
	var op := AiProtocolScript.op_from_string(String(cmd.get("op", "")))
	var batch_op := CommandValidatorScript.is_batch_op(op)
	var actor_id := int(cmd.get("unit_id", cmd.get("builder_id", cmd.get("building_id", -1))))
	var actor := null if batch_op else EntityRegistryScript.resolve(actor_id)
	# Player commands use the same primitive executor online without AI IDs.
	# An AI response based on a pre-manual snapshot must never overwrite them.
	if actor != null and actor.get("team") == ctx.team and (ctx.require_session_epoch or not command_id.is_empty()):
		if CommandValidatorScript.is_manual_held(actor, ctx):
			return _result(false, "manual_control_hold")

	var validation := CommandValidatorScript.validate(cmd, ctx)
	if not validation.ok:
		push_warning("AI command rejected (%s): %s" % [validation.reason, str(cmd)])
		if ctx.metrics != null:
			ctx.metrics.record_command_reject()
		return _result(false, validation.reason)

	# Online LLM callbacks are asynchronous. Submit their gameplay effects to the player's
	# ordered command frame so the peer and spectators can execute them too.
	if ctx.match_state != null and ctx.match_state.lockstep_enabled and ctx.entities != null:
		var network := ctx.entities.get_parent().get_node_or_null("NetworkMatch")
		if network != null and not bool(network.get("_frame_running")) and not bool(network.get("_replaying")):
			if batch_op:
				return _queue_online_batch(op, cmd, ctx, network)
			return network.call("queue_ai_command", cmd, ctx)

	var executed := false
	match op:
		AiProtocolScript.OP_NOOP:
			executed = true
		AiProtocolScript.OP_MOVE:
			executed = _exec_move(cmd, ctx)
		AiProtocolScript.OP_MOVE_GROUP, AiProtocolScript.OP_MOVE_BOX, AiProtocolScript.OP_MOVE_SAME_TYPE:
			executed = _exec_batch_move(cmd, ctx)
		AiProtocolScript.OP_STOP:
			executed = _exec_stop(cmd, ctx)
		AiProtocolScript.OP_GATHER:
			executed = _exec_gather(cmd, ctx)
		AiProtocolScript.OP_BUILD:
			executed = _exec_build(cmd, ctx)
		AiProtocolScript.OP_ATTACK:
			executed = _exec_attack(cmd, ctx)
		AiProtocolScript.OP_ATTACK_GROUP, AiProtocolScript.OP_ATTACK_BOX, AiProtocolScript.OP_ATTACK_SAME_TYPE:
			executed = _exec_batch_attack(cmd, ctx)
		AiProtocolScript.OP_PLACE_BUILDING:
			executed = _exec_place_building(cmd, ctx)
		AiProtocolScript.OP_PLACE_WALL:
			executed = _exec_place_wall(cmd, ctx)
		AiProtocolScript.OP_SET_GATE_STATE:
			executed = bool(EntityRegistryScript.resolve(int(cmd.building_id)).call("set_gate_state", String(cmd.gate_state)))
		AiProtocolScript.OP_TRAIN:
			executed = _exec_train(cmd, ctx)
		AiProtocolScript.OP_RESEARCH_AGE:
			executed = bool(EntityRegistryScript.resolve(int(cmd.building_id)).call("start_age_upgrade"))
		AiProtocolScript.OP_CANCEL_AGE:
			executed = bool(EntityRegistryScript.resolve(int(cmd.building_id)).call("cancel_age_upgrade"))
		AiProtocolScript.OP_RESEARCH_TECHNOLOGY:
			executed = bool(ctx.match_state.technology_progression.start_research(EntityRegistryScript.resolve(int(cmd.building_id)), String(cmd.technology_id)))
		AiProtocolScript.OP_CANCEL_TECHNOLOGY:
			executed = bool(ctx.match_state.technology_progression.cancel_research(EntityRegistryScript.resolve(int(cmd.building_id))))
		_:
			return _result(false, "unsupported_op")

	if executed and not command_id.is_empty():
		ctx.executed_command_ids[command_id] = true
	if not executed:
		push_warning("AI command failed to execute: %s" % str(cmd))
		return _result(false, "execution_failed")
	if actor != null and not command_id.is_empty():
		var lineage := {"command_id": command_id, "task_id": String(cmd.get("task_id", "")), "session_epoch": ctx.session_epoch, "issued_at_sim_time": ctx.sim_time}
		if actor.get("def") is UnitDef:
			lineage["order_signature"] = EntityRegistryScript.order_signature(actor)
		actor.set_meta("ai_command_lineage", lineage)
	var result := _result(true, "")
	result.merge(ctx.last_execution_details)
	return result


static func _exec_move(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	var pos: Vector2 = AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2
	if unit == null or pos == null:
		return false
	unit.call("command_move", pos)
	var formation_speed := float(cmd.get("formation_speed", 0.0))
	if formation_speed > 0.0 and unit.has_method("set_formation_move_speed"):
		unit.call("set_formation_move_speed", formation_speed)
	return true


static func _formation_speed(units: Array[Node2D]) -> float:
	if units.size() <= 1:
		return 0.0
	var group_speed := INF
	for unit in units:
		var definition := unit.get("def") as UnitDef
		if definition != null:
			group_speed = minf(group_speed, definition.move_speed)
	return group_speed if is_finite(group_speed) else 0.0


static func _stamp_batch_lineage(unit: Node2D, cmd: Dictionary, ctx: CommandExecutionContext) -> void:
	var command_id := String(cmd.get("command_id", ""))
	if command_id.is_empty():
		return
	var lineage := {"command_id": command_id, "task_id": String(cmd.get("task_id", "")), "session_epoch": ctx.session_epoch, "issued_at_sim_time": ctx.sim_time}
	if unit.get("def") is UnitDef:
		lineage["order_signature"] = EntityRegistryScript.order_signature(unit)
	unit.set_meta("ai_command_lineage", lineage)


static func _clamp_to_map_bounds(pos: Vector2, ctx: CommandExecutionContext) -> Vector2:
	if ctx != null and ctx.match_state != null and ctx.match_state.map_bounds.has_area():
		var b := ctx.match_state.map_bounds
		return pos.clamp(b.position + Vector2.ONE * 0.05, b.end - Vector2.ONE * 0.05)
	return pos


static func _exec_batch_move(cmd: Dictionary, ctx: CommandExecutionContext) -> bool:
	var resolved := CommandValidatorScript.resolve_batch_units(cmd, ctx)
	var units: Array[Node2D] = resolved.get("units", [])
	var pos := AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2
	if units.is_empty() or pos == null:
		return false
	var formation := UnitFormationScript.normalize_kind(StringName(String(cmd.get("formation", "line"))))
	var destinations := UnitFormationScript.destinations(units, pos, formation)
	var group_speed := _formation_speed(units)
	var selected_ids: Array = []
	for i in units.size():
		var unit := units[i]
		var target_pos := _clamp_to_map_bounds(destinations[i] if i < destinations.size() else pos, ctx)
		unit.call("command_move", target_pos)
		if group_speed > 0.0 and unit.has_method("set_formation_move_speed"):
			unit.call("set_formation_move_speed", group_speed)
		_stamp_batch_lineage(unit, cmd, ctx)
		selected_ids.append(EntityRegistryScript.id_of(unit))
	ctx.last_execution_details = {"selected_unit_ids": selected_ids, "unit_count": selected_ids.size()}
	return not selected_ids.is_empty()


static func _exec_batch_attack(cmd: Dictionary, ctx: CommandExecutionContext) -> bool:
	var resolved := CommandValidatorScript.resolve_batch_units(cmd, ctx)
	var units: Array[Node2D] = resolved.get("units", [])
	var target := EntityRegistryScript.resolve(int(cmd.get("target_id", -1)))
	if units.is_empty() or target == null:
		return false
	var selected_ids: Array = []
	for unit in units:
		unit.call("command_attack", target)
		_stamp_batch_lineage(unit, cmd, ctx)
		selected_ids.append(EntityRegistryScript.id_of(unit))
	ctx.last_execution_details = {"selected_unit_ids": selected_ids, "unit_count": selected_ids.size()}
	return not selected_ids.is_empty()


static func _queue_online_batch(op: StringName, cmd: Dictionary, ctx: CommandExecutionContext, network: Node) -> Dictionary:
	var resolved := CommandValidatorScript.resolve_batch_units(cmd, ctx)
	var units: Array[Node2D] = resolved.get("units", [])
	if units.is_empty():
		return _result(false, String(resolved.get("reason", "no_matching_units")))
	var is_move := op in [AiProtocolScript.OP_MOVE_GROUP, AiProtocolScript.OP_MOVE_BOX, AiProtocolScript.OP_MOVE_SAME_TYPE]
	var destinations := PackedVector2Array()
	var group_speed := 0.0
	if is_move:
		var pos := AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2
		var formation := UnitFormationScript.normalize_kind(StringName(String(cmd.get("formation", "line"))))
		destinations = UnitFormationScript.destinations(units, pos, formation)
		group_speed = _formation_speed(units)
	var command_id := String(cmd.get("command_id", ""))
	var selected_ids: Array = []
	var last_reason := ""
	network.call("begin_command_batch")
	for i in units.size():
		var unit := units[i]
		var uid := EntityRegistryScript.id_of(unit)
		var sub_cmd := {}
		if is_move:
			var dest := _clamp_to_map_bounds(destinations[i] if i < destinations.size() else (AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2), ctx)
			sub_cmd = {"op": "move", "unit_id": uid, "pos": [dest.x, dest.y]}
			var definition := unit.get("def") as UnitDef
			if group_speed > 0.0 and definition != null and group_speed < definition.move_speed - 0.001:
				sub_cmd["formation_speed"] = group_speed
		else:
			sub_cmd = {"op": "attack", "unit_id": uid, "target_id": int(cmd.get("target_id", -1))}
		if not command_id.is_empty():
			sub_cmd["command_id"] = "%s#%d" % [command_id, i]
		if cmd.has("task_id"):
			sub_cmd["task_id"] = cmd.get("task_id")
		var res: Dictionary = network.call("queue_ai_command", sub_cmd, ctx)
		if bool(res.get("ok")):
			selected_ids.append(uid)
		elif not String(res.get("reason", "")).is_empty():
			last_reason = String(res.get("reason", ""))
	network.call("end_command_batch")
	if selected_ids.is_empty():
		return _result(false, last_reason if not last_reason.is_empty() else "network_not_ready")
	if not command_id.is_empty():
		ctx.executed_command_ids[command_id] = true
	return {"ok": true, "reason": "queued_for_frame", "selected_unit_ids": selected_ids, "unit_count": selected_ids.size()}


static func _exec_stop(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	if unit == null:
		return false
	unit.call("command_stop")
	return true


static func _exec_gather(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	var target := EntityRegistryScript.resolve(int(cmd.get("target_id", -1)))
	if unit == null or target == null:
		return false
	unit.call("command_gather", target)
	return true


static func _exec_build(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	var building := EntityRegistryScript.resolve(int(cmd.get("building_id", -1)))
	if unit == null or building == null:
		return false
	unit.call("command_build", building)
	return true


static func _exec_attack(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	var target := EntityRegistryScript.resolve(int(cmd.get("target_id", -1)))
	if unit == null or target == null:
		return false
	unit.call("command_attack", target)
	return true


static func _exec_place_building(cmd: Dictionary, ctx: CommandExecutionContext) -> bool:
	var building_def := AiProtocolScript.building_def_for_id(
		String(cmd.get("building_def_id", ""))
	)
	var pos: Vector2 = AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2
	if building_def == null or pos == null:
		return false
	var builder: Node2D = null
	if cmd.has("builder_id"):
		builder = EntityRegistryScript.resolve(int(cmd.get("builder_id", -1)))
	var foundation := AiBuildPlacementScript.place_foundation(
		building_def, pos, ctx, builder, "", int(cmd.get("orientation", 0))
	)
	if foundation != null:
		var entity_id := EntityRegistryScript.register(foundation)
		ctx.last_execution_details = {"created_entity_id": entity_id, "building_id": entity_id}
		foundation.set_meta("ai_command_lineage", {"command_id": String(cmd.get("command_id", "")), "task_id": String(cmd.get("task_id", "")), "session_epoch": ctx.session_epoch})
	return foundation != null

static func _exec_place_wall(cmd: Dictionary, ctx: CommandExecutionContext) -> bool:
	var plan_items := Walls.plan(String(cmd.building_def_id), AiProtocolScript.array_to_vec2(cmd.start), AiProtocolScript.array_to_vec2(cmd.end), bool(cmd.get("include_gate", false)))
	var builder := EntityRegistryScript.resolve(int(cmd.builder_id))
	var foundations := Walls.place_plan(plan_items, ctx, builder, bool(cmd.get("append_queue", false)))
	var ids: Array = []
	for foundation in foundations:
		ids.append(EntityRegistryScript.register(foundation))
		foundation.set_meta("ai_command_lineage", {"command_id": String(cmd.get("command_id", "")), "task_id": String(cmd.get("task_id", "")), "session_epoch": ctx.session_epoch})
	ctx.last_execution_details = {"created_entity_ids": ids, "segment_count": ids.size()}
	return not ids.is_empty() or Walls.cost(plan_items, ctx).values().all(func(value): return value == 0)


static func _exec_train(cmd: Dictionary, ctx: CommandExecutionContext) -> bool:
	var building := EntityRegistryScript.resolve(int(cmd.get("building_id", -1)))
	var unit_def := AiProtocolScript.unit_def_for_id(String(cmd.get("unit_def_id", "")))
	if building == null or unit_def == null:
		return false
	var accepted := bool(building.call("enqueue_train", unit_def))
	if accepted:
		var ids: Variant = building.get("train_queue_ids")
		if ids is Array and not ids.is_empty():
			var queue_id := int(ids[-1])
			ctx.last_execution_details = {"queue_id": queue_id, "building_id": int(cmd.building_id)}
			var lineage: Dictionary = building.get_meta("ai_queue_lineage", {})
			lineage[queue_id] = {"command_id": String(cmd.get("command_id", "")), "task_id": String(cmd.get("task_id", "")), "session_epoch": ctx.session_epoch}
			building.set_meta("ai_queue_lineage", lineage)
	return accepted


static func _unit_from_cmd(cmd: Dictionary) -> Node2D:
	return EntityRegistryScript.resolve(int(cmd.get("unit_id", -1)))


static func _result(ok: bool, reason: String) -> Dictionary:
	return {"ok": ok, "reason": reason}
