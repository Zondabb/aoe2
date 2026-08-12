extends RefCounted

const PROJECTILE_VIEW := preload("res://scenes/entities/projectile_view.tscn")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_impact_hits_enemy_in_splash(failures)
	_test_impact_misses_when_empty(failures)
	_test_arrow_does_not_home(failures)
	return failures

func _test_impact_hits_enemy_in_splash(failures: Array[String]) -> void:
	var root := _make_root()
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(4.0, 0.0))
	var initial_hp: float = target.hp
	var arrow := _spawn_arrow(root, Vector2.ZERO, Vector2(4.0, 0.0))
	_advance(root, 1.0)
	if target.hp >= initial_hp:
		failures.append("projectile splash should damage an enemy standing on the aim point")
	if is_instance_valid(arrow) and not arrow.is_queued_for_deletion():
		failures.append("projectile should despawn after impact")
	root.free()

func _test_impact_misses_when_empty(failures: Array[String]) -> void:
	var root := _make_root()
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(4.0, 0.0))
	var initial_hp: float = target.hp
	# Aim at empty ground far from the unit.
	var arrow := _spawn_arrow(root, Vector2.ZERO, Vector2(8.0, 0.0))
	_advance(root, 1.0)
	if target.hp != initial_hp:
		failures.append("projectile should miss when no enemy is inside the impact radius")
	if is_instance_valid(arrow) and not arrow.is_queued_for_deletion():
		failures.append("missed projectile should still despawn on impact")
	root.free()

func _test_arrow_does_not_home(failures: Array[String]) -> void:
	var root := _make_root()
	var target := _spawn_unit(root, SWORDSMAN, Enums.Team.AI, Vector2(3.0, 0.0))
	var initial_hp: float = target.hp
	var arrow := _spawn_arrow(root, Vector2.ZERO, Vector2(3.0, 0.0))
	# Target runs away after the arrow is fired; arrow keeps original aim.
	target.sim_pos = Vector2(3.0, 4.0)
	_advance(root, 1.0)
	if target.hp != initial_hp:
		failures.append("projectile should not home onto a target that left the aim point")
	if is_instance_valid(arrow) and not arrow.is_queued_for_deletion():
		failures.append("non-homing projectile should despawn at the original aim point")
	root.free()

func _spawn_arrow(root: Node2D, origin: Vector2, aim: Vector2) -> Node2D:
	var arrow := PROJECTILE_VIEW.instantiate() as Node2D
	root.add_child(arrow)
	arrow.call("setup", origin, aim, ARCHER, Enums.Team.PLAYER)
	return arrow

func _spawn_unit(
	root: Node2D, unit_def: UnitDef, team: Enums.Team, spawn_position: Vector2
) -> UnitAgent:
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = unit_def
	unit.team = team
	unit.sim_pos = spawn_position
	root.add_child(unit)
	unit._ready()
	return unit

func _advance(root: Node, duration: float, step: float = 0.05) -> void:
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
