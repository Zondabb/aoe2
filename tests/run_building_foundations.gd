extends SceneTree
## Real building scenes exercise placement, construction, palette, age and wire state.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Runtime := preload("res://scripts/network/network_match.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const FARM := preload("res://scripts/entities/farm_agent.gd")
const Fortifications := preload("res://scripts/presentation/fortification_visual.gd")

var checks := 0
var failures: Array[String] = []
var fixture: Node2D
var completion_count := 0


func _initialize() -> void:
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)


func _new_fixture() -> void:
	if is_instance_valid(fixture):
		fixture.free()
	Registry.clear()
	fixture = Node2D.new()
	root.add_child(fixture)


func _state(age := 0) -> MatchState:
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.set_age(Enums.Team.PLAYER, age)
	state.set_age(Enums.Team.AI, age)
	return state


func _prepare(id: StringName, civ_id: StringName, state: MatchState, side := Enums.Team.PLAYER) -> BuildingAgent:
	var building := BUILDING.instantiate() as BuildingAgent
	if id == &"farm":
		building.set_script(FARM)
	building.def = Catalog.get_building(id)
	building.civ = load("res://data/civs/%s.tres" % civ_id) as CivDef
	building.match_state = state
	building.team = side
	building.sim_pos = Vector2(12, 12)
	return building


func _foundation(building: BuildingAgent) -> String:
	return Sprites.foundation_sheet_base(building.def.id, building.civ.id, building.match_state.age_of(building.team))


func _finished(building: BuildingAgent) -> String:
	if building.def.id == &"farm" and not building.farm_has_crops:
		return _foundation(building)
	return Sprites.building_sheet_base(building.def.id, building.civ.id, building.match_state.age_of(building.team))


func _check_art(building: BuildingAgent, expected: String, label: String) -> void:
	if building.has_node("FortificationVisual"):
		_check_fortification_art(building, expected == _foundation(building), label)
		return
	var sprite := building.get_node("Billboard") as Sprite2D
	check(not expected.is_empty() and Sprites.sheet_paths_exist(expected), label + " has imported artwork")
	check(building._sprite_sheet_base == expected, label + " selects the correct construction artwork")
	check(sprite.visible and sprite.texture != null, label + " displays its original textured billboard")
	check(not (building.get_node("Body") as CanvasItem).visible, label + " does not expose placeholder geometry")
	if sprite.texture == null or expected.is_empty():
		return
	var atlas := sprite.texture as AtlasTexture
	check(atlas != null and atlas.atlas == Sprites.load_texture(expected), label + " actually uses the expected atlas")
	check(sprite.scale.is_equal_approx(Vector2.ONE * Sprites.ORIGINAL_ART_PIXEL_SCALE_2D), label + " keeps the original art scale")
	var meta := Sprites.load_meta(expected)
	var peg := (Sprites.average_hotspot(meta) - sprite.texture.get_size() * 0.5 + sprite.offset) * sprite.scale
	check(peg.is_zero_approx(), label + " preserves the original ground anchor")
	check(sprite.modulate == Color.WHITE, label + " has no leftover placement tint")
	if not building.is_complete and not building.is_placement_ghost:
		var shadow := building.get_node_or_null("GroundShadow") as CanvasItem
		check(shadow == null or not shadow.visible, label + " hides raised building shadows while under construction")
		check(sprite.z_index < 0, label + " lies on the ground beneath its builders")


