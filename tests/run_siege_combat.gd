extends SceneTree
## Real unit/projectile scenes, fixed simulation steps and JSON visual replication.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE := preload("res://scenes/entities/projectile_view.tscn")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Collision := preload("res://scripts/systems/collision_resolver.gd")
const Runtime := preload("res://scripts/network/network_match.gd")
const STEP := 1.0 / 60.0

var checks := 0
var failures: Array[String] = []
var fixture: Node2D


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
	fixture = Node2D.new()
	root.add_child(fixture)
	Collision.clear_map_bounds()


func _unit(id: StringName, side: Enums.Team, at: Vector2) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = Catalog.get_unit(id)
	unit.team = side
	unit.sim_pos = at
	fixture.add_child(unit)
	unit.set_physics_process(false)
	return unit


func _victim(side: Enums.Team, at: Vector2) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	var definition := UnitDef.new()
	definition.id = &"swordsman"
	definition.max_hp = 1000
	definition.attack = 0
	definition.melee_armor = 3
	definition.pierce_armor = 17
	definition.move_speed = 4
	unit.def = definition
	unit.team = side
	unit.sim_pos = at
	fixture.add_child(unit)
	unit.set_physics_process(false)
	return unit


func _shots() -> Array[ProjectileAgent]:
	var result: Array[ProjectileAgent] = []
	for node in fixture.get_children():
		if node is ProjectileAgent and not node.is_queued_for_deletion():
			result.append(node)
	return result


func _shoot(definition: UnitDef, origin: Vector2, aim: Vector2, source: UnitAgent = null) -> ProjectileAgent:
	var shot := PROJECTILE.instantiate() as ProjectileAgent
	fixture.add_child(shot)
	shot.setup(origin, aim, definition, Enums.Team.PLAYER, source)
	shot.set_physics_process(false)
	return shot


func _step_unit(unit: UnitAgent, duration: float) -> void:
	for frame in ceili(duration / STEP):
		unit._physics_process(STEP)


func _step_shot(shot: ProjectileAgent, duration: float) -> void:
	for frame in ceili(duration / STEP):
		if not is_instance_valid(shot) or shot.is_queued_for_deletion():
			break
		shot._physics_process(STEP)


func _test_original_definitions() -> void:
	var ids := [&"mangonel", &"onager", &"siege_onager"]
	var ranges := [28.0, 32.0, 32.0]
	var radii := [4.0, 5.0, 6.0]
	for index in ids.size():
		var definition: UnitDef = Catalog.get_unit(ids[index])
		check(definition != null, "%s exists in the playable catalog" % ids[index])
		if definition == null:
			continue
		check(definition.is_ranged and is_equal_approx(definition.attack_range, ranges[index]), "%s uses original range at four simulation units per tile" % ids[index])
		check(definition.get("minimum_attack_range") == 12.0, "%s preserves the three-tile blind spot" % ids[index])
		check(definition.get("projectile_kind") == &"stone", "%s fires a stone" % ids[index])
		check(definition.get("projectile_speed") == 14.0, "%s uses original stone flight speed" % ids[index])
		check(definition.get("projectile_splash_radius") == radii[index], "%s has its original blast radius" % ids[index])
		check(definition.get("projectile_friendly_fire") == true, "%s blast can damage friendly units" % ids[index])
		check(definition.get("attack_uses_melee_armor") == true, "%s damage is reduced by melee armor" % ids[index])
		check(is_equal_approx(float(definition.get("attack_release_delay")), 0.0), "%s preserves the original zero-frame projectile release delay" % ids[index])


func _test_range_and_retreat() -> void:
	_new_fixture()
	var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
	var target := _victim(Enums.Team.AI, Vector2(-8.01, 0))
	check(not siege._in_attack_range(target), "a target inside minimum range cannot be hit")
	target.sim_pos = Vector2(-8, 0)
	check(siege._in_attack_range(target), "minimum range boundary can be hit")
	target.sim_pos = Vector2(8, 0)
	check(siege._in_attack_range(target), "maximum range boundary can be hit")
	target.sim_pos = Vector2(8.01, 0)
	check(not siege._in_attack_range(target), "target beyond maximum range cannot be hit")
	target.sim_pos = Vector2(-16, 0)
	siege.command_attack(target)
	_step_unit(siege, 0.4)
	check(siege.sim_pos.x < -20.1, "attack order retreats from a target in the blind spot")
	check(_shots().is_empty() and target.hp == 1000, "retreating siege causes no point-blank damage")
	for frame in 1200:
		siege._physics_process(STEP)
		if not _shots().is_empty():
			break
	check(not _shots().is_empty(), "retreat finishes with an actual ranged launch")
	check(siege.sim_pos.distance_to(target.sim_pos) >= 12.0, "launch happens outside the blind spot")
	check(siege.sim_pos.distance_to(target.sim_pos) <= siege.def.attack_range, "retreat does not overshoot usable firing range")


