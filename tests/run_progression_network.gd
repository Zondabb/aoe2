extends SceneTree
## Actual host commands and JSON snapshots, with distinct registry/wire IDs.

const Runtime := preload("res://scripts/network/network_match.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Age := preload("res://scripts/systems/age_progression.gd")
const Technology := preload("res://scripts/systems/technology_progression.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
var checks := 0
var failures: Array[String] = []
var fixture: Node2D
var host: Node
var guest: Node
var sequence := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _runtime(authority: bool) -> Node:
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	fixture.add_child(runtime.entities)
	runtime.match_state = MatchState.new()
	runtime.match_state.setup_defaults()
	runtime.match_state.progression_enabled = true
	runtime.match_state.unit_catalog.assign(Catalog.units().values())
	runtime._civs = {0: load("res://data/civs/chinese.tres"), 1: load("res://data/civs/teutons.tres")}
	runtime.match_state.team_civilizations = runtime._civs.duplicate()
	for team in [0, 1]:
		for resource in Enums.ResourceType.values():
			runtime.match_state.resources[team][resource] = 10000
	runtime.is_host = authority
	runtime.local_team = 0 if authority else 1
	runtime._playing = true
	fixture.add_child(runtime)
	var age := Age.new()
	fixture.add_child(age)
	age.setup(runtime.match_state, runtime.entities)
	age.set_process(false)
	var technology := Technology.new()
	fixture.add_child(technology)
	technology.setup(runtime.match_state, runtime.entities)
	technology.set_process(false)
	runtime.set_process(false)
	return runtime

func _building(id: String, team: int) -> BuildingAgent:
	var building := BUILDING.instantiate() as BuildingAgent
	if id == "farm":
		building.set_script(load("res://scripts/entities/farm_agent.gd"))
	building.def = Catalog.get_building(id)
	building.team = team as Enums.Team
	building.civ = host._civs[team]
	building.match_state = host.match_state
	building.sim_pos = Vector2(host.entities.get_child_count() * 5, 10)
	host.entities.add_child(building)
	building.set_physics_process(false)
	return building

func _unit(id: String, team: int) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = Catalog.get_unit(id)
	unit.team = team as Enums.Team
	unit.civ = host._civs[team]
	unit.match_state = host.match_state
	unit.sim_pos = Vector2(10, 20)
	host.entities.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _packet() -> Dictionary:
	return JSON.parse_string(JSON.stringify(host.capture_snapshot()))

func _sync(label: String) -> void:
	sequence += 1
	check(guest.apply_snapshot(_packet(), sequence), label)

func _command(op: String, building: BuildingAgent, team: int, technology := "") -> bool:
	var command := {"op": op, "building_id": host.entity_id(building)}
	if not technology.is_empty():
		command.technology_id = technology
	return host.execute_team_command(command, team)

func _invalid(packet: Dictionary, message: String) -> void:
	var age: int = guest.match_state.age_of(1)
	var food: int = guest.match_state.get_resource(1, Enums.ResourceType.FOOD)
	check(not guest.apply_snapshot(packet, sequence + 1), message)
	check(guest.match_state.age_of(1) == age and guest.match_state.get_resource(1, Enums.ResourceType.FOOD) == food, message + " preserves state")

func _run() -> void:
	Registry.clear()
	fixture = Node2D.new()
	root.add_child(fixture)
	# This consumes a registry ID without consuming any host wire ID.
	var decoy := UNIT.instantiate() as UnitAgent
	decoy.def = Catalog.get_unit(&"villager")
	fixture.add_child(decoy)
	Registry.register(decoy)
	host = _runtime(true)
	guest = _runtime(false)
	guest._civs = host._civs.duplicate()
	var host_tc := _building("town_center", 0)
	var guest_tc := _building("town_center", 1)
	_building("mill", 1)
	_building("lumber_camp", 1)
	var barracks := _building("barracks", 1)
	var farm := _building("farm", 1)
	var militia := _unit("militia", 1)
	militia.hp = militia.def.max_hp * 0.5
	militia.command_move(Vector2(15, 20))
	militia.set_physics_process(false)
	check(host.entity_id(guest_tc) != Registry.id_of(guest_tc), "fixture separates process IDs from wire IDs")
	_sync("initial Dark Age snapshot is JSON serializable")
	var guest_tc_copy: BuildingAgent = guest._resolve(host.entity_id(guest_tc))
	var barracks_copy: BuildingAgent = guest._resolve(host.entity_id(barracks))
	var militia_copy: UnitAgent = guest._resolve(host.entity_id(militia))
	check(guest.match_state.progression_enabled, "snapshot enables progression")
	check(guest.match_state.age_progression.network_replica and guest.match_state.technology_progression.replica, "guest services are replicas")
	check(guest.match_state.age_progression.can_advance(guest_tc_copy), "guest HUD can offer an available age research")
	check(not guest_tc_copy.start_age_upgrade(), "guest service cannot spend or simulate locally")
	check(not _command("research_age", host_tc, 1), "guest cannot research at host town center")
	var food_before: int = host.match_state.get_resource(1, Enums.ResourceType.FOOD)
	check(_command("research_age", guest_tc, 1), "guest wire command starts host-authoritative age research")
	check(not _command("research_age", guest_tc, 1), "duplicate age command is rejected")
	check(host.match_state.get_resource(1, Enums.ResourceType.FOOD) == food_before - 500, "age cost charged once")
	host.match_state.age_progression._process(65.0)
	_sync("partial age research transfers through JSON")
	var progress: Dictionary = guest.match_state.age_progression.progress_for(1)
	check(progress.get("building_id") == host.entity_id(guest_tc) and progress.get("progress") == 0.5, "age HUD progress uses correct wire ID and fraction")
	check(guest_tc_copy.is_age_researching(), "guest town center recognizes its age job")
	guest.match_state.age_progression._process(200.0)
	check(guest.match_state.age_of(1) == 0, "guest does not advance age independently")
	check(_command("cancel_research_age", guest_tc, 1), "guest can cancel own age job")
	_sync("age cancellation transfers")
	check(not guest_tc_copy.is_age_researching() and host.match_state.get_resource(1, Enums.ResourceType.FOOD) == food_before, "age cancellation removes job and refunds resources")
	check(_command("research_age", guest_tc, 1), "age restarts after cancellation")
	host.match_state.age_progression._process(130.0)
	_sync("completed Feudal snapshot applies")
	check(guest.match_state.age_of(1) == 1 and guest.match_state.age_of(0) == 0, "age completion updates only intended team")
	check(is_equal_approx(guest_tc_copy.hp, guest_tc.hp), "age HP changes copy exactly without applying twice")
	check(not _command("research_technology", barracks, 0, "man_at_arms"), "host-side command cannot use enemy research building")
	check(not _command("research_technology", barracks, 1, "elite_chu_ko_nu"), "civilization and research building restrictions remain enforced")
	check(_command("research_technology", barracks, 1, "man_at_arms"), "guest starts infantry upgrade via wire command")
	host.match_state.technology_progression._process(10.0)
	_sync("technology progress serializes without weak references")
	var research: Dictionary = guest.match_state.technology_progression.progress_for(barracks_copy)
	check(research.get("technology_id") == "man_at_arms" and research.get("elapsed") == 10.0, "guest sees correct technology progress")
	check(barracks_copy.is_technology_researching(), "guest production building recognizes research")
	guest.match_state.technology_progression._process(200.0)
	check(militia_copy.def.id == &"militia", "guest does not complete technology independently")
	check(_command("cancel_technology", barracks, 1), "guest can cancel technology")
	_sync("technology cancellation transfers")
	check(not barracks_copy.is_technology_researching(), "guest clears cancelled technology")
	check(_command("research_technology", barracks, 1, "man_at_arms"), "technology restarts")
	host.match_state.technology_progression._process(200.0)
	_sync("existing entity definition upgrade is accepted")
	check(guest._resolve(host.entity_id(militia)) == militia_copy, "upgrade retains network entity identity")
	check(militia_copy.def.id == &"man_at_arms" and is_equal_approx(militia_copy.hp, militia.hp), "upgrade copies target type and health")
	check(militia_copy.order == militia.order, "upgrade preserves synchronized movement order")
	check(guest.match_state.has_technology(1, &"man_at_arms"), "research completion unlocks guest production")
	check(not _command("research_technology", barracks, 1, "man_at_arms"), "completed technology cannot be charged twice")
	# A guest can skip snapshots during an upgrade chain and still accept the final tier.
	host.match_state.set_age(1, 2)
	host.match_state.technology_progression._complete(1, "long_swordsman")
	host.match_state.set_age(1, 3)
	host.match_state.technology_progression._complete(1, "two_handed_swordsman")
	host.match_state.technology_progression._complete(1, "champion")
	_sync("multiple skipped upgrade tiers can be reconciled")
	check(militia_copy.def.id == &"champion" and guest.match_state.age_of(1) == 3, "guest reaches latest infantry and age")
	var watch_tower := _building("watch_tower", 1)
	watch_tower.hp *= 0.5
	_sync("new tower enters snapshot")
	host.match_state.technology_progression._complete(1, "guard_tower")
	_sync("tower definition upgrade applies to existing replica")
	var tower_copy: BuildingAgent = guest._resolve(host.entity_id(watch_tower))
	check(tower_copy.def.id == &"guard_tower" and is_equal_approx(tower_copy.hp, watch_tower.hp), "tower upgrade preserves health and identity")
	check(tower_copy.pierce_armor == float(tower_copy._age_attributes().get("pierce_armor", tower_copy.def.pierce_armor)), "replica tower refreshes armor after upgrade")
	farm.amount = 12.5
	_sync("partially exhausted farm transfers")
	var farm_copy: BuildingAgent = guest._resolve(host.entity_id(farm))
	check(farm_copy.has_method("extract") and farm_copy.amount == 12.5, "replica farm preserves class and remaining food")
	check(guest.match_state.get_resource(1, Enums.ResourceType.STONE) == host.match_state.get_resource(1, Enums.ResourceType.STONE), "stone economy synchronizes")
	var tree := ResourceNode.new()
	tree.resource_type = Enums.ResourceType.WOOD
	tree.sim_pos = Vector2(-20,-20)
	tree.block_size_override = Vector2(4,4)
	host.entities.add_child(tree)
	_sync("generated forest collision size transfers through JSON")
	var tree_copy: ResourceNode = guest._resolve(host.entity_id(tree))
	check(tree_copy.pathfinding_size() == Vector2(4,4) and tree_copy.block_half == Vector2(2,2), "guest forest uses the same occupied tile as host")
	var packet := _packet()
	var invalid := packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(tree): record.block_size = [4,NAN]
	_invalid(invalid, "nonfinite forest collision size rejected atomically")
	invalid = packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(tree): record.block_size = [-1,4]
	_invalid(invalid, "negative forest collision size rejected atomically")
	invalid = packet.duplicate(true)
	invalid.progression.ages[1] = 3.5
	_invalid(invalid, "fractional age rejected")
	invalid = packet.duplicate(true)
	invalid.progression.technologies[1]["invented_technology"] = true
	_invalid(invalid, "unknown technology rejected")
	invalid = packet.duplicate(true)
	invalid.progression.technology_research = [{"building_id": host.entity_id(barracks), "team": 1, "technology_id": "man_at_arms", "elapsed": 2.0, "duration": 1.0, "progress": 2.0}]
	_invalid(invalid, "overflow research progress rejected")
	invalid = packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(farm): record.farm_food = -1.0
	_invalid(invalid, "negative remaining farm food rejected")
	invalid = packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(farm): record.farm_food = NAN
	_invalid(invalid, "nonfinite farm food rejected")
	invalid = packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(militia): record.def = "archer"
	_invalid(invalid, "unrelated entity definition switch rejected")
	invalid = packet.duplicate(true)
	for record in invalid.entities:
		if record.id == host.entity_id(militia): record.def = "militia"
	_invalid(invalid, "unit tier downgrade rejected")
	check(not guest.apply_snapshot(packet, sequence), "stale snapshot cannot roll back progression")
	fixture.free()
	Registry.clear()
	print("PROGRESSION NETWORK: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
