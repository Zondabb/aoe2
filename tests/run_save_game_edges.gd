extends SceneTree
## Save recovery must resume work and damage, including asynchronous navigation
## and visual memories whose original building no longer exists.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const MapDataScript := preload("res://scripts/world/map_data.gd")
const FogHolder := preload("res://scripts/systems/fog_of_war_holder.gd")
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const BuildingView := preload("res://scenes/entities/building_view.tscn")
const ProjectileView := preload("res://scenes/entities/projectile_view.tscn")
const Age := preload("res://scripts/systems/age_progression.gd")
const Technology := preload("res://scripts/systems/technology_progression.gd")

class Fixture extends Node:
	var match_state: MatchState
	var player_civ: CivDef = preload("res://data/civs/chinese.tres")
	var ai_civ: CivDef = preload("res://data/civs/teutons.tres")
	var map_data: Dictionary = MapData.create(80, 80, "Save recovery edges")
	var setup_ready := true

var checks := 0
var saves: GDScript
var failures: Array[String] = []
var world: Node2D
var bootstrap: Fixture
var entities: Node2D
var state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _fixture(with_fog := false) -> void:
	if is_instance_valid(world): world.free()
	world = Node2D.new()
	world.name = "Match"
	root.add_child(world)
	bootstrap = Fixture.new()
	bootstrap.name = "Bootstrap"
	state = MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.unit_catalog.assign(Catalog.units().values())
	state.team_civilizations = {0: &"chinese", 1: &"teutons"}
	state.map_bounds = Rect2(-40, -40, 80, 80)
	for team in 2:
		for type in 4: state.resources[team][type] = 10000
	bootstrap.match_state = state
	world.add_child(bootstrap)
	entities = Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var camera := Camera2D.new()
	camera.name = "Camera2D"
	world.add_child(camera)
	var nav := NavServiceHolder.new()
	nav.name = "NavService"
	nav.setup(-40, 40)
	world.add_child(nav)
	nav.set_process(false)
	var age := Age.new()
	age.name = "AgeProgression"
	world.add_child(age)
	age.setup(state, entities)
	age.set_process(false)
	var tech := Technology.new()
	tech.name = "TechnologyProgression"
	world.add_child(tech)
	tech.setup(state, entities)
	tech.set_process(false)
	if with_fog:
		FogHolder.install_rect(world, state, Vector2(-40, -40), Vector2(40, 40))
		world.get_node("FogOfWar").set_physics_process(false)

func _unit(id: StringName, team: int, position: Vector2, label: String) -> UnitAgent:
	var unit := UnitView.instantiate() as UnitAgent
	unit.def = Catalog.get_unit(id)
	unit.team = team as Enums.Team
	unit.civ = bootstrap.player_civ if team == 0 else bootstrap.ai_civ
	unit.match_state = state
	unit.sim_pos = position
	unit.name = label
	entities.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _building(id: StringName, team: int, position: Vector2, label: String) -> BuildingAgent:
	var building := BuildingView.instantiate() as BuildingAgent
	building.def = Catalog.get_building(id)
	building.team = team as Enums.Team
	building.civ = bootstrap.player_civ if team == 0 else bootstrap.ai_civ
	building.match_state = state
	building.sim_pos = position
	building.name = label
	building.accepts_all_resources = id == &"town_center"
	entities.add_child(building)
	building.set_physics_process(false)
	return building

func _roundtrip(with_fog := false) -> bool:
	var packet: Dictionary = JSON.parse_string(JSON.stringify(saves.capture(bootstrap)))
	var validation: String = saves.validate(packet)
	check(validation.is_empty(), "edge snapshot passes JSON validation: " + validation)
	if not validation.is_empty(): return false
	_fixture(with_fog)
	var error: String = saves.restore(bootstrap, packet)
	check(error.is_empty(), "edge snapshot restores: " + error)
	for entity in entities.get_children(): entity.set_physics_process(false)
	return error.is_empty()

