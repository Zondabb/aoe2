extends SceneTree

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
var checks := 0
var failures: Array[String] = []
var world: Node
var state: MatchState
var entities: Node2D
var serial := 0

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func _settle() -> void:
	await process_frame
	await process_frame

func _spawn(kind: String, id: String, team := "player", pos := Vector2.ZERO) -> Node2D:
	serial += 1
	var record := MapCatalog.make_record(kind,id,pos,team)
	record.id = "fixture_%d" % serial
	return Loader.spawn_entity(record,entities,state,false,{0:load("res://data/civs/chinese.tres"),1:load("res://data/civs/teutons.tres")})

func _ids(building: BuildingAgent) -> Array:
	return building.get_trainable_units().map(func(u): return String(u.id))

func _run() -> void:
	check(Catalog.data().units.size() == 41, "original filtered land unit count")
	check(Catalog.buildings().size() == 25, "original land building count")
	check(Catalog.technologies().size() == 26, "original unit and defense upgrades plus chemistry")
	for id in Catalog.data().units:
		if id not in ["monk", "trade_cart"]:
			check(Catalog.get_unit(id).attack > 0, "military unit has its original base damage " + id)
	check(Catalog.get_unit(&"chu_ko_nu").attack == 8 and Catalog.get_unit(&"scorpion").attack == 12, "zero melee channel does not hide pierce damage")
	check(Catalog.get_unit(&"bombard_cannon").civilizations == [&"teutons"], "Chinese cannot recruit bombard cannons")
	check(Catalog.get_unit(&"paladin").civilizations == [&"teutons"], "Paladin restricted to Teutons")
	check(Catalog.get_unit(&"camel").civilizations == [&"chinese"], "camel restricted to Chinese")
	for group in [Catalog.data().units,Catalog.data().buildings]:
		for id in group:
			var record: Dictionary = group[id]
			check(not String(record.display_name).is_empty(), "original translated name " + id)
			var sheets: Array = []
			if record.has("train_at"):
				check(Catalog.buildings().has(record.train_at), "training building exists " + id)
				sheets.assign(record.sprites.values())
			else:
				for civ_sheets in record.sprites.values(): sheets.append_array(civ_sheets.values())
			check(not sheets.is_empty(), "has original artwork " + id)
			for base in sheets: check(ResourceLoader.exists(base+".png") and FileAccess.file_exists(base+".json"),"imported atlas " + base)
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	session.online_active = false
	session.player_civ_id = &"chinese"
	session.ai_civ_id = &"teutons"
	world = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await _settle()
	state = world.get_node("Bootstrap").match_state
	entities = world.get_node("Entities")
	world.get_node("LandSupport").set_process(false)
	world.get_node("Camera2D").set_process(false)
	for entity in entities.get_children(): entity.set_physics_process(false)
	var tc: BuildingAgent = entities.get_node("PlayerTownCenter")
	var age: Node = state.age_progression
	var tech: Node = state.technology_progression
	age.set_process(false)
	tech.set_process(false)
	state.fog_enabled = false
	for team in [0,1]:
		for resource in Enums.ResourceType.values(): state.resources[team][resource] = 10000
	check(state.progression_enabled and state.age_of(0) == 0 and state.age_of(1) == 0,"formal games begin in Dark Age")
	check(_ids(tc) == ["villager"],"TC only trains villager, never the legacy swordsman alias")
	check(not age.can_advance(tc),"age needs two distinct complete buildings")
	_spawn("building","mill", "player",Vector2(-30,-30))
	_spawn("building","mill", "player",Vector2(-20,-30))
	check(not age.can_advance(tc),"duplicate building types do not satisfy age prerequisite")
	var lumber: BuildingAgent = _spawn("building","lumber_camp", "player",Vector2(-10,-30))
	lumber.is_complete = false
	check(not age.can_advance(tc),"unfinished prerequisites do not count")
	lumber.is_complete = true
	var food := state.get_resource(0,0)
	check(tc.start_age_upgrade(),"start Feudal")
	check(state.get_resource(0,0) == food-500,"Feudal cost debited once")
	check(not tc.start_age_upgrade() and state.get_resource(0,0) == food-500,"duplicate research rejected without charge")
	check(not tc.enqueue_train(Catalog.get_unit(&"villager")),"research blocks training")
	check(tc.cancel_age_upgrade() and state.get_resource(0,0) == food,"cancel age refunds")
	check(tc.start_age_upgrade(),"restart Feudal")
	state.frozen = true
	age._process(150)
	check(state.age_of(0) == 0,"frozen simulation pauses research")
	state.frozen = false
	age._process(129)
	check(state.age_of(0) == 0,"research does not complete early")
	if "--render" in OS.get_cmdline_user_args():
		world.get_node("UILayer/HUD")._select_town_center()
		await _settle()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/age-research.png")
	age._process(1)
	check(state.age_of(0) == 1 and state.age_of(1) == 0,"age completion is per team")
	var barracks: BuildingAgent = _spawn("building","barracks", "player",Vector2(-30,-15))
	check("militia" in _ids(barracks) and "man_at_arms" not in _ids(barracks),"advanced unit needs research")
	var militia: UnitAgent = _spawn("unit","militia", "player",Vector2(-22,-15))
	militia.hp = militia.def.max_hp * 0.5
	militia.command_move(Vector2(-18,-15))
	militia.set_physics_process(false)
	check(barracks.start_technology(&"man_at_arms"),"research next infantry tier")
	check(not barracks.enqueue_train(Catalog.get_unit(&"militia")),"technology blocks training")
	tech._process(200)
	check(militia.def.id == &"man_at_arms" and is_equal_approx(militia.hp,militia.def.max_hp*0.5),"existing unit upgrades and retains health fraction")
	check(militia.order == Enums.OrderType.MOVE,"upgrade retains active order")
	check("man_at_arms" in _ids(barracks) and "militia" not in _ids(barracks),"production replaces old unit tier")
	check(not barracks.start_technology(&"man_at_arms"),"completed research cannot be purchased twice")
	_spawn("building","blacksmith", "player",Vector2(-15,-15))
	_spawn("building","market", "player",Vector2(-3,-15))
	check(tc.start_age_upgrade(),"start Castle from two Feudal buildings")
	age._process(160)
	check(state.age_of(0) == 2,"Castle completes after original duration")
	var castle: BuildingAgent = _spawn("building","castle", "player",Vector2(12,-15))
	check("chu_ko_nu" in _ids(castle) and "teutonic_knight" not in _ids(castle),"Chinese Castle unique unit restriction")
	check(tc.start_age_upgrade(),"one Castle satisfies Imperial alternative")
	age._process(190)
	check(state.age_of(0) == 3 and not tc.start_age_upgrade(),"Imperial is final age")
	var teuton_castle: BuildingAgent = _spawn("building","castle", "ai",Vector2(25,0))
	state.set_age(1,2)
	check("teutonic_knight" in _ids(teuton_castle) and "chu_ko_nu" not in _ids(teuton_castle),"Teuton Castle unique unit restriction")
	var farm: BuildingAgent = _spawn("building","farm", "player",Vector2(-30,0))
	check(farm.has_method("extract") and farm.extract(1) > 0 and not castle.has_method("extract"),"only farms are gatherable buildings")
	var village: UnitAgent = entities.get_node("PlayerVillager1")
	village.sim_pos = farm.sim_pos
	village.command_gather(farm)
	check(village.order == Enums.OrderType.GATHER,"villager can farm")
	check(Catalog.building_reason(state,0,tc.civ,Catalog.get_building(&"castle"),entities).is_empty(),"castle construction available in Imperial with stone")
	state.resources[0][Enums.ResourceType.STONE] = 0
	check(not Catalog.building_reason(state,0,tc.civ,Catalog.get_building(&"castle"),entities).is_empty(),"stone cost enforced")
	# Real HUD input: H selects TC; upgrading and building categories remain reachable.
	var hud: Control = world.get_node("UILayer/HUD")
	hud._select_town_center()
	await _settle()
	check(hud.get_node("AgeLabel").text == "帝王时代", "HUD displays current age")
	check(hud._command_grid.get_child_count() == 15,"production commands keep fixed grid")
	if "--render" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://.godot/age-progression.png")
	world.free()
	current_scene = null
	await _settle()
	print("AGE PROGRESSION: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
