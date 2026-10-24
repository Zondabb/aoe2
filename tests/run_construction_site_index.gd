extends SceneTree
## The bucketed construction-site checks in DecisionContextBuilder must give
## exactly the answers of the original full scans: Build.can_place, the
## original _planning_clear loop and Perimeter.keeps_wall_strip_clear.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const DC := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const Build := preload("res://scripts/systems/build_system.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const TEAM := 1
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	UnitDebugFocus.set_spectator_mode(true)
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var entities: Node2D = world.get_node("Entities")
	var state: MatchState = world.get_node("Bootstrap").match_state
	for node in entities.get_children(): node.set_physics_process(false)
	var base := Vector2.ZERO
	for node in entities.get_children():
		if node.get("team") == TEAM and node.get("def") is BuildingDef and node.get("def").id == &"town_center": base = node.sim_pos
	# Military exits, gates (orientation-dependent footprints), walls and farms.
	var civ: CivDef = load("res://data/civs/teutons.tres")
	var layout := [["barracks", Vector2(30, 0), 0], ["archery_range", Vector2(-30, 6), 0], ["stable", Vector2(0, 32), 0],
		["house", Vector2(18, 18), 0], ["house", Vector2(-18, -18), 0], ["farm", Vector2(10, -12), 0], ["mill", Vector2(-24, 24), 0],
		["gate", Vector2(40, -20), 2], ["gate", Vector2(-40, 20), 1], ["palisade_wall", Vector2(44, -10), 0], ["stone_wall", Vector2(45, -10), 0]]
	for item: Array in layout:
		var building := BUILDING_VIEW.instantiate()
		if item[0] == "farm": building.set_script(load("res://scripts/entities/farm_agent.gd"))
		building.set("def", Catalog.get_building(StringName(item[0])))
		building.set("team", TEAM)
		building.set("civ", civ)
		building.set("match_state", state)
		building.set("sim_pos", (base + item[1]).round())
		if Walls.is_fortification(StringName(item[0])): Walls.configure_building(building, item[2])
		entities.add_child(building)
	# The blocker set DecisionContextBuilder passes: buildings and terrain regions.
	var blockers: Array = []
	var water := 0
	for node in entities.get_children():
		if node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		if node.get("def") is BuildingDef or node.is_in_group("terrain_regions"): blockers.append(node)
		if node.has_method("get_water_contours") and not node.get_water_contours().is_empty(): water += 1
	check(water > 0, "default map provides water contours for the shore path")
	var sites := DC._site_index(blockers)
	var bounds := state.map_bounds
	var definitions: Array[BuildingDef] = []
	for id in DC.BUILD_PRIORITY: definitions.append(Catalog.get_building(StringName(id)))
	var points: Array[Vector2] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261024
	for i in 4000:
		var point := Vector2(rng.randf_range(bounds.position.x, bounds.end.x), rng.randf_range(bounds.position.y, bounds.end.y))
		points.append(point.round() if i % 2 == 0 else point)
	for i in 3000:
		points.append((base + Vector2(rng.randf_range(-70, 70), rng.randf_range(-70, 70))).round())
	# Exactly touching and barely overlapping footprints exercise the strict edges.
	for blocker in blockers:
		var footprint: Vector2 = blocker.call("get_placement_footprint") if blocker.has_method("get_placement_footprint") else (blocker.get("block_size") if blocker.get("block_size") is Vector2 else Vector2.ONE)
		for definition in [Catalog.get_building(&"house"), Catalog.get_building(&"barracks")]:
			var reach: Vector2 = (footprint + definition.footprint) * 0.5
			var planning_reach: Vector2 = (DC.planning_footprint(definition) + DC.planning_footprint(blocker.get("def")) if blocker.get("def") is BuildingDef else footprint) * 0.5 + Vector2.ONE * DC.LANE_WIDTH * 0.5
			for offset in [Vector2(reach.x, 0), Vector2(0, -reach.y), Vector2(reach.x - 0.001, 0), Vector2(planning_reach.x, 0), Vector2(-planning_reach.x, 0), Vector2(0, planning_reach.y), Vector2(planning_reach.x - 0.001, 1)]:
				points.append(blocker.sim_pos + offset)
	var outcomes := {"place_true": 0, "place_false": 0, "plan_true": 0, "plan_false": 0, "water_false": 0}
	var mismatches := {"place": 0, "plan": 0, "strip": 0}
	for index in points.size():
		var point := points[index]
		var definition := definitions[index % definitions.size()]
		var expected_place := Build.can_place(definition.footprint, point, blockers)
		if _hits_water(definition.footprint, point, blockers): outcomes.water_false += 1
		if DC._can_place(definition.footprint, point, sites) != expected_place: mismatches.place += 1
		outcomes["place_true" if expected_place else "place_false"] += 1
		var expected_plan := _reference_planning_clear(definition, point, base, blockers, bounds)
		if DC._planning_clear(definition, point, base, sites, bounds) != expected_plan: mismatches.plan += 1
		outcomes["plan_true" if expected_plan else "plan_false"] += 1
	for key in ["place_true", "place_false", "plan_true", "plan_false"]: check(outcomes[key] > 100, "both outcomes are exercised: %s" % JSON.stringify(outcomes))
	check(outcomes.water_false > 10, "shore rejections are exercised: %d" % outcomes.water_false)
	check(mismatches.place == 0, "indexed placement matches Build.can_place (%d mismatches)" % mismatches.place)
	check(mismatches.plan == 0, "indexed planning clearance matches the full scan (%d mismatches)" % mismatches.plan)
	var plan := {"rect": Rect2(base - Vector2.ONE * 28, Vector2.ONE * 56)}
	for strip_plan in [plan, {}]:
		var strips := Perimeter.wall_strips(strip_plan)
		for point in points:
			if Perimeter.strips_clear(strips, point, Vector2(7, 7)) != _reference_strip_clear(strip_plan, point, Vector2(7, 7)): mismatches.strip += 1
	check(mismatches.strip == 0, "precomputed wall bands match the per-point check (%d mismatches)" % mismatches.strip)
	print("CONSTRUCTION SITE INDEX: %d checks, %d failures, %d points %s" % [checks, failures.size(), points.size(), JSON.stringify(outcomes)])
	quit(0 if failures.is_empty() else 1)