func _tower_arrow() -> void:
	_fixture()
	var tower := _building(&"watch_tower", 0, Vector2(-5, 5), "Tower")
	var target := _unit(&"villager", 1, Vector2(5, 5), "ArrowTarget")
	var weapon := UnitDef.new()
	weapon.id = tower.def.id
	weapon.attack = int(Catalog.building_record(tower.def.id).attack)
	weapon.is_ranged = true
	var projectile := ProjectileView.instantiate() as ProjectileAgent
	projectile.name = "TowerArrow"
	entities.add_child(projectile)
	projectile.setup(tower.sim_pos, target.sim_pos, weapon, Enums.Team.PLAYER, tower)
	projectile.set_physics_process(false)
	projectile._physics_process(0.2)
	var traveled: float = projectile._traveled
	var old_hp: float = target.hp
	if not _roundtrip(): return
	projectile = entities.get_node("TowerArrow") as ProjectileAgent
	target = entities.get_node("ArrowTarget") as UnitAgent
	check(projectile.attacker == entities.get_node("Tower"), "tower arrow restores the building attacker reference")
	check(projectile.attacker_def.id == &"watch_tower" and projectile.attacker_def.attack == weapon.attack, "tower arrow restores its temporary building weapon")
	check(is_equal_approx(projectile._traveled, traveled), "tower arrow keeps in-flight progress")
	projectile._physics_process(2.0)
	check(target.hp < old_hp, "restored tower arrow applies damage on impact")

func _dead_unit() -> void:
	_fixture()
	var corpse := _unit(&"villager", 0, Vector2(4, 4), "Corpse")
	corpse.take_damage(corpse.hp + 1.0)
	var population: int = state.population[0]
	check(corpse._combat_action == &"die" and corpse.hp == 0.0, "death fixture is saved during its animation")
	if not _roundtrip(): return
	corpse = entities.get_node("Corpse") as UnitAgent
	check(corpse.hp == 0.0 and corpse._combat_action == &"die", "restored dead unit stays dead and keeps its animation")
	check(state.population[0] == population, "death animation does not change saved population prematurely")
	corpse._physics_process(10.0)
	check(corpse.is_queued_for_deletion(), "restored corpse finishes its death animation")
	await process_frame
	check(state.population[0] == population - 1, "finishing restored death releases population exactly once")

func _upgraded_queue() -> void:
	_fixture()
	state.team_ages[0] = Enums.Age.FEUDAL
	_building(&"town_center", 0, Vector2(-12, -8), "TownCenter")
	var barracks := _building(&"barracks", 0, Vector2(7, 4), "Barracks")
	check(barracks.enqueue_train(Catalog.get_unit(&"militia")), "militia enters queue before upgrade")
	check(barracks.enqueue_train(Catalog.get_unit(&"militia")), "second militia enters queue")
	state.technology_progression._complete(0, "man_at_arms")
	var saved_queue_ids: Array[int] = barracks.train_queue_ids.duplicate()
	var payment: Dictionary = barracks._train_payments[saved_queue_ids[1]].duplicate(true)
	barracks.train_progress = 3.5
	if not _roundtrip(): return
	barracks = entities.get_node("Barracks") as BuildingAgent
	check(barracks.train_queue[0].id == &"man_at_arms" and barracks.train_queue_ids == saved_queue_ids, "queued upgrade and cancellation identities survive save")
	var restored_payment: Dictionary = barracks._train_payments[saved_queue_ids[1]]
	var same_cost := int(restored_payment.population) == int(payment.population)
	for type in 4: same_cost = same_cost and int(restored_payment.cost[type]) == int(payment.cost[type])
	check(barracks.train_progress == 3.5 and same_cost, "queue progress and original paid cost survive save")
	var old_food: int = state.resources[0][0]
	var old_reserved: int = state.population_reserved[0]
	check(barracks.cancel_train(saved_queue_ids[1]), "restored upgraded queue can cancel by its stable ID")
	check(state.resources[0][0] == old_food + int(payment.cost[0]) and state.population_reserved[0] == old_reserved - int(payment.population), "cancellation refunds the original payment and reserved population")
	var old_pop: int = state.population[0]
	barracks._physics_process(1000.0)
	check(barracks.train_queue.is_empty() and state.population[0] == old_pop + 1 and state.population_reserved[0] == 0, "restored upgraded production completes and exchanges reserved population")