func _test_real_launch_and_impact() -> void:
	_new_fixture()
	var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
	var target := _victim(Enums.Team.AI, Vector2.ZERO)
	siege.command_attack(target)
	check(_shots().is_empty() and target.hp == 1000, "attack command itself causes no direct damage")
	_step_unit(siege, STEP)
	var shots := _shots()
	check(shots.size() == 1, "original zero-frame release launches one stone on the first attack tick")
	check(target.hp == 1000, "launch itself applies no direct damage")
	check(siege.sim_pos.is_equal_approx(Vector2(-20, 0)), "siege fires at distance instead of walking into melee")
	_step_unit(siege, 2.0)
	check(_shots().size() == 1, "the attack animation cannot emit additional stones during its reload")
	if shots.is_empty():
		return
	var shot := shots[0]
	var sprite := shot.get_node("Sprite") as Sprite2D
	check(sprite.visible and sprite.texture != null, "stone has a visible textured sprite")
	var origin := shot.sim_pos
	_step_shot(shot, 0.3)
	check(is_equal_approx(origin.distance_to(shot.sim_pos), 14.0 * 0.3), "stone moves at its definition's projectile speed")
	check(shot.position.y < Iso.world_to_screen(shot.sim_pos).y - 2.0, "stone visibly rises above the ground along an arc")
	check(target.hp == 1000, "target remains unharmed while stone is in flight")
	_step_shot(shot, 3.0)
	check(target.hp == 1000.0 - float(siege.def.attack - 3), "landing applies exactly one center hit using melee armor")
	check(shot.is_queued_for_deletion(), "stone is consumed on impact")


func _test_splash_and_miss() -> void:
	_new_fixture()
	var definition: UnitDef = Catalog.get_unit(&"mangonel")
	var center := _victim(Enums.Team.AI, Vector2.ZERO)
	var nearby := _victim(Enums.Team.AI, Vector2(0, 2))
	var friendly := _victim(Enums.Team.PLAYER, Vector2(0, -2))
	var outside := _victim(Enums.Team.AI, Vector2(0, 7))
	var shot := _shoot(definition, Vector2(-20, 0), Vector2.ZERO)
	_step_shot(shot, 3.0)
	check(center.hp < 1000 and nearby.hp < 1000, "impact damages multiple enemies within the blast")
	check(friendly.hp < 1000, "stone blast damages a friendly unit inside the radius")
	check(friendly.order == Enums.OrderType.NONE, "friendly blast does not generate an invalid friendly attack order")
	check(outside.hp == 1000, "stone does not damage units outside its blast")
	_new_fixture()
	var runner := _victim(Enums.Team.AI, Vector2.ZERO)
	shot = _shoot(definition, Vector2(-20, 0), Vector2.ZERO)
	_step_shot(shot, 0.3)
	runner.sim_pos = Vector2(0, 8)
	_step_shot(shot, 3.0)
	check(shot.aim_pos == Vector2.ZERO, "stone preserves its aim point after its target moves")
	check(runner.hp == 1000, "a target can dodge a non-homing stone")
	_new_fixture()
	var building := BUILDING.instantiate() as BuildingAgent
	building.def = Catalog.get_building(&"barracks")
	building.team = Enums.Team.AI
	# The outer wall is inside the splash even when the building center is not.
	building.sim_pos = Vector2(4.0 + building.def.footprint.x * 0.5 - 0.5, 0)
	fixture.add_child(building)
	building.set_physics_process(false)
	var building_hp := building.hp
	shot = _shoot(definition, Vector2(-20, 0), Vector2.ZERO)
	_step_shot(shot, 3.0)
	check(building.hp < building_hp, "stone splash measures distance to a building's footprint")


func _test_freed_attacker() -> void:
	_new_fixture()
	var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
	var target := _victim(Enums.Team.AI, Vector2.ZERO)
	var shot := _shoot(siege.def, siege.sim_pos, target.sim_pos, siege)
	siege.free()
	_step_shot(shot, 3.0)
	check(target.hp < 1000, "in-flight stone still resolves safely after attacker is freed")
	check(shot.is_queued_for_deletion(), "freed-attacker impact still consumes its projectile")


