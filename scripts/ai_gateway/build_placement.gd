class_name AiBuildPlacement
extends RefCounted

const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const BuildSystemScript := preload("res://scripts/systems/build_system.gd")
const AiEntityQueriesScript := preload("res://scripts/systems/ai/ai_entity_queries.gd")


static func place_foundation(
	building_def: BuildingDef,
	pos: Vector2,
	ctx: CommandExecutionContext,
	builder: Node2D = null,
	foundation_name: String = ""
) -> Node2D:
	if building_def == null or ctx == null or ctx.match_state == null or ctx.entities == null:
		return null
	if not can_place_at(building_def, pos, ctx.entities):
		return null
	if not ctx.match_state.spend(
		ctx.team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold,
		building_def.cost_stone,
	):
		return null
	var foundation := BUILDING_VIEW.instantiate() as Node2D
	if building_def.id == &"farm": foundation.set_script(load("res://scripts/entities/farm_agent.gd"))
	if foundation_name.is_empty():
		foundation.name = "Gateway%sFoundation%d" % [
			String(building_def.id).to_pascal_case(),
			ctx.next_build_slot,
		]
	else:
		foundation.name = foundation_name
	foundation.set("team", ctx.team)
	foundation.set("def", building_def)
	if ctx.civ != null:
		foundation.set("civ", ctx.civ)
	foundation.set("match_state", ctx.match_state)
	foundation.set("sim_pos", pos)
	foundation.call("start_construction")
	ctx.entities.add_child(foundation)
	ctx.next_build_slot += 1
	if builder != null and builder.has_method("command_build"):
		builder.call("command_build", foundation)
	return foundation


static func can_place_at(
	building_def: BuildingDef,
	pos: Vector2,
	entities: Node2D
) -> bool:
	if building_def == null or entities == null:
		return false
	var existing := AiEntityQueriesScript.all_buildings(entities)
	for node in entities.get_children():
		if node.is_in_group("terrain_regions"):
			existing.append(node)
	return BuildSystemScript.can_place(building_def.footprint, pos, existing)
