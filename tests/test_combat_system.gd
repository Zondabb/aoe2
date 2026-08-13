extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")
const TOWN_CENTER: BuildingDef = preload("res://data/buildings/town_center.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SelectionController2DScript := preload("res://scripts/input/selection_controller_2d.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_attack_order_chases_and_hits(failures)
	_test_selection_issues_attack_order(failures)
	_test_attack_cooldown_and_unit_death(failures)
	_test_civ_combat_bonuses(failures)
	_test_town_center_death_sets_winner(failures)
	_test_building_armor_applies(failures)
	_test_idle_unit_retaliates(failures)
	_test_busy_unit_does_not_retaliate(failures)
	_test_ranged_attack_range_from_def(failures)
	return failures

func _test_attack_order_chases_and_hits(failures: Array[String]) -> void:
	var root := _make_root()
	var attacker := _spawn_unit(root, SWORDSMAN, Enums.Team.PLAYER, Vector2.ZERO)
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(4.0, 0.0))
	var initial_hp: float = target.hp
	attacker.call("command_attack", target)
	attacker._physics_process(0.5)
	if attacker.order != Enums.OrderType.ATTACK:
		failures.append("attack command should remain active while chasing")
	if attacker.sim_pos.x <= 0.0:
		failures.append("melee attacker should chase an out-of-range target")
	attacker.sim_pos = Vector2(3.5, 0.0)
	IsoMathScript.sync_node(attacker, attacker.sim_pos)
	_advance_combat(attacker, 1.0)
	if target.hp != initial_hp - 7:
		failures.append("melee attack should apply target melee armor")
	root.free()

func _test_selection_issues_attack_order(failures: Array[String]) -> void:
	var root := _make_root()
	var attacker := _spawn_unit(root, SWORDSMAN, Enums.Team.PLAYER, Vector2.ZERO)
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2.ONE)
	var selection := SelectionController2DScript.new()
	root.add_child(selection)
	selection.call("_add_selection", attacker)
	selection.call("_issue_attack", target)
	if attacker.order != Enums.OrderType.ATTACK:
		failures.append("right-clicking an enemy should issue an attack order")
	root.free()

func _test_attack_cooldown_and_unit_death(failures: Array[String]) -> void:
	var root := _make_root()
	var attacker := _spawn_unit(root, ARCHER, Enums.Team.PLAYER, Vector2.ZERO)
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(1.0, 0.0))
	attacker.command_attack(target)
	_advance_combat(attacker, 0.8)
	var hp_after_first_hit: float = target.hp
	_advance_combat(attacker, ARCHER.attack_cooldown * 0.4)
	if target.hp != hp_after_first_hit:
		failures.append("attacker should wait for its cooldown before hitting again")
	_advance_combat(attacker, ARCHER.attack_cooldown + 1.0)
	if target.hp >= hp_after_first_hit:
		failures.append("attacker should hit again when its cooldown elapses")
	target.call("take_damage", 999.0)
	_advance_combat(target, 2.0)
	if not target.is_queued_for_deletion():
		failures.append("unit should queue itself for removal at zero HP")
	root.free()

func _test_civ_combat_bonuses(failures: Array[String]) -> void:
	var root := _make_root()
	var knight := _spawn_unit(
		root, SWORDSMAN, Enums.Team.PLAYER, Vector2.ZERO, TEUTONS
	)
	if knight.get("melee_armor") != SWORDSMAN.melee_armor + TEUTONS.melee_armor_bonus:
		failures.append("Teuton melee units should receive the melee armor bonus")
	var archer := _spawn_unit(
		root, ARCHER, Enums.Team.PLAYER, Vector2(2.0, 0.0), TEUTONS
	)
	if archer.get("melee_armor") != ARCHER.melee_armor:
		failures.append("Teuton ranged units should not receive the melee armor bonus")
	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("def", TOWN_CENTER)
	town_center.set("civ", TEUTONS)
	town_center.set("sim_pos", Vector2.ZERO)
	root.add_child(town_center)
	town_center.call("_ready")
	if town_center.get("hp") != int(TOWN_CENTER.max_hp * TEUTONS.building_hp_mul):
		failures.append("Teuton buildings should receive the civilization HP multiplier")
	root.free()

func _test_town_center_death_sets_winner(failures: Array[String]) -> void:
	var root := _make_root()
	var state := MatchState.new()
	state.setup_defaults()
	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.set("team", Enums.Team.PLAYER)
	town_center.set("def", TOWN_CENTER)
	town_center.set("match_state", state)
	town_center.set("sim_pos", Vector2.ZERO)
	root.add_child(town_center)
	town_center.call("_ready")
	var destroyed_events: Array[bool] = []
	town_center.connect(
		"destroyed",
		func(_building: Node2D) -> void: destroyed_events.append(true)
	)
	town_center.call("take_damage", float(town_center.get("hp")))
	if not town_center.is_queued_for_deletion():
		failures.append("destroyed town center should queue itself for removal")
	if destroyed_events.size() != 1:
		failures.append("destroyed building should emit its destroyed signal once")
	if state.get("winner") != Enums.Team.AI:
		failures.append("destroying the player town center should make AI the winner")
	root.free()