func _test_order_interruptions() -> void:
	for command in ["stop", "move"]:
		_new_fixture()
		var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
		var target := _victim(Enums.Team.AI, Vector2.ZERO)
		siege.command_attack(target)
		_step_unit(siege, STEP)
		var shots_before := _shots().size()
		check(siege._combat_action == &"attack", "%s fixture interrupts an active attack animation" % command)
		if command == "stop":
			siege.command_stop()
		else:
			siege.command_move(Vector2(-25, 5))
		check(siege._combat_action == &"", "%s clears the attack animation state immediately" % command)
		_step_unit(siege, 1.0)
		check(_shots().size() == shots_before and target.hp == 1000, "%s leaves no additional ghost launch or direct damage" % command)
	_new_fixture()
	var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
	var target := _victim(Enums.Team.AI, Vector2.ZERO)
	siege.command_attack(target)
	target.free()
	_step_unit(siege, 1.0)
	check(siege.order == Enums.OrderType.NONE and _shots().is_empty(), "freed target cancels the attack windup safely")


func _test_other_weapons() -> void:
	_new_fixture()
	var ram := _unit(&"battering_ram", Enums.Team.PLAYER, Vector2(-1, 0))
	var target := _victim(Enums.Team.AI, Vector2.ZERO)
	check(not ram.def.is_ranged, "battering ram remains a melee siege weapon")
	ram.command_attack(target)
	_step_unit(ram, 3.0)
	check(target.hp < 1000, "ram still causes contact damage")
	check(_shots().is_empty(), "ram never launches a stone")
	_new_fixture()
	var archer_def: UnitDef = load("res://data/units/archer.tres")
	var enemy := _victim(Enums.Team.AI, Vector2.ZERO)
	var friendly := _victim(Enums.Team.PLAYER, Vector2(0, 0.2))
	var outside := _victim(Enums.Team.AI, Vector2(0, 2))
	var arrow := _shoot(archer_def, Vector2(-4, 0), Vector2.ZERO)
	_step_shot(arrow, 1.0)
	check(enemy.hp < 1000, "existing authored archer still hits the aimed enemy")
	check(friendly.hp == 1000, "arrow preserves its no-friendly-fire rule")
	check(outside.hp == 1000, "arrow retains its small impact radius")
	_new_fixture()
	var trebuchet := _unit(&"trebuchet", Enums.Team.PLAYER, Vector2(-40, 0))
	var distant := _victim(Enums.Team.AI, Vector2.ZERO)
	check(trebuchet.def.attack_range == 64.0 and trebuchet.def.minimum_attack_range == 16.0, "trebuchet preserves original sixteen/four-tile ranges")
	check(is_equal_approx(trebuchet._combat_anim_duration(&"attack"), 2.2), "trebuchet attack uses the original 22-frame timing")
	trebuchet.command_attack(distant)
	_step_unit(trebuchet, 0.4)
	check(_shots().is_empty(), "trebuchet respects its original release delay")
	_step_unit(trebuchet, 0.3)
	check(_shots().size() == 1, "trebuchet launches after its original 0.6-second delay")
	if not _shots().is_empty():
		var stone := _shots()[0]
		_step_shot(stone, 4.0)
		check(distant.hp < 1000, "trebuchet stone lands with damage")
		check(stone.is_queued_for_deletion(), "trebuchet impact animation finishes and releases the projectile")


func _test_ranged_chase_boundary() -> void:
	_new_fixture()
	var archer := _unit(&"archer", Enums.Team.PLAYER, Vector2.ZERO)
	var target := _victim(Enums.Team.AI, Vector2(archer.def.attack_range + 0.1, 0))
	archer.command_attack(target)
	for frame in 300:
		archer._physics_process(STEP)
		if not _shots().is_empty():
			break
	check(archer.sim_pos.x > 0.0, "archer chases a stationary target just beyond actual firing range")
	check(not _shots().is_empty(), "archer does not loop empty attacks inside the former chase slack")
	check(archer._in_attack_range(target), "archer reaches usable firing range before releasing its arrow")


