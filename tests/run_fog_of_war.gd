extends SceneTree

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Holder := preload("res://scripts/systems/fog_of_war_holder.gd")
const Access := preload("res://scripts/systems/fog_access.gd")
const Events := preload("res://scripts/ai_gateway/event_buffer.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const Validator := preload("res://scripts/ai_gateway/command_validator.gd")
const UnitScene := preload("res://scenes/entities/unit_view.tscn")
const BuildingScene := preload("res://scenes/entities/building_view.tscn")
var failures: Array[String] = []
var checks := 0

class Source extends Node2D:
	var team := 0
	var sim_pos := Vector2.ZERO
	var hp := 100.0
	var radius := 6.0
	var is_placement_ghost := false
	func resolved_vision_radius() -> float:
		return radius

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	_test_masks()
	_test_circle_union()
	await _test_integration()
	await _test_scenes()
	_profile()
	check(checks >= 65, "all test sections must run to completion")
	print("FOG TESTS: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_masks() -> void:
	var fog := Fog.new()
	fog.setup(-20, 20)
	check(fog.cell_at(Vector2(-19.8,-19.2)) == Vector2i.ZERO, "negative coordinates must floor")
	check(fog.cell_at(Vector2(20,20)) == Vector2i(39,39), "maximum edge must clamp")
	check(fog.cell_at(Vector2(20.01,0)).x == -1, "out of bounds must reject")
	var a := Source.new()
	a.sim_pos = Vector2(0.5,0.5)
	var b := Source.new()
	b.team = 1
	b.sim_pos = Vector2(15.5,15.5)
	fog.rebuild([a,b])
	check(fog.state_at(0, a.sim_pos) == Fog.State.VISIBLE, "own circle must reveal cells")
	check(fog.state_at(0, b.sim_pos) == Fog.State.UNEXPLORED, "team masks must be independent")
	check(fog.state_at(0, Vector2(6.5,0.5)) == Fog.State.VISIBLE, "circle includes radius edge")
	check(fog.state_at(0, Vector2(6.5,6.5)) == Fog.State.UNEXPLORED, "circle must exclude square corner")
	check(fog.footprint_visible(0, Vector2(7,0.5), Vector2(4,2)), "partially seen building is visible")
	check(not fog.footprint_visible(0, Vector2(7,0.5), Vector2(4,2), true), "placement requires whole footprint")
	var rev := fog.revision
	fog.rebuild([a,b])
	check(rev == fog.revision, "unchanged mask must reuse GPU texture revision")
	a.sim_pos = Vector2(-14,-14)
	fog.rebuild([a,b])
	check(fog.state_at(0, Vector2(0.5,0.5)) == Fog.State.EXPLORED, "exploration survives lost sight")
	a.hp = 0
	fog.rebuild([a,b])
	check(fog.source_counts[0] == 0 and fog.state_at(0, a.sim_pos) == Fog.State.EXPLORED, "dead sources must stop revealing")
	a.hp = 10
	a.is_placement_ghost = true
	fog.rebuild([a])
	check(fog.source_counts[0] == 0, "placement ghosts cannot explore")
	fog.reset()
	check(fog.state_at(0, Vector2.ZERO) == Fog.State.UNEXPLORED and fog.memories[0].is_empty(), "reset clears all history")
	a.free()
	b.free()

func _test_circle_union() -> void:
	var fog := Fog.new()
	fog.setup(-20,20)
	var sources: Array = []
	for index in 12:
		var source := Source.new()
		source.sim_pos = Vector2((index*7)%37-18.2, (index*11)%37-18.7)
		source.radius = 2.5 + index%6
		sources.append(source)
	fog.rebuild(sources)
	var matches := true
	for y in 40:
		for x in 40:
			var pos := Vector2(x-19.5,y-19.5)
			var expected := false
			for source in sources:
				if source.sim_pos.distance_squared_to(pos) <= source.radius*source.radius:
					expected = true
			matches = matches and (fog.state_at(0,pos) == Fog.State.VISIBLE) == expected
	check(matches, "optimized overlapping/disjoint circle raster must match independent distance oracle")
	for source in sources:
		source.free()

func _test_integration() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	world.add_child(entities)
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	world.add_child(layer)
	var selection := preload("res://scripts/input/selection_controller_2d.gd").new()
	selection.name = "SelectionController"
	layer.add_child(selection)
	var state := MatchState.new()
	state.setup_defaults()
	state.population_cap[0] = 200
	state.population_cap[1] = 200
	var scout := _unit(entities, state, 0, Vector2(0.5,0.5))
	scout.set_vision_radius(8)
	var enemy := _unit(entities, state, 1, Vector2(4,0.5))
	var town := _building(entities, state, 1, Vector2(4,4))
	check(Fog.radius_of(town) == 16.0, "completed building uses configured vision")
	town.is_complete = false
	check(Fog.radius_of(town) == 2.0, "foundation uses reduced construction vision")
	town.is_complete = true
	var hidden := _building(entities, state, 1, Vector2(-14,14))
	var resource := preload("res://scripts/entities/resource_node.gd").new()
	resource.sim_pos = Vector2(2,2)
	entities.add_child(resource)
	Holder.install(world, state, -20,20)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	var fog: RefCounted = state.fog
	check(enemy.visible and town.visible and not hidden.visible, "live entity visibility must follow team fog")
	check(fog.memories[0].has(town.get_instance_id()), "visible static buildings must be remembered")
	check(not fog.memories[0].has(hidden.get_instance_id()), "unseen buildings cannot produce memory")
	var pending := MatchState.new()
	pending.fog_enabled = true
	check(not Access.state_can_see(pending,0,hidden), "enabled but uninitialized fog must fail closed")
	var resource_key := resource.get_instance_id()
	check(fog.memories[0].has(resource_key), "visible resources must be remembered")
	check(not is_finite(selection._pick_distance(hidden, hidden.position)), "hidden building cannot be picked")
	var town_key := town.get_instance_id()
	var known_pos: Vector2 = fog.memories[0][town_key].sim_pos
	scout.command_attack(enemy)
	check(scout.order == Enums.OrderType.ATTACK, "visible enemy accepts attack")
	enemy.sim_pos = Vector2(18,18)
	holder.rebuild_now()
	scout._process_attack(0.01)
	check(scout.order == Enums.OrderType.MOVE and scout.get("_attack_target") == null, "lost enemy must drop live reference")
	check(scout.get("_move_target") == Vector2(4,0.5), "pursuit must use last observed position")
	scout.command_stop()
	scout.sim_pos = Vector2(-14,-14)
	holder.rebuild_now()
	check(not town.visible and holder.get("_memory_views").has(town_key), "hidden known building must render a memory proxy")
	resource.extract(10000)
	holder.rebuild_now()
	check(fog.memories[0].has(resource_key), "hidden resource depletion must retain memory")
	var proxy: Node = holder.get("_memory_views")[town_key]
	check(proxy.get_script() == null and proxy.get_groups().size() == 1 and proxy.is_in_group("occlusion_memories") and proxy.get("def") == null, "memory proxy can register for rendering only, never simulation")
	town.queue_free()
	await process_frame
	holder.rebuild_now()
	check(fog.memories[0].has(town_key), "hidden destruction must retain the last seen building")
	var partial: Vector2i = fog.cell_at(known_pos)
	fog.visible_now[0][partial.y*fog.side+partial.x] = 255
	holder._update_memories(entities.get_children())
	check(fog.memories[0].has(town_key), "partial footprint sight cannot confirm destruction")
	holder.rebuild_now()
	check(fog.memories[0][town_key].sim_pos == known_pos, "memory must be a value snapshot")
	var obs := Observation.build(state, entities, 0, 1, 0)
	check(obs.derived.enemy_tc_id == -1 and obs.derived.enemy_tc_pos == [0.0,0.0], "derived enemy TC cannot bypass fog")
	check(obs.entities.size() == 1, "observation includes only own or visible live entities")
	var auto_combat := preload("res://scripts/systems/auto_combat_director.gd").new()
	auto_combat.setup(entities, state)
	check(auto_combat.pick_target_for_unit(scout) == null, "auto combat radius cannot reveal enemies through fog")
	var ctx := CommandExecutionContext.new()
	ctx.match_state = state
	ctx.team = 0
	ctx.entities = entities
	var attack := {"op":"attack", "unit_id":Registry.id_of(scout), "target_id":Registry.id_of(enemy)}
	check(Validator.validate(attack,ctx).reason == "target_unavailable", "hidden target commands must fail")
	attack.target_id = 99999999
	check(Validator.validate(attack,ctx).reason == "target_unavailable", "missing and hidden targets must have identical errors")
	var placement := {"op":"place_building", "building_def_id":"house", "pos":[14.0,14.0]}
	check(Validator.validate(placement,ctx).reason == "need_vision", "building placement must reject unseen footprint first")
	Events.clear()
	Events.push_for_entity({"type":"entity_destroyed", "entity_id":Registry.id_of(enemy)},enemy)
	var events := Events.drain()
	check(Events.for_team(events,0,true).is_empty(), "hidden lifecycle event must not leak")
	check(Events.for_team(events,1,true).size() == 1, "owner must receive own lifecycle event")
	var history: PackedByteArray = fog.explored[0].duplicate()
	selection._add_selection(scout)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_G
	key.pressed = true
	holder._unhandled_input(key)
	check(holder.debug_mode, "G InputMap action must enter debug mode")
	key.echo = true
	holder._unhandled_input(key)
	check(holder.debug_mode, "G key repeat must not toggle debug")
	var input := LineEdit.new()
	layer.add_child(input)
	input.grab_focus()
	key.echo = false
	holder._unhandled_input(key)
	check(holder.debug_mode, "typing G in a text field must not exit debug")
	input.release_focus()
	input.queue_free()
	holder.set_view(1)
	check(selection.read_only and selection.select_all_teams and not scout.visible, "AI debug perspective must be read-only and hide unseen player units")
	holder.get("_choices").item_selected.emit(0)
	check(holder.view_team == -1, "first dropdown item must select omniscience")
	check(enemy.visible and hidden.visible, "omniscient display must reveal live entities")
	check(not resource.visible, "omniscient view cannot revive a depleted resource")
	check(fog.explored[0] == history and not fog.can_see(0,enemy), "debug reveal must not change gameplay information")
	check(Observation.build(state,entities,0,1,0) == obs, "debug perspective cannot change AI observation")
	selection._add_selection(scout)
	selection._issue_move(Vector2(10,10))
	check(scout.order == Enums.OrderType.NONE, "debug selection cannot issue local commands")
	holder.set_debug_mode(false)
	check(holder.view_team == 0 and not selection.read_only and not selection.select_all_teams, "exit debug must restore view and input flags")
	check(selection.get_primary_selection() == scout, "exit debug must restore legal saved selection")
	scout.sim_pos = known_pos
	holder.rebuild_now()
	check(not fog.memories[0].has(town_key), "seeing empty entire footprint must invalidate old memory")
	check(not fog.memories[0].has(resource_key), "re-observing depleted resource clears memory")
	scout.hp = 0
	holder.rebuild_now()
	obs = Observation.build(state,entities,0,1,0)
	check(obs.derived.enemy_tc_id == -1, "zero observers cannot reveal hidden TC")
	holder.reset_match()
	check(fog.memories[0].is_empty() and fog.visible_now[0].count(255) == 0, "reset with no living sources clears player fog")
	world.queue_free()
	await process_frame
	Registry.clear()
	Events.clear()

func _unit(parent: Node, state: MatchState, team: int, pos: Vector2) -> Node2D:
	var unit := UnitScene.instantiate() as Node2D
	unit.def = load("res://data/units/swordsman.tres")
	unit.civ = load("res://data/civs/chinese.tres")
	unit.team = team
	unit.match_state = state
	unit.sim_pos = pos
	parent.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _building(parent: Node, state: MatchState, team: int, pos: Vector2) -> Node2D:
	var building := BuildingScene.instantiate() as Node2D
	building.def = load("res://data/buildings/town_center.tres")
	building.civ = load("res://data/civs/chinese.tres")
	building.team = team
	building.match_state = state
	building.sim_pos = pos
	parent.add_child(building)
	building.set_physics_process(false)
	return building

func _test_scenes() -> void:
	for scene in ["match_2d", "ai_vs_ai", "combat_arena", "combat_duel_arena", "pathfinding_arena", "pathfinding_test"]:
		var world := load("res://scenes/%s.tscn" % scene).instantiate() as Node
		root.add_child(world)
		await process_frame
		await process_frame
		check(world.has_meta("fog_holder"), "%s must install match-local fog" % scene)
		if world.has_meta("fog_holder"):
			var holder: Node = world.get_meta("fog_holder")
			check(holder.fog.ready, "%s must finish first visibility before play" % scene)
			if scene == "match_2d":
				check(not world.get_node("Entities/AiTownCenter").visible, "real match must hide enemy base on first frame")
				world.get_node("UILayer/SelectionController")._add_selection(world.get_node("Entities/PlayerVillager1"))
				check(world.get_node("BuildSystem").begin_placement(load("res://data/buildings/house.tres")), "normal view allows placement preview")
			holder.set_debug_mode(true)
			if scene == "match_2d":
				check(not world.get_node("BuildSystem").is_placing(), "entering debug cancels pending placement")
				check(not world.get_node("BuildSystem").begin_placement(load("res://data/buildings/house.tres")), "debug blocks new construction")
			holder.set_view(1)
			holder.set_view(-1)
			holder.set_debug_mode(false)
		world.queue_free()
		await process_frame
	Registry.clear()
	Events.clear()

func _profile() -> void:
	var fog := Fog.new()
	fog.setup(-60,60)
	for count in [100,300,500]:
		var sources: Array = []
		for index in count:
			var source := Source.new()
			source.team = index % 2
			source.radius = 16
			source.sim_pos = Vector2((index*17)%110-55, (index*29)%110-55)
			sources.append(source)
		var total := 0.0
		for repeat in 3:
			fog.rebuild(sources)
			total += fog.elapsed_ms
		print("FOG PROFILE sources=%d radius=16 map=120x120 average=%.2fms" % [count,total/3])
		for source in sources:
			source.free()