## The original per-blocker loop of DecisionContextBuilder._planning_clear.
func _reference_planning_clear(definition: BuildingDef, pos: Vector2, base: Vector2, blockers: Array, bounds: Rect2) -> bool:
	var size := DC.planning_footprint(definition)
	var area := Rect2(pos - size * 0.5, size)
	if not bounds.encloses(area.grow(1.0)): return false
	var offset := pos - base
	if absf(offset.x) < size.x * 0.5 + DC.LANE_WIDTH * 0.5 or absf(offset.y) < size.y * 0.5 + DC.LANE_WIDTH * 0.5: return false
	for blocker in blockers:
		var other: BuildingDef = blocker.get("def") as BuildingDef
		if other == null: continue
		var other_pos: Vector2 = blocker.get("sim_pos")
		var other_size := DC.planning_footprint(other)
		if area.grow(DC.LANE_WIDTH * 0.5).intersects(Rect2(other_pos - other_size * 0.5, other_size)): return false
		if String(other.id) in DC.MILITARY_BUILDINGS:
			var exit := Rect2(other_pos + Vector2(other.footprint.x * 0.5, -1.5), Vector2(5.0, 3.0))
			if area.intersects(exit): return false
	return true

## The original Perimeter.keeps_wall_strip_clear body.
func _reference_strip_clear(plan: Dictionary, point: Vector2, footprint: Vector2) -> bool:
	if plan.is_empty(): return true
	var area := Rect2(point - footprint * 0.5, footprint).grow(2.0)
	for side: Dictionary in Perimeter.sides(plan.rect):
		var size: Vector2 = (side.end - side.start).abs() + Vector2.ONE
		var strip := Rect2(side.start.min(side.end) - Vector2.ONE * 0.5, size)
		if area.intersects(strip): return false
	return true

func _hits_water(footprint: Vector2, point: Vector2, blockers: Array) -> bool:
	for blocker in blockers:
		if blocker.has_method("get_water_contours") and not blocker.get_water_contours().is_empty():
			if preload("res://scripts/world/shore_geometry.gd").intersects_rect(Rect2(point - footprint * 0.5, footprint), blocker.get_water_contours()): return true
	return false
