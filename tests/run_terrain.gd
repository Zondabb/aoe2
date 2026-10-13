extends SceneTree

## Authored terrain, real navigation / construction, and generated-map regression.
const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
const Generator := preload("res://scripts/world/default_map_generator.gd")
const Navigation := preload("res://scripts/systems/nav_grid_service.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Shore := preload("res://scripts/world/shore_geometry.gd")
const Construction := preload("res://scripts/systems/build_system.gd")
const Queries := preload("res://scripts/systems/ai/ai_entity_queries.gd")
const Manager := preload("res://scripts/systems/ai/ai_build_manager.gd")
const GameCatalog := preload("res://scripts/data/game_catalog.gd")
const CHINESE := preload("res://data/civs/chinese.tres")
const TEUTONS := preload("res://data/civs/teutons.tres")

class SelectedBuilders extends Control:
	var units: Array[Node2D] = []
	func get_selected_units() -> Array[Node2D]:
		return units

class BoundsCarrier extends Node:
	var map_bounds := Rect2(-160, -160, 320, 320)

var checks := 0
var failures: Array[String] = []
var fixture: Node2D
var entities: Node2D

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	_test_schema_and_overlap()
	_test_files()
	_test_loader_navigation()
	_test_island()
	await _test_player_building()
	_test_ai_building()
	_test_default_map()
	if is_instance_valid(fixture):
		fixture.free()
	Collision.clear_map_bounds()
	await process_frame
	print("TERRAIN: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _terrain(id: String, kind: String, position: Vector2, size: Vector2) -> Dictionary:
	var record := Catalog.make_record("terrain", kind, position)
	record.id = id
	record.block_size = [size.x, size.y]
	return record

func _land(id: String, kind: String, definition: String, position: Vector2, team := "player") -> Dictionary:
	var record := Catalog.make_record(kind, definition, position, team)
	record.id = id
	return record

func _schema_fixture() -> Dictionary:
	var data := Data.create(160, 160, "水体与悬崖")
	data.entities = [
		_terrain("water_1", "water", Vector2(-20, -10), Vector2(18.5, 9.5)),
		_terrain("cliff_1", "cliff", Vector2(25, 12), Vector2(14, 5)),
	]
	return data

func _test_schema_and_overlap() -> void:
	var data := _schema_fixture()
	check(Data.VERSION == 1 and data.schema_version == 1, "adding terrain retains existing version-1 map compatibility")
	check(Data.validate(data).is_empty(), "terrain supports non-square finite footprints without team ownership")
	check(Catalog.ids("terrain") == ["water", "cliff"], "only whitelisted water and cliff kinds can be loaded")
	for kind in Catalog.ids("terrain"):
		var sample := Catalog.make_record("terrain", kind, Vector2.ZERO)
		check(Catalog.definition_id(sample) == kind and not sample.has("team"), "terrain catalog produces neutral %s records" % kind)
		check(Catalog.half_size(sample) == Catalog.terrain_size(kind) * 0.5, "terrain defaults use their explicit footprint: %s" % kind)
	for invalid_size in [null, [], [1], [1, 2, 3], "8,8", {"x": 8, "y": 8}, ["8", 8], [true, 8], [0, 8], [-1, 8], [129, 8], [8, 129], [INF, 8], [8, NAN]]:
		var invalid := data.duplicate(true)
		invalid.entities[0].block_size = invalid_size
		check(not Data.validate(invalid).is_empty(), "unsafe terrain dimensions reject cleanly: %s" % str(invalid_size))
	for patch in [{"terrain_id": "res://scripts/entities/unit_agent.gd"}, {"terrain_id": "lava"}, {"terrain_id": null}, {"pos": [NAN, 0]}, {"pos": [0, INF]}, {"pos": [80, 0]}, {"id": "cliff_1"}]:
		var invalid := data.duplicate(true)
		invalid.entities[0].merge(patch, true)
		check(not Data.validate(invalid).is_empty(), "unsafe terrain ID, position, bounds, or duplicate name rejects: %s" % str(patch))
	var missing := data.duplicate(true)
	missing.entities[0].erase("block_size")
	check(not Data.validate(missing).is_empty(), "terrain map records require an explicit footprint")
	var maximum := Data.create(160, 160)
	maximum.entities = [_terrain("maximum", "water", Vector2.ZERO, Vector2(128, 128))]
	check(Data.validate(maximum).is_empty(), "128-cell terrain patches fit the documented maximum")
	var legacy := Data.create()
	legacy.entities = [_land("unit_1", "unit", "villager", Vector2.ZERO), _land("unit_2", "unit", "villager", Vector2.ZERO)]
	check(Data.validate(legacy).is_empty(), "legacy maps may retain intentionally overlapping regular entities")
	var lake := _terrain("lake", "water", Vector2.ZERO, Vector2(12, 10))
	var overlap := Data.create()
	overlap.entities = [lake, _terrain("cliff", "cliff", Vector2(3, 0), Vector2(10, 4))]
	check(Data.validate(overlap).is_empty(), "overlapping terrain kinds can form continuous inaccessible regions")
	check(Data.placement_error(overlap, _terrain("paint", "water", Vector2.ZERO, Vector2(8, 8))).is_empty(), "continuous terrain painting may overlap existing terrain")
	for entry in [["unit", "villager"], ["building", "house"], ["resource", "gold"]]:
		var land := _land("land", entry[0], entry[1], Vector2.ZERO)
		var crossed := Data.create()
		crossed.entities = [lake, land]
		check(not Data.validate(crossed).is_empty(), "terrain prevents an imported %s from starting inside water" % entry[0])
		crossed.entities.reverse()
		check(not Data.validate(crossed).is_empty(), "terrain overlap rejection is independent of %s record order" % entry[0])
		crossed.entities = [lake]
		check(not Data.placement_error(crossed, land).is_empty(), "placing %s on existing water is rejected" % entry[0])
		crossed.entities = [land]
		check(not Data.placement_error(crossed, lake).is_empty(), "painting water beneath an existing %s is rejected" % entry[0])
	var shore := _land("shore", "building", "house", Vector2.ZERO)
	var half := Catalog.half_size(shore)
	shore.pos = [6.0 + half.x, 0.0]
	var touching := Data.create()
	touching.entities = [lake, shore]
	check(Data.validate(touching).is_empty(), "touching the shore without footprint intersection remains valid")
	shore.pos[0] -= 0.01
	check(Data.validate(touching).is_empty(), "a building may overlap the authoring rectangle while remaining on the dry beach")
	var shoreline := _rightmost(Shore.build_contours([Rect2(-6, -5, 12, 10)]))
	shore.pos = [shoreline.x + half.x - 0.01, shoreline.y]
	check(not Data.validate(touching).is_empty(), "even a partial land-footprint overlap with the actual water contour is rejected")

func _rightmost(contours: Array) -> Vector2:
	var result := Vector2(-INF, 0)
	for contour: PackedVector2Array in contours:
		for point in contour:
			if point.x > result.x: result = point
	return result

func _test_files() -> void:
	var example := Loader.load_file("res://data/maps/editor_demo.json")
	check(example.has("data") and example.data.schema_version == 1, "the original bundled editor map loads without migration")
	var path := "user://terrain-regression-roundtrip.json"
	var data := _schema_fixture()
	check(Loader.save_file(data, path).is_empty(), "authored water and cliff map saves")
	var content := FileAccess.get_file_as_string(path)
	check(content.contains("\n  ") and content.ends_with("\n") and content.contains("水体与悬崖"), "terrain maps retain formatted UTF-8 JSON")
	var loaded := Loader.load_file(path)
	check(loaded.has("data") and loaded.data == data, "terrain JSON round trip preserves exact fractional non-square dimensions")
	var invalid := data.duplicate(true)
	invalid.entities[0].block_size = [-8, 8]
	check(not Loader.save_file(invalid, path).is_empty(), "invalid terrain cannot overwrite a saved map")
	check(Loader.load_file(path).data == data, "rejected terrain save preserves the prior file")
	DirAccess.remove_absolute(path)

func _new_fixture() -> void:
	if is_instance_valid(fixture):
		fixture.free()
	Collision.clear_map_bounds()
	fixture = Node2D.new()
	root.add_child(fixture)
	entities = Node2D.new()
	entities.name = "Entities"
	fixture.add_child(entities)

func _state() -> MatchState:
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = false
	for team in [Enums.Team.PLAYER, Enums.Team.AI]:
		for resource in Enums.ResourceType.values():
			state.resources[team][resource] = 1000
	return state

func _blockers() -> Array:
	var result: Array = []
	for blocker in Navigation.collect_blockers_from_tree(self):
		if is_instance_valid(blocker) and fixture.is_ancestor_of(blocker):
			result.append(blocker)
	return result

func _test_loader_navigation() -> void:
	_new_fixture()
	var state := _state()
	var water := _terrain("water", "water", Vector2.ZERO, Vector2(12, 16))
	var cliff := _terrain("cliff", "cliff", Vector2(20, -12), Vector2(4, 8))
	for record in [water, cliff]:
		var actor := Loader.spawn_entity(record, entities, state, true)
		check(actor != null and actor is PathBlocker, "map loader constructs actual %s blockers" % record.terrain_id)
		if actor == null:
			continue
		check(actor.sim_pos == Data.position_of(record) and actor.position == IsoMath.world_to_screen(Data.position_of(record)), "loaded %s retains its logical and rendered position" % record.terrain_id)
		var size := Vector2(record.block_size[0], record.block_size[1])
		check(actor.block_size == size and actor.block_half == size * 0.5 and not actor.auto_block_size, "loaded %s uses exact non-square map dimensions instead of artwork bounds" % record.terrain_id)
		check(actor.is_in_group("path_blockers") and actor.is_in_group("terrain_regions"), "%s participates in navigation and terrain-specific placement checks" % record.terrain_id)
		check(actor.get_meta("map_id") == record.id and actor.get_meta("map_record") == record, "%s retains authoring metadata" % record.terrain_id)
		check(not actor.is_in_group("units") and not actor.is_in_group("buildings") and not actor.is_in_group("resources"), "%s is neutral terrain rather than a gameplay entity" % record.terrain_id)
	var blockers := _blockers()
	check(blockers.size() == 2, "the real navigation collector includes both terrain types exactly once")
	var nav := Navigation.new()
	nav.setup_rect(Vector2i(-40, -24), Vector2i(40, 24))
	nav.rebuild_from_blockers(blockers)
	check(nav.is_world_solid(Vector2.ZERO) and nav.is_world_solid(Vector2(20, -12)), "water and cliff interior cells are blocked")
	check(nav.is_world_walkable_with_radius(Vector2(0, 10), 0.35) and nav.is_world_walkable_with_radius(Vector2(8, 0), 0.35), "land beyond the water's short and long edges remains walkable")
	check(not nav.is_segment_walkable(Vector2(-18, 0), Vector2(18, 0), 0.35), "direct segments cannot cross a lake")
	check(not Collision.static_step_safe(Vector2(-18, 0), Vector2(18, 0), 0.35, blockers), "swept collisions prevent a large step from tunneling through water")
	check(not Collision.static_step_safe(Vector2(20, -20), Vector2(20, 0), 0.35, blockers), "swept collisions prevent a large step from tunneling through cliffs")
	var route := nav.find_path(Vector2(-18, 0), Vector2(18, 0), 0.35)
	check(not route.is_empty() and route[-1].distance_to(Vector2(18, 0)) < 0.1, "a route around water reaches the requested dry land")
	_check_path(nav, route, Vector2(-18, 0), 0.35, "water route")
	var detour := 0.0
	for point in route:
		detour = maxf(detour, absf(point.y))
	check(detour > 0.35, "water route bends around the irregular lake contour")
	route = nav.find_path(Vector2(20, -20), Vector2(20, 0), 0.35)
	check(not route.is_empty() and route[-1].distance_to(Vector2(20, 0)) < 0.1, "a route around cliffs reaches dry land behind them")
	_check_path(nav, route, Vector2(20, -20), 0.35, "cliff route")
	var shore := nav.nearest_walkable_world(Vector2.ZERO, 0.35)
	var lake := entities.get_child(0) as PathBlocker
	check(not Shore.circle_hits(shore, 0.35, lake.get_water_contours()) and nav.is_world_walkable_with_radius(shore, 0.35), "a clicked water point resolves to dry land beyond the actual coast")

func _check_path(nav: Navigation, route: PackedVector2Array, from: Vector2, radius: float, label: String) -> void:
	var valid := not route.is_empty()
	var previous := from
	for point in route:
		valid = valid and nav.is_world_walkable_with_radius(point, radius) and nav.is_segment_walkable(previous, point, radius)
		previous = point
	check(valid, "%s has no waypoint or simplified segment through inaccessible terrain" % label)

func _test_island() -> void:
	_new_fixture()
	var state := _state()
	var records := [
		_terrain("north", "water", Vector2(0, -12), Vector2(32, 8)),
		_terrain("south", "water", Vector2(0, 12), Vector2(32, 8)),
		_terrain("west", "water", Vector2(-12, 0), Vector2(8, 16)),
		_terrain("east", "water", Vector2(12, 0), Vector2(8, 16)),
	]
	var eastern: Node2D
	for record in records:
		var actor := Loader.spawn_entity(record, entities, state, true)
		if record.id == "east":
			eastern = actor
	var nav := Navigation.new()
	nav.setup(-32, 32)
	nav.rebuild_from_blockers(_blockers())
	check(nav.is_world_walkable_with_radius(Vector2.ZERO, 0.35), "the island interior itself remains valid dry land")
	check(not nav.find_path(Vector2.ZERO, Vector2(4, 4)).is_empty(), "units on an island can still travel within the island")
	check(nav.find_path(Vector2(-24, 0), Vector2.ZERO).is_empty(), "land units cannot find a path from mainland onto a closed island")
	check(nav.find_path(Vector2.ZERO, Vector2(-24, 0)).is_empty(), "land units cannot find a path out of a closed island")
	var outside := nav.find_path(Vector2(-24, 0), Vector2(24, 0))
	check(not outside.is_empty(), "the mainland route around the island remains reachable")
	_check_path(nav, outside, Vector2(-24, 0), 0.35, "mainland island detour")
	eastern.free()
	nav.rebuild_from_blockers(_blockers())
	var opened := nav.find_path(Vector2.ZERO, Vector2(24, 0))
	check(not opened.is_empty(), "opening the water ring restores an actual route from the island")
	_check_path(nav, opened, Vector2.ZERO, 0.35, "opened island route")
	Loader.spawn_entity(_terrain("east_cliff", "cliff", Vector2(12, 0), Vector2(8, 16)), entities, state, true)
	nav.rebuild_from_blockers(_blockers())
	check(nav.find_path(Vector2.ZERO, Vector2(24, 0)).is_empty(), "cliffs can close the same island passage and invalidate the previous route cache")

func _test_player_building() -> void:
	_new_fixture()
	var state := _state()
	var worker := Loader.spawn_entity(_land("builder", "unit", "villager", Vector2(0, -16)), entities, state, true)
	var selection := SelectedBuilders.new()
	selection.units.append(worker)
	fixture.add_child(selection)
	var camera := Camera2D.new()
	fixture.add_child(camera)
	var build := Construction.new()
	fixture.add_child(build)
	build.set_process(false)
	build.setup(camera, entities, selection, state, CHINESE)
	var house := GameCatalog.get_building("house")
	for kind in ["water", "cliff"]:
		var position := Vector2(-18, 0) if kind == "water" else Vector2(18, 0)
		var terrain := Loader.spawn_entity(_terrain(kind, kind, position, Vector2(12, 20)), entities, state, true)
		check(not Construction.can_place(house.footprint, position, [terrain]), "shared construction legality rejects %s interiors" % kind)
		check(not Queries.can_plan_settlement(house.footprint, position, [terrain]), "AI settlement planning rejects %s interiors" % kind)
		var before := state.resources.duplicate(true)
		check(build.begin_placement(house), "a funded builder can begin a %s rejection test" % kind)
		build._ghost.sim_pos = position
		build._update_placement_validity()
		check(not build._placement_valid and not build.confirm_placement(), "actual player construction cannot confirm on %s" % kind)
		check(state.resources == before and build._ghost.is_placement_ghost, "rejected %s placement keeps resources and preview ownership intact" % kind)
		var shoreline := position + Vector2(6 + house.footprint.x * 0.5 - 0.1, 0)
		if kind == "water": shoreline = _rightmost(terrain.get_water_contours()) + Vector2(house.footprint.x * 0.5 - 0.1, 0)
		build._ghost.sim_pos = shoreline
		build._update_placement_validity()
		check(not build.confirm_placement() and state.resources == before, "even partial house overlap with %s fails without charging resources" % kind)
		build.cancel_placement()
		await process_frame
	var before := state.resources.duplicate(true)
	check(build.begin_placement(house), "dry-land positive control begins placement")
	build._ghost.sim_pos = Vector2.ZERO
	check(build.confirm_placement(), "the same player builder can place a house on dry land")
	for resource in Enums.ResourceType.values():
		var cost: int = [house.cost_food, house.cost_wood, house.cost_gold, house.cost_stone][resource]
		check(state.resources[Enums.Team.PLAYER][resource] == before[Enums.Team.PLAYER][resource] - cost, "successful dry-land placement charges exactly the resource cost: %d" % resource)
	check(worker.order == Enums.OrderType.BUILD, "successful dry-land construction assigns the actual builder")

func _test_ai_building() -> void:
	_new_fixture()
	var state := _state()
	var bootstrap := BoundsCarrier.new()
	bootstrap.name = "Bootstrap"
	fixture.add_child(bootstrap)
	var town := Loader.spawn_entity(_land("tc", "building", "town_center", Vector2.ZERO, "ai"), entities, state, true)
	var worker := Loader.spawn_entity(_land("builder", "unit", "villager", Vector2(-10, -10), "ai"), entities, state, true)
	var ctx := AiRunContext.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.civ = TEUTONS
	ctx.team = Enums.Team.AI
	ctx.enemy_team = Enums.Team.PLAYER
	ctx.blackboard = AiBlackboard.new()
	ctx.blackboard.refresh(state, entities, ctx.team, ctx.enemy_team, 0, 20)
	var house := GameCatalog.get_building("house")
	check(Queries.next_build_position(house, town, entities, 0) == Vector2(16, 0), "AI dry-land fixture has a valid first house candidate")
	# All planner offsets are in the inward positive quadrant. Cover its rows
	# above y=8 with water and the bottom strip with cliffs, leaving the TC dry.
	Loader.spawn_entity(_terrain("blocked_rows", "water", Vector2(64, 68), Vector2(128, 120)), entities, state, true)
	var cliff := Loader.spawn_entity(_terrain("blocked_strip", "cliff", Vector2(68, 0), Vector2(120, 16)), entities, state, true)
	var before := state.resources.duplicate(true)
	var before_count := entities.get_child_count()
	var manager := Manager.new()
	check(Queries.next_build_position(house, town, entities, 0) == null, "AI rejects every house candidate when water and cliffs occupy available settlement slots")
	check(not manager.ensure_building(ctx, house), "actual local AI refuses to build in an inaccessible settlement")
	check(state.resources == before and entities.get_child_count() == before_count, "AI terrain rejection creates no foundation and deducts no resources")
	check(worker.order == Enums.OrderType.NONE and ctx.next_build_slot == 0, "rejected AI terrain planning leaves its worker and slot unchanged")
	ctx.begin_capture(1)
	check(not manager.ensure_building(ctx, house) and ctx.pending_commands.is_empty(), "captured AI likewise emits no invalid terrain placement")
	ctx.end_capture()
	cliff.free()
	check(Queries.next_build_position(house, town, entities, 0) == Vector2(16, 0), "clearing the cliff strip restores the dry-land candidate")
	check(manager.ensure_building(ctx, house), "the same AI can build after a real dry-land slot becomes available")
	check(state.resources[Enums.Team.AI][Enums.ResourceType.WOOD] == before[Enums.Team.AI][Enums.ResourceType.WOOD] - house.cost_wood, "accepted AI dry-land placement charges its normal wood cost")
	check(worker.order == Enums.OrderType.BUILD and ctx.next_build_slot == 1, "accepted AI dry-land placement assigns a builder and advances one slot")

func _test_default_map() -> void:
	_new_fixture()
	var data := Generator.generate()
	check(Data.validate(data).is_empty(), "default generated terrain remains compatible with the authoritative map validator")
	var terrain_records: Array[Dictionary] = []
	var records := {}
	var resource_count := 0
	for record in data.entities:
		records[record.id] = record
		if record.type == "terrain":
			terrain_records.append(record)
		elif record.type == "resource":
			resource_count += 1
	check(terrain_records.size() == 4, "default map supplies exactly two lakes and two cliff regions")
	check(resource_count == 1070, "adding terrain preserves the established forest and resource population")
	var kinds := {"water": 0, "cliff": 0}
	for terrain in terrain_records:
		kinds[terrain.terrain_id] += 1
		var other_id: String = String(terrain.id).replace("Player", "Ai") if String(terrain.id).begins_with("Player") else String(terrain.id).replace("Ai", "Player")
		var opposite: Dictionary = records.get(other_id, {})
		check(not opposite.is_empty() and Data.position_of(opposite) == -Data.position_of(terrain) and opposite.terrain_id == terrain.terrain_id and opposite.block_size == terrain.block_size, "default %s has a geometrically identical rotational counterpart" % terrain.id)
		var half := Catalog.half_size(terrain)
		var area := Rect2(Data.position_of(terrain) - half, half * 2)
		check(not area.has_point(Generator.BASE_POSITION) and not area.has_point(-Generator.BASE_POSITION), "%s leaves both starting town centers on land" % terrain.id)
	check(kinds.water == 2 and kinds.cliff == 2, "both players receive equal numbers of each terrain kind")
	var state := _state()
	Loader.spawn_entities(data, entities, state, true)
	var blockers := _blockers()
	var nav := Navigation.new()
	var bounds := Data.bounds(data)
	nav.setup_rect(Vector2i(bounds.position), Vector2i(bounds.end))
	nav.rebuild_from_blockers(blockers)
	for terrain in terrain_records:
		check(nav.is_world_solid(Data.position_of(terrain)), "actual default navigation blocks %s" % terrain.id)
	var route := nav.find_path(Generator.BASE_POSITION, -Generator.BASE_POSITION)
	check(not route.is_empty() and route[-1].distance_to(-Generator.BASE_POSITION) < 1, "all default resources and terrain together preserve a route between both bases")
	_check_path(nav, route, Generator.BASE_POSITION, 0.35, "default base-to-base route")
	for record in data.entities:
		if record.type != "unit":
			continue
		var radius: float = (Catalog.UNITS[record.unit_id] as UnitDef).resolved_footprint_radius()
		var from := Data.position_of(record)
		route = nav.find_path(from, Vector2.ZERO, radius)
		check(not route.is_empty() and route[-1].distance_to(Vector2.ZERO) < 1, "default starting unit %s can reach the shared central land" % record.id)
		_check_path(nav, route, from, radius, "default spawn %s route" % record.id)