func _check_fortification_art(building: BuildingAgent, foundation: bool, label: String) -> void:
	var art := building.get_node("FortificationVisual")
	art.refresh()
	var data := Fortifications.manifest()
	var record: Dictionary = data.civilizations[String(building.civ.id)][String(building.def.id)]
	var expected: String = (data.gate_foundation_tile if building.def.id == &"gate" else record.construction) if foundation else record.complete
	var sprite := art.get_child(0) as Sprite2D
	check(Sprites.sheet_paths_exist(expected) and art.sheet_base == expected, label + " selects original directional fortification artwork")
	check(sprite.visible and sprite.texture is AtlasTexture and sprite.texture.atlas == Sprites.load_texture(expected), label + " renders expected original atlas")
	check(not building.get_node("Billboard").visible and not building.get_node("Body").visible, label + " hides old single-frame and placeholder visuals")
	check(sprite.scale.is_equal_approx(Vector2.ONE * IsoMath.SCALE_X / 48.0), label + " aligns native tiles to contiguous wall grid")
	var meta := Sprites.load_meta(expected)
	var peg := (Sprites.hotspot_at_index(meta, art.frame_index) - sprite.texture.get_size() * 0.5 + sprite.offset) * sprite.scale
	check(peg.is_zero_approx(), label + " preserves each original frame ground anchor")
	check(art.modulate == Color.WHITE and sprite.modulate == Color.WHITE, label + " clears preview tint")
	check(art.get_child_count() == (4 if foundation and building.def.id == &"gate" else 1), label + " uses correct number of foundation tiles")
	if foundation:
		var shadow := building.get_node_or_null("GroundShadow") as CanvasItem
		check(shadow == null or not shadow.visible, label + " uses only original foundation shadows")
		check(sprite.z_index < 0, label + " foundation lies beneath builders")


func _check_palette(building: BuildingAgent, color_id: int, label: String) -> void:
	var sprite := building.get_node("Billboard") as Sprite2D
	check(building.match_state.set_team_color_id(building.team, color_id), label + " accepts palette selection")
	check(building._sprite_sheet_base == _foundation(building), label + " palette refresh preserves the foundation")
	var art := building.get_node_or_null("FortificationVisual")
	if art != null: sprite = art.get_child(0) as Sprite2D
	var material := sprite.material as ShaderMaterial
	var meta := Sprites.load_meta(art.sheet_base if art != null else _foundation(building))
	var player_color: Dictionary = meta.get("player_color", {})
	if player_color.get("mode", "") == "none":
		check(material == null, label + " keeps uncolored original foundation art")
	else:
		check(material != null, label + " retains the original player color shader")
		if material != null:
			check(int(material.get_shader_parameter("target_player")) == color_id, label + " updates the requested player palette row")


func _test_every_building_and_age() -> void:
	_new_fixture()
	for civilization in [&"chinese", &"teutons"]:
		for age in 4:
			var state := _state(age)
			for id in Catalog.buildings():
				var building := _prepare(StringName(id), civilization, state)
				var label := "%s %s age %d" % [civilization, id, age]
				building.start_construction()
				fixture.add_child(building)
				building.set_physics_process(false)
				var foundation := _foundation(building)
				var final_art := _finished(building)
				check(foundation == final_art if id == &"farm" else foundation != final_art, label + " has bare farm soil until harvesting or separate completed building art")
				_check_art(building, foundation, label + " initial")
				check(not building.is_complete and is_zero_approx(building.build_progress), label + " starts unfinished")
				check(state.population_cap[building.team] == 0, label + " adds no population before completion")
				var initial_half := building.block_half
				building.add_build_progress(building.def.build_time * 0.5)
				_check_art(building, foundation, label + " halfway")
				building.add_build_progress(building.def.build_time * 0.49)
				_check_art(building, foundation, label + " almost complete")
				check(not building.is_complete, label + " does not display completion at 99 percent")
				_check_palette(building, 7, label)
				building.add_build_progress(building.def.build_time)
				_check_art(building, final_art, label + " complete")
				check(building.is_complete and is_equal_approx(building.build_progress, building.def.build_time), label + " finishes at its definition duration")
				check(state.population_cap[building.team] == building.def.population_provided, label + " adds population only on completion")
				check(building.block_half == initial_half, label + " keeps collision and selection placement through completion")
				building.free()
				check(state.population_cap[Enums.Team.PLAYER] == 0, label + " removal returns population accounting")


func _count_completion(_building: BuildingAgent) -> void:
	completion_count += 1