func _test_death_cannot_be_interrupted() -> void:
	for command in ["stop", "move", "attack"]:
		_new_fixture()
		var siege := _unit(&"mangonel", Enums.Team.PLAYER, Vector2(-20, 0))
		var target := _victim(Enums.Team.AI, Vector2.ZERO)
		siege.take_damage(10000.0)
		check(siege.hp == 0.0 and siege._combat_action == &"die", "%s fixture starts the death animation" % command)
		match command:
			"stop": siege.command_stop()
			"move": siege.command_move(Vector2(-30, 0))
			"attack": siege.command_attack(target)
		check(siege._combat_action == &"die" and siege.order == Enums.OrderType.NONE, "%s cannot cancel death or assign an order to a dead unit" % command)
		for frame in 600:
			siege._physics_process(STEP)
			if siege.is_queued_for_deletion():
				break
		check(siege.is_queued_for_deletion(), "%s still allows the corpse to finish and be released" % command)
		check(siege.sim_pos == Vector2(-20, 0) and _shots().is_empty(), "%s cannot make a dead unit walk or fire" % command)


func _test_projectile_replication() -> void:
	_new_fixture()
	var target := _victim(Enums.Team.AI, Vector2.ZERO)
	var shot := _shoot(Catalog.get_unit(&"mangonel"), Vector2(-20, 0), Vector2.ZERO)
	_step_shot(shot, 0.4)
	var presentation: Dictionary = JSON.parse_string(JSON.stringify(shot.network_presentation()))
	var replica := PROJECTILE.instantiate() as ProjectileAgent
	replica.set_meta("network_replica", true)
	fixture.add_child(replica)
	replica.call("_configure_visual")
	replica.apply_network_presentation(presentation)
	check(replica.network_presentation().get("projectile_kind") == "stone", "JSON replica retains the stone weapon type")
	check(replica.position.is_equal_approx(shot.position), "JSON replica keeps stone trajectory and arc position")
	var source_sprite := shot.get_node("Sprite") as Sprite2D
	var copy_sprite := replica.get_node("Sprite") as Sprite2D
	check(copy_sprite.visible and copy_sprite.texture != null, "JSON replica renders a visible projectile")
	check(copy_sprite.texture.get_size().is_equal_approx(source_sprite.texture.get_size()), "JSON replica preserves stone art rather than falling back to an arrow")
	var before := replica.position
	replica._physics_process(10.0)
	check(replica.position == before and not replica.is_queued_for_deletion(), "network replica cannot simulate local projectile impact")
	var runtime := Runtime.new()
	var record := {"id": 1, "kind": "projectile", "team": 0, "pos": [shot.sim_pos.x, shot.sim_pos.y], "presentation": presentation}
	check(runtime._valid_record(record), "network accepts the serialized stone presentation")
	for invalid in [
		{"projectile_kind": "unknown"}, {"source_def": "archer"}, {"source_def": "missing_unit"},
		{"launch_height": -1.0}, {"launch_height": INF}, {"impact_elapsed": -0.1},
		{"impact_elapsed": NAN}, {"impact": "true"}, {"traveled": -0.1},
	]:
		var malformed := record.duplicate(true)
		malformed.presentation.merge(invalid, true)
		check(not runtime._valid_record(malformed), "network rejects malformed stone presentation: %s" % str(invalid))
	_step_shot(shot, 1.1)
	presentation = JSON.parse_string(JSON.stringify(shot.network_presentation()))
	check(presentation.impact and not shot.is_queued_for_deletion(), "impact fixture captures the stone's visible landing animation")
	replica.apply_network_presentation(presentation)
	check(replica.position.is_equal_approx(shot.position), "landing replica is anchored at the host's impact point")
	check(replica.network_presentation().impact and is_equal_approx(replica.network_presentation().impact_elapsed, presentation.impact_elapsed), "JSON replica preserves impact phase and elapsed animation time")
	var host_texture := source_sprite.texture as AtlasTexture
	var replica_texture := copy_sprite.texture as AtlasTexture
	check(host_texture != null and replica_texture != null and host_texture.atlas == replica_texture.atlas and host_texture.region == replica_texture.region, "landing replica uses the exact host impact sheet and frame")
	var impact_hp := target.hp
	replica._physics_process(10.0)
	check(target.hp == impact_hp and not replica.is_queued_for_deletion(), "replicated landing animation cannot apply damage twice or expire locally")
	runtime.free()


func _run() -> void:
	_test_original_definitions()
	_test_range_and_retreat()
	_test_real_launch_and_impact()
	_test_splash_and_miss()
	_test_freed_attacker()
	_test_order_interruptions()
	_test_other_weapons()
	_test_ranged_chase_boundary()
	_test_death_cannot_be_interrupted()
	_test_projectile_replication()
	if is_instance_valid(fixture):
		fixture.free()
	await process_frame
	print("Siege combat: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
