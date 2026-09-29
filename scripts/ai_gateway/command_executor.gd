class_name CommandExecutor
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const CommandValidatorScript := preload("res://scripts/ai_gateway/command_validator.gd")
const AiBuildPlacementScript := preload("res://scripts/ai_gateway/build_placement.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")


static func execute(cmd: Dictionary, ctx: CommandExecutionContext) -> Dictionary:
	if ctx == null:
		return _result(false, "missing_context")
	var command_id := String(cmd.get("command_id", ""))
	if not command_id.is_empty() and ctx.executed_command_ids.has(command_id):
		return _result(true, "duplicate_skipped")

	var validation := CommandValidatorScript.validate(cmd, ctx)
	if not validation.ok:
		push_warning("AI command rejected (%s): %s" % [validation.reason, str(cmd)])
		if ctx.metrics != null:
			ctx.metrics.record_command_reject()
		return _result(false, validation.reason)

	var op := AiProtocolScript.op_from_string(String(cmd.get("op", "")))
	var executed := false
	match op:
		AiProtocolScript.OP_NOOP:
			executed = true
		AiProtocolScript.OP_MOVE:
			executed = _exec_move(cmd, ctx)
		AiProtocolScript.OP_STOP:
			executed = _exec_stop(cmd, ctx)
		AiProtocolScript.OP_GATHER:
			executed = _exec_gather(cmd, ctx)
		AiProtocolScript.OP_BUILD:
			executed = _exec_build(cmd, ctx)
		AiProtocolScript.OP_ATTACK:
			executed = _exec_attack(cmd, ctx)
		AiProtocolScript.OP_PLACE_BUILDING:
			executed = _exec_place_building(cmd, ctx)
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
	return _result(true, "")


static func _exec_move(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var unit := _unit_from_cmd(cmd)
	var pos: Vector2 = AiProtocolScript.array_to_vec2(cmd.get("pos")) as Vector2
	if unit == null or pos == null:
		return false
	unit.call("command_move", pos)
	return true


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
		building_def, pos, ctx, builder
	)
	return foundation != null


static func _exec_train(cmd: Dictionary, _ctx: CommandExecutionContext) -> bool:
	var building := EntityRegistryScript.resolve(int(cmd.get("building_id", -1)))
	var unit_def := AiProtocolScript.unit_def_for_id(String(cmd.get("unit_def_id", "")))
	if building == null or unit_def == null:
		return false
	return bool(building.call("enqueue_train", unit_def))


static func _unit_from_cmd(cmd: Dictionary) -> Node2D:
	return EntityRegistryScript.resolve(int(cmd.get("unit_id", -1)))


static func _result(ok: bool, reason: String) -> Dictionary:
	return {"ok": ok, "reason": reason}