func _test_building_armor_applies(failures: Array[String]) -> void:
	var root := _make_root()
	var barracks := BUILDING_VIEW.instantiate() as Node2D
	barracks.set("team", Enums.Team.AI)
	barracks.set("def", BARRACKS)
	barracks.set("sim_pos", Vector2(2.0, 0.0))
	root.add_child(barracks)
	barracks.call("_ready")
	if barracks.get("melee_armor") != BARRACKS.melee_armor:
		failures.append("buildings should load melee armor from BuildingDef")
	if barracks.get("pierce_armor") != BARRACKS.pierce_armor:
		failures.append("buildings should load pierce armor from BuildingDef")
	var initial_hp: float = barracks.get("hp")
	var dealt := CombatSystemScript.apply_hit(ARCHER, barracks)
	# Archer atk 5 − pierce 4 = 1
	if not is_equal_approx(dealt, 1.0):
		failures.append("ranged hits on barracks should use pierce armor (got %s)" % dealt)
	if not is_equal_approx(float(barracks.get("hp")), initial_hp - 1.0):
		failures.append("building HP should drop by armored pierce damage")
	var after_pierce: float = barracks.get("hp")
	dealt = CombatSystemScript.apply_hit(SWORDSMAN, barracks)
	# Swordsman atk 8 − melee 2 = 6
	if not is_equal_approx(dealt, 6.0):
		failures.append("melee hits on barracks should use melee armor (got %s)" % dealt)
	if not is_equal_approx(float(barracks.get("hp")), after_pierce - 6.0):
		failures.append("building HP should drop by armored melee damage")
	root.free()

func _test_idle_unit_retaliates(failures: Array[String]) -> void:
	var root := _make_root()
	var attacker := _spawn_unit(root, SWORDSMAN, Enums.Team.PLAYER, Vector2.ZERO)
	var idle := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(1.0, 0.0))
	CombatSystemScript.apply_hit(SWORDSMAN, idle, {"attacker": attacker})
	if idle.order != Enums.OrderType.ATTACK:
		failures.append("idle unit should retaliate when damaged by an attacker")
	if idle._attack_target != attacker:
		failures.append("retaliation should target the damaging attacker")
	root.free()

func _test_busy_unit_does_not_retaliate(failures: Array[String]) -> void:
	var root := _make_root()
	var attacker := _spawn_unit(root, SWORDSMAN, Enums.Team.PLAYER, Vector2.ZERO)
	var mover := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(1.0, 0.0))
	mover.command_move(Vector2(8.0, 0.0))
	if mover.order != Enums.OrderType.MOVE:
		failures.append("setup: unit should be moving before retaliation check")
	CombatSystemScript.apply_hit(SWORDSMAN, mover, {"attacker": attacker})
	if mover.order != Enums.OrderType.MOVE:
		failures.append("moving unit should not switch to attack on damage")
	root.free()

func _test_ranged_attack_range_from_def(failures: Array[String]) -> void:
	if ARCHER.attack_range != 9.0:
		failures.append("archer attack_range should be configurable in UnitDef")
	if ARCHER.preferred_attack_range != 8.0:
		failures.append("archer preferred_attack_range should be configurable in UnitDef")
	var root := _make_root()
	var archer := _spawn_unit(root, ARCHER, Enums.Team.PLAYER, Vector2.ZERO)
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(1.0, 0.0))
	if archer.call("_effective_attack_range", target) != ARCHER.attack_range:
		failures.append("ranged effective range should come from UnitDef.attack_range")
	if archer.call("_needs_attack_chase", target):
		failures.append("archer in attack range should not flee when enemy is close")
	var far_target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(20.0, 0.0))
	var far_approach: Vector2 = archer.call("_attack_approach_point", far_target)
	if far_approach.distance_to(far_target.sim_pos) > ARCHER.attack_range:
		failures.append("ranged chase point should stay within attack_range")
	root.free()

func _advance_combat(entity: Node, duration: float, step: float = 0.05) -> void:
	var root := entity.get_parent()
	if root == null:
		return
	var elapsed := 0.0
	while elapsed < duration:
		_physics_process_recursive(root, step)
		elapsed += step

func _physics_process_recursive(node: Node, delta: float) -> void:
	if node.has_method("_physics_process"):
		node._physics_process(delta)
	for child in node.get_children():
		_physics_process_recursive(child, delta)

func _make_root() -> Node2D:
	var root := Node2D.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(root)
	return root

func _spawn_unit(
	root: Node2D,
	unit_def: UnitDef,
	team: Enums.Team,
	spawn_position: Vector2,
	civ: CivDef = null
) -> UnitAgent:
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = unit_def
	unit.team = team
	unit.civ = civ
	unit.sim_pos = spawn_position
	root.add_child(unit)
	unit._ready()
	return unit