func _test_placement_and_state_transitions() -> void:
	_new_fixture()
	for id in [&"house", &"barracks", &"castle", &"town_center", &"farm", &"stone_wall", &"gate", &"palisade_wall"]:
		if Catalog.get_building(id) == null:
			check(false, "%s transition fixture exists in the catalog" % id)
			continue
		var state := _state(3)
		var ghost := _prepare(id, &"chinese", state)
		ghost.is_placement_ghost = true
		fixture.add_child(ghost)
		ghost.set_physics_process(false)
		check(ghost._sprite_sheet_base == _finished(ghost), "%s placement previews the whole building" % id)
		check(state.population_cap[0] == 0, "%s preview reserves no population" % id)
		ghost.set_ghost_visual(false)
		check((ghost.get_node("Billboard") as Sprite2D).modulate.a < 1, "%s invalid preview has placement tint" % id)
		ghost.start_construction()
		check(ghost._sprite_sheet_base == _finished(ghost), "%s still previews the whole building while it is a ghost" % id)
		ghost.clear_ghost_visual()
		_check_art(ghost, _foundation(ghost), "%s placed ghost" % id)
		check(ghost.is_in_group("buildings") and not ghost.is_placement_ghost, "%s placed foundation enters the building registry" % id)
		check(state.population_cap[0] == 0, "%s placed foundation adds no population" % id)
		if id == &"farm":
			check(not ghost.is_in_group("resource_nodes"), "placed farm is not harvestable during construction")
			check(is_zero_approx(float(ghost.call("extract", 1.0))), "unfinished farm cannot produce food")
		completion_count = 0
		ghost.construction_completed.connect(_count_completion)
		ghost.add_build_progress(ghost.def.build_time)
		_check_art(ghost, _finished(ghost), "%s ghost completion" % id)
		check(completion_count == 1, "%s emits completion exactly once" % id)
		ghost.add_build_progress(ghost.def.build_time)
		check(completion_count == 1, "%s repeated progress cannot repeat completion" % id)
		if id == &"farm":
			check(ghost.is_in_group("resource_nodes"), "completed farm joins the resource registry")
			check(float(ghost.call("extract", 1.0)) > 0.0, "completed farm yields food")
		ghost.free()
		var ready_building := _prepare(id, &"teutons", state)
		fixture.add_child(ready_building)
		ready_building.start_construction()
		_check_art(ready_building, _foundation(ready_building), "%s start after ready" % id)
		check(state.population_cap[0] == 0, "%s starting construction after ready revokes completed population" % id)
		if id == &"farm":
			check(not ready_building.is_in_group("resource_nodes"), "farm restarted after ready leaves the resource registry")
		state.frozen = true
		ready_building._physics_process(60.0)
		check(not ready_building.is_complete and ready_building.build_progress == 0.0, "%s pause keeps the unfinished building" % id)
		_check_art(ready_building, _foundation(ready_building), "%s paused" % id)
		state.frozen = false
		ready_building.free()


func _test_age_refresh() -> void:
	_new_fixture()
	for civilization in [&"chinese", &"teutons"]:
		for id in [&"house", &"barracks", &"castle", &"town_center", &"farm", &"gate"]:
			var state := _state()
			var building := _prepare(id, civilization, state)
			building.start_construction()
			fixture.add_child(building)
			building.add_build_progress(building.def.build_time * 0.25)
			var progress := building.build_progress
			for age in 4:
				state.set_age(0, age)
				_check_art(building, _foundation(building), "%s %s upgrade to age %d" % [civilization, id, age])
				check(not building.is_complete and building.build_progress == progress, "%s %s age refresh keeps construction progress" % [civilization, id])
			building.add_build_progress(building.def.build_time)
			_check_art(building, _finished(building), "%s %s completes in the current age" % [civilization, id])
			building.free()


func _test_direct_placement_and_restored_sites() -> void:
	_new_fixture()
	for civilization in [&"chinese", &"teutons"]:
		for id in [&"house", &"town_center", &"farm"]:
			var state := _state(2)
			var ghost := _prepare(id, civilization, state)
			ghost.is_placement_ghost = true
			fixture.add_child(ghost)
			ghost.set_ghost_visual(true)
			ghost.clear_ghost_visual()
			_check_art(ghost, _foundation(ghost), "%s %s direct placement" % [civilization, id])
			check(not ghost.is_complete and ghost.build_progress == 0.0, "%s %s direct placement starts a new foundation" % [civilization, id])
			check(state.population_cap[0] == 0, "%s %s direct placement has no completed population" % [civilization, id])
			ghost.free()
			var restored := _prepare(id, civilization, state)
			restored.is_complete = false
			restored.build_progress = restored.def.build_time * 0.25
			fixture.add_child(restored)
			_check_art(restored, _foundation(restored), "%s %s restored site" % [civilization, id])
			check(not restored.is_complete and is_equal_approx(restored.build_progress, restored.def.build_time * 0.25), "%s %s readiness preserves restored construction state" % [civilization, id])
			restored.free()


