extends SceneTree

const Generator := preload("res://scripts/world/default_map_generator.gd")
const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const Navigation := preload("res://scripts/systems/nav_grid_service.gd")
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
	var data := Generator.generate()
	check(Data.validate(data).is_empty(), "generated map passes the same validation as an authored map")
	check(Data.bounds(data).size == Vector2(480, 480), "1v1 map contains 120 original tiles at four simulation units each")
	check(data == Generator.generate(), "same seed reproduces exactly the same preview and match map")
	check(data != Generator.generate(Generator.DEFAULT_SEED + 1), "different seed varies forest edges")
	var changed_civs := Generator.generate(Generator.DEFAULT_SEED, &"teutons", &"chinese")
	check(_unit_count(data, "player", "villager") == 4 and _unit_count(changed_civs, "player", "villager") == 3, "selected civilizations determine starting villagers")
	check(_unit_count(data, "player", "scout_cavalry") == 1 and _unit_count(data, "ai", "scout_cavalry") == 1, "both sides receive a starting scout")
	var groups := {}
	var counts := {"food": 0, "wood": 0, "gold": 0, "stone": 0}
	var resources := {}
	for record in data.entities:
		if record.type != "resource": continue
		counts[record.resource_type] += 1
		groups[record.resource_group] = int(groups.get(record.resource_group, 0)) + 1
		resources[record.id] = record
		check(record.amount == Generator.RESOURCE_AMOUNTS[record.resource_type], "resource quantities are copied from original DAT: " + record.id)
		var point := Data.position_of(record)
		check(point.distance_to(Generator.BASE_POSITION) >= Generator.BASE_CLEAR_RADIUS and point.distance_to(-Generator.BASE_POSITION) >= Generator.BASE_CLEAR_RADIUS, "base construction clearing contains no resource: " + record.id)
	check(counts.wood == 980 and counts.gold == 40 and counts.stone == 26 and counts.food == 24, "map provides fourteen forests plus multiple ore and berry groups")
	check(groups.size() == 32, "distinct resource groups are spread across the map")
	for suffix in ["home_food", "home_gold", "home_stone"]:
		check(groups["Player_" + suffix] == groups["Ai_" + suffix], "both players have equal main resource groups: " + suffix)
	for record in resources.values():
		var opposite: Dictionary = resources.get(String(record.id).replace("Player", "Ai"), {}) if String(record.id).begins_with("Player") else {}
		if opposite.is_empty(): continue
		check(Data.position_of(record) == -Data.position_of(opposite) and record.amount == opposite.amount, "resource placement and quantity are symmetric: " + record.id)
	for seed_value in [0, 1, 7654321]:
		var alternative := Generator.generate(seed_value)
		check(Data.validate(alternative).is_empty() and alternative.entities.size() == data.entities.size(), "alternate seed remains bounded and complete: %d" % seed_value)
	_test_paths(data)
	await _test_menu_preview(data)
	await _test_real_bootstrap(data)
	print("DEFAULT MAP: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _unit_count(data: Dictionary, team: String, unit_id: String) -> int:
	var count := 0
	for record in data.entities:
		if record.type == "unit" and record.team == team and record.unit_id == unit_id: count += 1
	return count

func _test_paths(data: Dictionary) -> void:
	var nav := Navigation.new()
	nav.setup(-240, 240)
	var blockers: Array = []
	var home: Array[ResourceNode] = []
	for record in data.entities:
		if record.type != "resource": continue
		var node := ResourceNode.new()
		node.resource_type = Catalog.RESOURCES[record.resource_type]
		node.sim_pos = Data.position_of(record)
		node.amount = record.amount
		node.set_meta("record_id", record.id)
		node.block_half = ResourceNode.pathfinding_footprint(node.resource_type) * 0.5
		if record.has("block_size"):
			node.set("block_size_override", Vector2(record.block_size[0], record.block_size[1]))
			node.block_half = Vector2(record.block_size[0], record.block_size[1]) * 0.5
		if ResourceNode.resource_blocks_pathfinding(node.resource_type): blockers.append(node)
		if record.resource_group in ["Player_home_food", "Player_home_gold", "Player_home_stone"] or record.id == "PlayerTree": home.append(node)
		elif not ResourceNode.resource_blocks_pathfinding(node.resource_type): node.free()
	nav.rebuild_from_blockers(blockers)
	check(not nav.find_path(Generator.BASE_POSITION, Vector2.ZERO).is_empty(), "starting base has an open route to map center")
	check(not nav.find_path(Generator.BASE_POSITION, -Generator.BASE_POSITION).is_empty(), "forests do not isolate the two bases")
	for node in home:
		var goal := node.approach_point(Generator.BASE_POSITION)
		var route := nav.find_path(Generator.BASE_POSITION, goal)
		# Clearance cells can stop just outside the physical working position;
		# UnitAgent finishes the final short segment with exact box collision.
		check(not route.is_empty() and route[-1].distance_to(goal) < 4.0, "worker route reaches the working band: " + str(node.get_meta("record_id")))
	for node in home:
		if not blockers.has(node): node.free()
	for node in blockers: node.free()

func _test_menu_preview(data: Dictionary) -> void:
	var session := root.get_node("GameSession")
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	session.selected_map_path = ""
	var menu := load("res://scenes/civ_select.tscn").instantiate() as Control
	root.add_child(menu)
	await process_frame
	menu.show_single_player()
	menu._map_choice.select(0)
	menu._map_selected(0)
	check(menu._preview.data == data, "singleplayer preview displays all the same resource groups as the match")
	check("480" in menu._map_info.text and not menu._start.disabled, "singleplayer setup explains the expanded map and permits starting")
	menu._player_choice.select(1)
	menu._update_civ_description()
	check(_unit_count(menu._preview.data, "player", "villager") == 3, "preview updates starting unit count with player civilization")
	menu._enemy_choice.select(0)
	menu._enemy_choice.item_selected.emit(0)
	check(_unit_count(menu._preview.data, "ai", "villager") == 4, "preview updates opponent starting units with civilization")
	if "--render" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/default-map-setup.png")) == OK, "render singleplayer preview with forests")
	menu.free()
	await process_frame

func _test_real_bootstrap(data: Dictionary) -> void:
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	await process_frame
	await process_frame
	var bootstrap: Node = world.get_node("Bootstrap")
	bootstrap.match_state.frozen = true
	check(bootstrap.map_data == data and bootstrap.generated_default_map, "actual match uses the same generated layout as menu preview")
	check(world.get_node("Entities").get_child_count() == data.entities.size(), "actual match spawns every generated object exactly once")
	var network := preload("res://scripts/network/network_match.gd").new()
	network.entities = world.get_node("Entities")
	network.match_state = bootstrap.match_state
	var snapshot_bytes := JSON.stringify(network.capture_snapshot()).to_utf8_buffer().size()
	check(snapshot_bytes + 1024 < preload("res://scripts/network/network_session.gd").MAX_MESSAGE_BYTES, "full generated forest snapshot fits the online transport budget")
	network.free()
	check(bootstrap.match_state.fog.cell_size == 4.0 and bootstrap.match_state.fog.grid_size == Vector2i(120,120), "large map keeps the fog mask at original tile resolution")
	for id in ["PlayerTownCenter", "AiTownCenter", "PlayerVillager1", "AiVillager1", "PlayerFoodBush", "PlayerTree", "PlayerGoldMine", "PlayerStoneMine", "PlayerScout", "AiScout"]:
		check(world.has_node("Entities/" + id), "default map preserves named entity: " + id)
	var town: BuildingAgent = world.get_node("Entities/PlayerTownCenter")
	check(town.sim_pos == Generator.BASE_POSITION, "camera / AI base position is actual generated town center")
	var camera: Camera2D = world.get_node("Camera2D")
	check(camera.map_world_min == Vector2(-240,-240) and camera.map_world_max == Vector2(240,240), "camera bounds follow the expanded map")
	check(bootstrap.match_state.fog.map_origin == Vector2(-240,-240) and bootstrap.match_state.fog.map_end == Vector2(240,240), "fog bounds follow expanded map")
	_test_actual_gathering(world)
	_test_forest_collision(world)
	if "--render" in OS.get_cmdline_user_args():
		bootstrap.match_state.fog_enabled = false
		camera.set_process(false)
		camera.zoom = Vector2.ONE * 0.5
		camera.call("focus_on", Generator.BASE_POSITION + Vector2(4, -4))
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/default-map-base.png")) == OK, "render expanded starting area")
		var fog_holder: Node = world.get_meta("fog_holder")
		fog_holder.set_view(-1)
		camera.zoom = Vector2.ONE * 0.3
		camera.call("focus_on", Generator.BASE_POSITION + Vector2(14, 1))
		await process_frame
		await RenderingServer.frame_post_draw
		check(root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/default-map-resources.png")) == OK, "render overview of home resource groups with fog disabled for inspection")
	world.free()
	await process_frame

func _test_actual_gathering(world: Node2D) -> void:
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.frozen = false
	state.fog_enabled = false
	for entity in world.get_node("Entities").get_children(): entity.set_physics_process(false)
	var worker: UnitAgent = world.get_node("Entities/PlayerVillager1")
	var nav: Node = world.get_node("NavService")
	for id in ["PlayerFoodBush", "PlayerGoldMine", "PlayerStoneMine", "PlayerTree"]:
		worker.command_stop()
		worker.sim_pos = Generator.BASE_POSITION + Vector2(7, 7)
		worker.carry_amount = 0
		worker.carry_type = -1
		var resource: ResourceNode = world.get_node("Entities/" + id)
		var start_amount := resource.amount
		var start_stock: int = state.get_resource(0, resource.resource_type)
		worker.command_gather(resource)
		for tick in 2400:
			nav._process(0.1)
			worker._physics_process(0.1)
			if state.get_resource(0, resource.resource_type) >= start_stock + 40: break
		if state.get_resource(0, resource.resource_type) < start_stock + 40:
			var goal: Vector2 = worker.get("_move_target")
			print("GATHER DEBUG ", id, " radius=", worker.def.resolved_footprint_radius(), " goal=", goal, " path=", worker.get("_path"), " index=", worker.get("_path_index"), " pending=", worker.get("_path_pending"), " debug=", worker.get_move_debug())
			for other in world.get_node("Entities").get_children():
				if other is ResourceNode and other.resource_type != Enums.ResourceType.FOOD and not CollisionResolver.static_step_safe(worker.sim_pos, goal, worker.def.resolved_footprint_radius(), [other]): print("BLOCKS FINAL APPROACH ", other.name, " at=", other.sim_pos, " size=", other.pathfinding_size())
		check(state.get_resource(0, resource.resource_type) >= start_stock + 40, "actual villager reaches, gathers and deposits four complete loads: %s, at %s, state %s, carry %s" % [id, worker.sim_pos, worker.get("_gather_state"), worker.carry_amount])
		check(is_equal_approx(start_amount - resource.amount, state.get_resource(0, resource.resource_type) - start_stock + worker.carry_amount), "cluster resource extraction is conserved: " + id)
	worker.command_stop()
	state.frozen = true

func _test_forest_collision(world: Node2D) -> void:
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.frozen = false
	var worker: UnitAgent = world.get_node("Entities/PlayerVillager1")
	worker.sim_pos = Generator.BASE_POSITION + Vector2(7, 7)
	var nav: Node = world.get_node("NavService")
	var trees: Array[ResourceNode] = []
	for node in world.get_node("Entities").get_children():
		if node is ResourceNode and node.resource_type == Enums.ResourceType.WOOD: trees.append(node)
	var forest_center := Vector2(-120, -188)
	worker.command_move(forest_center)
	check(worker.get("_move_target") != forest_center, "move destination inside a dense forest is clamped to reachable ground")
	var entered_tree := false
	for tick in 900:
		nav._process(0.1)
		worker._physics_process(0.1)
		for tree in trees:
			var half := tree.pathfinding_size() * 0.5 + Vector2.ONE * worker.def.resolved_footprint_radius()
			var offset := (worker.sim_pos - tree.sim_pos).abs()
			if offset.x < half.x - 0.001 and offset.y < half.y - 0.001:
				entered_tree = true
		if worker.order == Enums.OrderType.NONE: break
	check(not entered_tree, "consumed final nav waypoint never permits a worker to walk through forest boxes")
	check(worker.order == Enums.OrderType.NONE, "worker completes a move to the reachable forest edge")
	state.frozen = true
