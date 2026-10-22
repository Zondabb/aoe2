extends SceneTree
## Real actors and navigation: siege can reach fortifications and damage them.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Units := preload("res://scenes/entities/unit_view.tscn")
const Buildings := preload("res://scenes/entities/building_view.tscn")
const NavHolder := preload("res://scripts/systems/nav_service_holder.gd")
const Director := preload("res://scripts/systems/auto_combat_director.gd")
const Combat := preload("res://scripts/systems/combat_system.gd")
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const DecisionContext := preload("res://scripts/ai_gateway/decision_context_builder.gd")
const STEP := 1.0 / 30.0

var checks := 0
var failures: Array[String] = []
var fixture: Node2D


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func _reset() -> void:
	if is_instance_valid(fixture): fixture.free()
	fixture = Node2D.new()
	root.add_child(fixture)
	CollisionResolver.clear_map_bounds()


func _unit(id: StringName, at: Vector2, team := Enums.Team.PLAYER) -> UnitAgent:
	var actor := Units.instantiate() as UnitAgent
	actor.def = Catalog.get_unit(id)
	actor.sim_pos = at
	actor.team = team
	fixture.add_child(actor)
	actor.set_physics_process(false)
	return actor


func _building(id: StringName, at: Vector2, orientation := 0) -> BuildingAgent:
	var actor := Buildings.instantiate() as BuildingAgent
	actor.def = Catalog.get_building(id)
	actor.sim_pos = at
	actor.team = Enums.Team.AI
	actor.wall_orientation = orientation
	actor.gate_state = "locked"
	fixture.add_child(actor)
	actor.set_physics_process(false)
	actor.set_process(false)
	return actor


func _test_role_targets() -> void:
	_reset()
	var ram := _unit(&"battering_ram", Vector2(-10, 0))
	var soldier := _unit(&"swordsman", Vector2(-10, 3))
	var scorpion := _unit(&"scorpion", Vector2(-10, -3))
	var villager := _unit(&"villager", Vector2(-8, 0), Enums.Team.AI)
	var wall := _building(&"stone_wall", Vector2.ZERO)
	var auto := Director.new()
	auto.setup(fixture)
	auto.set_team_auto_attack(Enums.Team.PLAYER, true)
	check(auto.pick_target_for_unit(ram) == wall, "idle ram acquires a fortification instead of a nearby villager")
	check(auto.pick_target_for_unit(soldier) == villager, "soldiers prioritize enemy units over structures")
	check(auto.pick_target_for_unit(scorpion) == villager, "scorpions preserve their anti-unit role")
	ram.command_attack(villager)
	auto.tick(1.0)
	check(ram._attack_target == villager, "automatic targeting preserves an explicit attack order")
	ram.command_move(Vector2(-20, 0))
	auto.tick(1.0)
	check(ram.order == Enums.OrderType.MOVE, "automatic targeting preserves a move order")
	wall.free()
	check(auto.pick_target_for_unit(ram) == null, "idle rams do not chase workers when no visible structures remain")
	var existing: Array = load("res://tests/test_auto_combat_director.gd").new().run()
	check(existing.is_empty(), "existing automatic target selection regressions: %s" % [existing])


func _test_automatic_friendly_fire() -> void:
	_reset()
	var siege := _unit(&"mangonel", Vector2(-20, 0))
	var town := _building(&"town_center", Vector2.ZERO)
	var escort := _unit(&"swordsman", Vector2(-3, 0))
	var auto := Director.new()
	auto.setup(fixture)
	check(auto.pick_target_for_unit(siege) == null, "automatic artillery holds fire while a melee escort is in its blast")
	escort.sim_pos = Vector2(-10, 8)
	check(auto.pick_target_for_unit(siege) == town, "automatic artillery acquires its objective once the escort clears the blast")
	var ally := _building(&"barracks", Vector2(-5, 0))
	ally.team = Enums.Team.PLAYER
	check(auto.pick_target_for_unit(siege) == null, "automatic artillery also protects nearby friendly building footprints")
	var ram := _unit(&"battering_ram", Vector2(-12, 0))
	check(auto.pick_target_for_unit(ram) == town, "friendly blast protection never blocks a melee ram")


