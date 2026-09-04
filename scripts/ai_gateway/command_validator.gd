class_name CommandValidator
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiBuildPlacementScript := preload("res://scripts/ai_gateway/build_placement.gd")


class ValidationResult:
	var ok := false
	var reason := ""


static func validate(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := ValidationResult.new()
	if ctx == null:
		result.reason = "missing_context"
		return result
	var op := AiProtocolScript.op_from_string(String(cmd.get("op", "")))
	if op.is_empty():
		result.reason = "unknown_op"
		return result
	if op == AiProtocolScript.OP_NOOP:
		result.ok = true
		return result
	match op:
		AiProtocolScript.OP_MOVE:
			return _validate_move(cmd, ctx)
		AiProtocolScript.OP_STOP:
			return _validate_unit_command(cmd, ctx, "unit_id")
		AiProtocolScript.OP_GATHER:
			return _validate_gather(cmd, ctx)
		AiProtocolScript.OP_BUILD:
			return _validate_build(cmd, ctx)
		AiProtocolScript.OP_ATTACK:
			return _validate_attack(cmd, ctx)
		AiProtocolScript.OP_PLACE_BUILDING:
			return _validate_place_building(cmd, ctx)
		AiProtocolScript.OP_TRAIN:
			return _validate_train(cmd, ctx)
		_:
			result.reason = "unsupported_op"
			return result


static func _validate_move(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := _validate_unit_command(cmd, ctx, "unit_id")
	if not result.ok:
		return result
	if AiProtocolScript.array_to_vec2(cmd.get("pos")) == null:
		result.ok = false
		result.reason = "invalid_pos"
	return result


static func _validate_gather(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := _validate_unit_command(cmd, ctx, "unit_id")
	if not result.ok:
		return result
	var target := _resolve_entity(int(cmd.get("target_id", -1)))
	if target == null:
		result.ok = false
		result.reason = "missing_target"
		return result
	if not target.has_method("extract"):
		result.ok = false
		result.reason = "target_not_resource"
		return result
	if float(target.get("amount")) <= 0.0:
		result.ok = false
		result.reason = "resource_depleted"
		return result
	result.ok = true
	return result


static func _validate_build(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := _validate_unit_command(cmd, ctx, "unit_id")
	if not result.ok:
		return result
	var building := _resolve_entity(int(cmd.get("building_id", -1)))
	if building == null or building.get("def") is not BuildingDef:
		result.ok = false
		result.reason = "missing_building"
		return result
	if int(building.get("team")) != int(ctx.team):
		result.ok = false
		result.reason = "building_wrong_team"
		return result
	if bool(building.get("is_complete")):
		result.ok = false
		result.reason = "building_complete"
		return result
	result.ok = true
	return result


static func _validate_attack(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := _validate_unit_command(cmd, ctx, "unit_id")
	if not result.ok:
		return result
	var target := _resolve_entity(int(cmd.get("target_id", -1)))
	if target == null:
		result.ok = false
		result.reason = "missing_target"
		return result
	if not target.has_method("take_damage"):
		result.ok = false
		result.reason = "target_not_attackable"
		return result
	if float(target.get("hp")) <= 0.0:
		result.ok = false
		result.reason = "target_dead"
		return result
	if int(target.get("team")) == int(ctx.team):
		result.ok = false
		result.reason = "friendly_target"
		return result
	if target.get("is_placement_ghost") == true:
		result.ok = false
		result.reason = "invalid_target"
		return result
	result.ok = true
	return result


static func _validate_place_building(
	cmd: Dictionary, ctx: CommandExecutionContext
) -> ValidationResult:
	var result := ValidationResult.new()
	if ctx.match_state == null or ctx.entities == null:
		result.reason = "missing_context"
		return result
	var building_def := AiProtocolScript.building_def_for_id(String(cmd.get("building_def_id", "")))
	if building_def == null:
		result.reason = "unknown_building_def"
		return result
	var pos: Variant = AiProtocolScript.array_to_vec2(cmd.get("pos"))
	if pos == null:
		result.reason = "invalid_pos"
		return result
	if not ctx.match_state.can_afford(
		ctx.team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold,
	):
		result.reason = "cannot_afford"
		return result
	if not AiBuildPlacementScript.can_place_at(building_def, pos as Vector2, ctx.entities):
		result.reason = "invalid_placement"
		return result
	if cmd.has("builder_id"):
		var builder_id := int(cmd.get("builder_id", -1))
		if builder_id >= 0:
			var builder_result := _validate_unit_entity(_resolve_entity(builder_id), ctx)
			if not builder_result.ok:
				return builder_result
	result.ok = true
	return result


static func _validate_train(cmd: Dictionary, ctx: CommandExecutionContext) -> ValidationResult:
	var result := ValidationResult.new()
	if ctx.match_state == null:
		result.reason = "missing_context"
		return result
	var building := _resolve_entity(int(cmd.get("building_id", -1)))
	if building == null or building.get("def") is not BuildingDef:
		result.reason = "missing_building"
		return result
	if int(building.get("team")) != int(ctx.team):
		result.reason = "building_wrong_team"
		return result
	if not bool(building.get("is_complete")):
		result.reason = "building_incomplete"
		return result
	var train_queue: Array = building.get("train_queue") as Array
	if not train_queue.is_empty():
		result.reason = "train_queue_busy"
		return result
	var unit_def := AiProtocolScript.unit_def_for_id(String(cmd.get("unit_def_id", "")))
	if unit_def == null:
		result.reason = "unknown_unit_def"
		return result
	if not building.has_method("get_trainable_units"):
		result.reason = "building_cannot_train"
		return result
	var trainable: Array = building.call("get_trainable_units")
	if unit_def not in trainable:
		result.reason = "unit_not_trainable"
		return result
	if not ctx.match_state.can_train(ctx.team, unit_def):
		result.reason = "cannot_train"
		return result
	result.ok = true
	return result


static func _validate_unit_command(
	cmd: Dictionary, ctx: CommandExecutionContext, unit_key: String
) -> ValidationResult:
	return _validate_unit_entity(_resolve_entity(int(cmd.get(unit_key, -1))), ctx)


static func _validate_unit_entity(unit: Node2D, ctx: CommandExecutionContext) -> ValidationResult:
	var result := ValidationResult.new()
	if unit == null or unit.get("def") is not UnitDef:
		result.reason = "missing_unit"
		return result
	if int(unit.get("team")) != int(ctx.team):
		result.reason = "unit_wrong_team"
		return result
	if float(unit.get("hp")) <= 0.0:
		result.reason = "unit_dead"
		return result
	if not unit.has_method("command_move"):
		result.reason = "not_controllable_unit"
		return result
	result.ok = true
	return result


static func _resolve_entity(entity_id: int) -> Node2D:
	if entity_id < 0:
		return null
	return EntityRegistryScript.resolve(entity_id)
