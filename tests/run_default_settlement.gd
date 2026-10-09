extends SceneTree
## Actual default map + AI foundations; -- --render saves the built settlement.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Queries := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const Manager := preload("res://scripts/systems/ai/ai_build_manager.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	preload("res://scripts/debug/unit_debug_focus.gd").set_spectator_mode(true)
	state.fog_enabled = false
	state.set_age(Enums.Team.AI, 3)
	world.get_node("LandSupport").set_process(false)
	world.get_node("Camera2D").set_process(false)
	for resource in Enums.ResourceType.values():
		state.resources[Enums.Team.AI][resource] = 100000
	for entity in entities.get_children():
		entity.set_physics_process(false)
	var ctx := AiRunContext.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.civ = load("res://data/civs/teutons.tres")
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.blackboard = AiBlackboard.new()
	var manager := Manager.new()
	var created: Array[BuildingAgent] = []
	for id in ["house", "mill", "lumber_camp", "barracks", "blacksmith", "market", "archery_range", "stable", "monastery", "university", "castle", "siege_workshop", "house", "mining_camp"]:
		ctx.blackboard.refresh(state, entities, ctx.team, ctx.enemy_team, 0, 20)
		check(manager.ensure_building(ctx, Catalog.get_building(id)), "actual default map can plan %s" % id)
		for entity in entities.get_children():
			entity.set_physics_process(false)
			if entity is BuildingAgent and not entity.is_complete:
				entity.add_build_progress(entity.def.build_time)
				created.append(entity)
		for villager in ctx.blackboard.team_villagers:
			villager.command_stop()
	var buildings := Queries.all_buildings(entities)
	var resources: Array = []
	for entity in entities.get_children():
		if entity.has_method("extract") and not entity.get("def") is BuildingDef:
			resources.append(entity)
	var bounds: Rect2 = world.get_node("Bootstrap").map_bounds
	for building in created:
		var other_buildings := buildings.duplicate()
		other_buildings.erase(building)
		check(Queries.can_plan_settlement(building.def.footprint, building.sim_pos, other_buildings, resources, bounds), "%s leaves visual ground, road, resource and border clearance" % building.def.id)
		check(building.is_complete and building.hp > 0, "%s foundation completes normally" % building.def.id)
	check(created.size() == 14, "the full planned settlement has fourteen completed buildings")
	state.frozen = true
	if "--render" in OS.get_cmdline_user_args():
		world.get_node("UILayer").hide()
		world.get_meta("fog_holder").set_view(-1)
		var visual_bounds := Rect2()
		var have_bounds := false
		for building in buildings:
			if building.team != Enums.Team.AI: continue
			var sprite := building.get_node("Billboard") as Sprite2D
			var local := sprite.get_rect()
			var rect := Rect2(sprite.global_transform * local.position, local.size * sprite.global_scale)
			visual_bounds = visual_bounds.merge(rect) if have_bounds else rect
			have_bounds = true
		var camera := world.get_node("Camera2D") as Camera2D
		camera.limit_to_map_bounds = false
		camera.position = visual_bounds.get_center()
		var view_size := root.get_visible_rect().size
		var zoom := minf((view_size.x - 80) / visual_bounds.size.x, (view_size.y - 80) / visual_bounds.size.y)
		camera.zoom = Vector2.ONE * minf(zoom, 1.0)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png("res://.godot/default-ai-settlement.png") == OK, "actual settlement preview saved")
	print("DEFAULT SETTLEMENT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
