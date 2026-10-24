extends SceneTree
## WallSystem.scene_index must tolerate every child of the entity container.
## Fog memory views (FogMemory) are plain Node2D children without sim_pos; they
## appear as soon as the player's scout leaves explored objects behind.
const Walls := preload("res://scripts/systems/wall_system.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	entities = world.get_node("Entities")
	state = world.get_node("Bootstrap").match_state
	for node in entities.get_children(): node.set_physics_process(false)
	var fog_holder: Node = world.get_node("FogOfWar")
	fog_holder.set_physics_process(false)
	fog_holder.rebuild_now()
	check(_memory_views() == 0, "fixture starts without fog memory views")

	var contexts := [_context(Enums.Team.PLAYER, "chinese"), _context(Enums.Team.AI, "teutons")]
	var plans: Array = []
	for ctx: CommandExecutionContext in contexts: plans.append(_perimeter_pieces(ctx))
	var before := _wall_results(contexts, plans)
	var hints_before := _ai_hints()

	# Same exploration the default-map benchmark uses: the player's scout visits
	# forests and returns, leaving memory views of what it saw.
	var scout: Node2D = entities.get_node("PlayerScout")
	var start: Vector2 = scout.sim_pos
	for center in [Vector2(-120, -188), Vector2(-188, -120), Vector2(-52, -40), Vector2(-160, -24)]:
		for side in [-1, 1]:
			scout.sim_pos = center * side
			Iso.sync_node(scout, scout.sim_pos)
			fog_holder.rebuild_now()
	scout.sim_pos = start
	Iso.sync_node(scout, start)
	fog_holder.rebuild_now()
	# Any other decoration without simulation fields is equally possible.
	var bare := Node2D.new()
	bare.name = "BareDecoration"
	entities.add_child(bare)
	var views := _memory_views()
	check(views > 0, "exploration creates fog memory views in the entity container (%d)" % views)

	for ctx: CommandExecutionContext in contexts:
		var index: Variant = Walls.scene_index(ctx)
		check(index is Dictionary and index.has("buckets") and index.has("owned"), "scene_index builds with memory views present (team %d)" % ctx.team)
	var after := _wall_results(contexts, plans)
	check(after == before, "wall validation, cost and existing segments ignore memory views")
	check(_ai_hints() == hints_before, "AI planning hints are unchanged by memory views")
	print("WALL SCENE INDEX: %d checks, %d failures, %d memory views, %d wall pieces" % [checks, failures, views, plans.reduce(func(total, batches): return total + batches.reduce(func(sum, batch): return sum + batch.size(), 0), 0)])
	quit(0 if failures == 0 else 1)

func _context(team: Enums.Team, civ_id: String) -> CommandExecutionContext:
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = team
	ctx.civ = load("res://data/civs/%s.tres" % civ_id)
	return ctx

## Each team's base perimeter, fixed before memory views appear.
func _perimeter_pieces(ctx: CommandExecutionContext) -> Array:
	var tc: Node2D
	for node in entities.get_children():
		if node.get("team") == ctx.team and node.get("def") is BuildingDef and node.get("def").id == &"town_center": tc = node
	var plan := Perimeter.get_plan(state, entities, ctx.team, tc.sim_pos, tc.get_instance_id(), state.map_bounds, "palisade_wall")
	var result: Array = []
	for batch: Dictionary in Perimeter.batches(plan): result.append(batch.pieces)
	return result

func _wall_results(contexts: Array, plans: Array) -> Array:
	var out: Array = []
	for team_index in contexts.size():
		var ctx: CommandExecutionContext = contexts[team_index]
		var index: Variant = Walls.scene_index(ctx)
		var shared: Dictionary = index if index is Dictionary else {}
		for pieces: Array in plans[team_index]:
			# Shared index (AI planner, player preview) and self-built index.
			out.append([Walls.validate_plan(pieces, ctx, false, shared), Walls.validate_plan(pieces, ctx, true), Walls.cost(pieces, ctx)])
			for piece: Dictionary in pieces:
				out.append([Walls.existing_segment(piece, ctx, shared), Walls.existing_segment(piece, ctx)])
	return out

func _ai_hints() -> String:
	var observation := Observation.build(state, entities, Enums.Team.AI, Enums.Team.PLAYER, 60.0)
	return JSON.stringify(Protocol.json_safe(observation.get("decision_context", {})))

func _memory_views() -> int:
	return entities.get_children().filter(func(node): return node.has_meta("fog_memory")).size()