func _test_damage_and_observation() -> void:
	_reset()
	var ram := _unit(&"battering_ram", Vector2(-10, 0))
	var wall := _building(&"stone_wall", Vector2.ZERO)
	var town := _building(&"town_center", Vector2(12, 0))
	var wall_damage := Combat.apply_hit(ram.def, wall)
	var town_damage := Combat.apply_hit(ram.def, town)
	check(wall_damage >= 100, "ram applies original building-class damage against stone walls")
	check(town_damage >= 100, "ram applies original building-class damage against town centers")
	var sword_damage := Combat.apply_hit(Catalog.get_unit(&"swordsman"), town)
	check(town_damage > sword_damage * 10, "siege already demolishes a town center substantially faster per hit than soldiers")
	var gate := _building(&"gate", Vector2(0, 12), 2)
	var gate_snapshot := Observation.serialize_entity(gate, 42)
	check(gate_snapshot.footprint == [1.0, 4.0] and gate_snapshot.blocks_movement, "AI sees the actual rotated gate footprint and its movement obstruction")
	var ram_snapshot := Observation.serialize_entity(ram, 43)
	check(ram_snapshot.combat.attack_class_bonuses.get("BUILDINGS_NO_PORT", 0) == 125, "AI can observe the ram's real building damage bonus")
	check(ram_snapshot.combat.projectile_splash_radius == 0.0 and not ram_snapshot.combat.projectile_friendly_fire, "melee ram observations do not imply projectile friendly fire")
	var state := MatchState.new()
	state.setup_defaults()
	var catalog := DecisionContext._catalog(state, fixture, Enums.Team.PLAYER, null)
	for name in [&"mangonel", &"onager", &"siege_onager", &"trebuchet", &"archer"]:
		var actor := _unit(name, Vector2(-15, 15))
		var observed := Observation.serialize_entity(actor, 44)
		check(observed.combat.projectile_splash_radius == actor.def.projectile_splash_radius and observed.combat.projectile_friendly_fire == actor.def.projectile_friendly_fire,
			"%s snapshot exposes the real blast radius and friendly-fire rule" % name)
		var record: Dictionary = catalog.units.filter(func(item): return item.id == String(name))[0]
		check(record.projectile_splash_radius == observed.combat.projectile_splash_radius and record.projectile_friendly_fire == observed.combat.projectile_friendly_fire,
			"%s catalog agrees with actual observed projectile damage rules" % name)


func _test_gate_geometry_and_navigation() -> void:
	for orientation in [0, 2]:
		_reset()
		var nav := NavHolder.new()
		nav.setup(-32, 32)
		fixture.add_child(nav)
		nav.set_process(false)
		var gate := _building(&"gate", Vector2.ZERO, orientation)
		var ram := _unit(&"battering_ram", Vector2(0, -12))
		nav.rebuild_from_scene()
		var half := gate.get_placement_footprint() * 0.5
		check(is_equal_approx(ram._distance_to(gate), 12.0 - half.y), "gate orientation %d uses its real footprint for attack range" % orientation)
		var edge := ProjectileAgent.aim_point_for_target(ram.sim_pos, gate)
		check(edge.is_equal_approx(Vector2(0, -half.y)), "gate orientation %d projectile aim lands on the visible edge" % orientation)
		var approach := ram._attack_approach_point(gate)
		check(approach.y < -half.y - ram.def.resolved_footprint_radius(), "gate orientation %d melee approach stays outside the solid footprint" % orientation)
		var probe := ProjectileAgent.new()
		probe.sim_pos = edge
		check(probe._distance_to_entity(gate) == 0.0, "gate orientation %d projectile impact hits the physical edge" % orientation)
		probe.free()
		var hp_before := gate.hp
		ram.command_attack(gate)
		for step in 900:
			nav._process(STEP)
			ram._physics_process(STEP)
			if gate.hp < hp_before: break
		check(gate.hp < hp_before, "ram navigates to and hits orientation %d gate within 30 simulation seconds" % orientation)
		check(CollisionResolver.static_step_safe(ram.sim_pos, ram.sim_pos, ram.def.resolved_footprint_radius(), [gate]), "ram hits orientation %d gate without entering its solid body" % orientation)


func _run() -> void:
	_test_role_targets()
	_test_automatic_friendly_fire()
	_test_damage_and_observation()
	_test_gate_geometry_and_navigation()
	if is_instance_valid(fixture): fixture.free()
	await process_frame
	print("Siege AI mechanics: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