func _resource_search() -> void:
	_fixture()
	_building(&"town_center", 0, Vector2(-9, 0), "DropOff")
	var tree := ResourceNode.new()
	tree.name = "NextTree"
	tree.resource_type = Enums.ResourceType.WOOD
	tree.amount = 90.0
	tree.sim_pos = Vector2(4, 0)
	entities.add_child(tree)
	var worker := _unit(&"villager", 0, Vector2(1, 0), "SearchingWorker")
	world.get_node("NavService").rebuild_from_scene()
	worker._gather_resource_type = Enums.ResourceType.WOOD
	worker._last_seen_resource_pos = Vector2(2, 0)
	worker.order = Enums.OrderType.GATHER
	worker._finish_or_drop_off()
	check(worker._gather_state == "searching_resource" and worker._path_pending, "gather fixture is saved while its path callback is pending")
	if not _roundtrip(): return
	worker = entities.get_node("SearchingWorker") as UnitAgent
	tree = entities.get_node("NextTree") as ResourceNode
	check(worker._gather_state == "searching_resource" and worker._path_pending, "restored search obtains a new pending navigation request")
	for frame in 200:
		world.get_node("NavService")._process(0.1)
		worker._physics_process(0.1)
		if tree.amount < 90.0: break
	check(tree.amount < 90.0 and worker.order == Enums.OrderType.GATHER, "restored asynchronous gather search resumes real extraction")

func _hidden_history() -> void:
	_fixture(true)
	state.set_team_color_id(1, 5)
	var remembered := _building(&"town_center", 1, Vector2(20, 0), "RememberedBuilding")
	var scout := _unit(&"scout_cavalry", 0, Vector2(20, 8), "Scout")
	scout.vision_radius_override = 12.0
	var holder: Node = world.get_node("FogOfWar")
	holder.rebuild_now()
	var history: Dictionary = state.fog.memories[0].get(remembered.get_instance_id(), {})
	check(not history.is_empty(), "visible opponent creates a fog memory")
	var remembered_target_color := -1
	for part in history.get("parts", []):
		if part.get("material") is ShaderMaterial:
			remembered_target_color = int(part.material.get_shader_parameter("target_player"))
	check(remembered_target_color == 5, "fog fixture remembers a nondefault player-color shader")
	scout.sim_pos = Vector2(-20, 0)
	scout._sync_visual()
	holder.rebuild_now()
	check(not state.fog.can_see(0, remembered), "remembered enemy leaves the player's current visibility")
	remembered.free()
	holder.rebuild_now()
	check(not state.fog.memories[0].is_empty(), "hidden destroyed building retains its last observed memory")
	if not _roundtrip(true): return
	var restored_history: Dictionary = {}
	for memory in state.fog.memories[0].values():
		if memory.minimap_kind == "building": restored_history = memory
	check(not restored_history.is_empty() and restored_history.sim_pos == Vector2(20, 0), "hidden destroyed building's orphan memory survives save")
	var restored_color := -1
	for part in restored_history.get("parts", []):
		if part.get("material") is ShaderMaterial:
			restored_color = int(part.material.get_shader_parameter("target_player"))
	check(restored_color == remembered_target_color, "restored hidden memory keeps the observed player-color material")
	check(state.fog.state_at(0, Vector2(20, 8)) == FogOfWarService.State.EXPLORED, "old explored territory survives while no longer visible")

func _invalid_resume_targets() -> void:
	_fixture()
	var worker := _unit(&"villager", 0, Vector2(4, 4), "Worker")
	var stone := ProjectileView.instantiate() as ProjectileAgent
	stone.name = "SiegeStone"
	entities.add_child(stone)
	stone.setup(worker.sim_pos, Vector2(12, 4), Catalog.get_unit(&"mangonel"), Enums.Team.PLAYER, worker)
	stone.set_physics_process(false)
	var packet: Dictionary = JSON.parse_string(JSON.stringify(saves.capture(bootstrap)))
	check(saves.validate(packet).is_empty(), "valid siege snapshot passes recovery validation")
	var invalid_candidates: Dictionary = packet.duplicate(true)
	invalid_candidates.entities[0].gather_candidates = [0]
	check(not saves.validate(invalid_candidates).is_empty(), "null candidate ID is rejected before recovery indexes its node")
	var invalid_weapon: Dictionary = packet.duplicate(true)
	invalid_weapon.entities[1].presentation.source_def = "unknown_source"
	check(not saves.validate(invalid_weapon).is_empty(), "inconsistent siege source definition is rejected before restoring its visual")

func _run() -> void:
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "local"
	saves = load("res://scripts/core/save_game_service.gd")
	_tower_arrow()
	await _dead_unit()
	_upgraded_queue()
	_resource_search()
	_hidden_history()
	_invalid_resume_targets()
	if is_instance_valid(world): world.free()
	CollisionResolver.clear_map_bounds()
	print("SAVE GAME EDGES: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