func _runtime(authority: bool) -> Node:
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	fixture.add_child(runtime.entities)
	runtime.match_state = _state()
	runtime._civs = {0: load("res://data/civs/chinese.tres"), 1: load("res://data/civs/teutons.tres")}
	runtime.is_host = authority
	runtime.local_team = 0 if authority else 1
	fixture.add_child(runtime)
	runtime.set_process(false)
	return runtime


func _packet(host: Node) -> Dictionary:
	return JSON.parse_string(JSON.stringify(host.capture_snapshot())) as Dictionary


func _test_network_construction() -> void:
	_new_fixture()
	var host := _runtime(true)
	var guest := _runtime(false)
	var sites: Array[BuildingAgent] = []
	for side in [Enums.Team.PLAYER, Enums.Team.AI]:
		for id in [&"house", &"town_center", &"farm", &"gate"]:
			var building := _prepare(id, &"chinese" if side == 0 else &"teutons", host.match_state, side)
			building.start_construction()
			building.sim_pos = Vector2(5 + sites.size() * 4, 10)
			host.entities.add_child(building)
			sites.append(building)
	check(guest.apply_snapshot(_packet(host), 1), "JSON snapshot creates initially unfinished network buildings")
	for building in sites:
		var copy := guest._resolve(host.entity_id(building)) as BuildingAgent
		check(copy != null and not copy.is_complete, "%s replica starts unfinished" % building.def.id)
		if copy == null:
			continue
		_check_art(copy, _foundation(copy), "%s initial replica" % building.def.id)
		if building.def.id == &"farm":
			check(not copy.is_in_group("resource_nodes"), "initial unfinished farm replica is not harvestable")
		building.add_build_progress(building.def.build_time * 0.5)
	check(guest.apply_snapshot(_packet(host), 2), "JSON snapshot updates construction progress")
	for building in sites:
		var copy := guest._resolve(host.entity_id(building)) as BuildingAgent
		_check_art(copy, _foundation(copy), "%s halfway replica" % building.def.id)
		check(is_equal_approx(copy.build_progress, building.build_progress), "%s wire progress agrees with host" % building.def.id)
	for side in [0, 1]:
		host.match_state.set_age(side, 3)
	check(guest.apply_snapshot(_packet(host), 3), "network age update applies to unfinished buildings")
	for building in sites:
		var copy := guest._resolve(host.entity_id(building)) as BuildingAgent
		_check_art(copy, _foundation(copy), "%s age refreshed replica" % building.def.id)
		building.add_build_progress(building.def.build_time)
	check(guest.apply_snapshot(_packet(host), 4), "JSON snapshot completes network buildings")
	for building in sites:
		var copy := guest._resolve(host.entity_id(building)) as BuildingAgent
		check(copy.is_complete, "%s replica receives completion" % building.def.id)
		_check_art(copy, _finished(copy), "%s completed replica" % building.def.id)
		if building.def.id == &"farm":
			check(copy.is_in_group("resource_nodes"), "completed farm replica becomes a resource")
		building.start_construction()
	check(guest.apply_snapshot(_packet(host), 5), "newer unfinished state can replace a completed network presentation")
	for building in sites:
		var copy := guest._resolve(host.entity_id(building)) as BuildingAgent
		_check_art(copy, _foundation(copy), "%s restarted replica" % building.def.id)
		if building.def.id == &"farm":
			check(not copy.is_in_group("resource_nodes"), "restarted farm replica ceases to be a resource")
	for side in [0, 1]:
		check(guest.match_state.population_cap[side] == host.match_state.population_cap[side], "snapshot restores population without counting foundation births")


func _run() -> void:
	_test_every_building_and_age()
	_test_placement_and_state_transitions()
	_test_age_refresh()
	_test_direct_placement_and_restored_sites()
	_test_network_construction()
	if is_instance_valid(fixture):
		fixture.free()
	Registry.clear()
	print("Building foundations: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
