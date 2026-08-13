extends RefCounted

const AutoCombatDirectorScript := preload("res://scripts/systems/auto_combat_director.gd")

class FakeEntity extends Node2D:
	var def: Resource
	var hp := 100.0
	var team: Enums.Team = Enums.Team.PLAYER
	var sim_pos := Vector2.ZERO
	var order: Enums.OrderType = Enums.OrderType.NONE
	var _attack_target: Node = null
	var attack_calls: Array = []

	func _init() -> void:
		add_to_group("units")

	func command_attack(target: Node) -> void:
		attack_calls.append(target)
		_attack_target = target
		order = Enums.OrderType.ATTACK

	func take_damage(_amount: float, _source: Node = null) -> void:
		pass


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_picks_nearest_in_aggro(failures)
	_test_respects_aggro_radius(failures)
	_test_skips_when_attacking_valid_target(failures)
	_test_prefers_units_over_buildings(failures)
	_test_skips_move_order(failures)
	return failures


func _test_picks_nearest_in_aggro(failures: Array[String]) -> void:
	var director := AutoCombatDirectorScript.new()
	var root := Node2D.new()
	var attacker := _make_unit(Enums.Team.AI, Vector2(0, 0))
	var near := _make_unit(Enums.Team.PLAYER, Vector2(3, 0))
	var far := _make_unit(Enums.Team.PLAYER, Vector2(20, 0))
	root.add_child(attacker)
	root.add_child(near)
	root.add_child(far)
	director.setup(root)
	director.set_team_auto_attack(Enums.Team.AI, true)
	director.aggro_radius = 40.0
	var picked: Node = director.pick_target_for_unit(attacker)
	if picked != near:
		failures.append("auto combat should pick nearest hostile in aggro")
	root.free()


func _test_respects_aggro_radius(failures: Array[String]) -> void:
	var director := AutoCombatDirectorScript.new()
	var root := Node2D.new()
	var attacker := _make_unit(Enums.Team.AI, Vector2(0, 0))
	var far := _make_unit(Enums.Team.PLAYER, Vector2(25, 0))
	root.add_child(attacker)
	root.add_child(far)
	director.setup(root)
	director.aggro_radius = 10.0
	if director.pick_target_for_unit(attacker) != null:
		failures.append("hostile outside aggro radius should not be picked")
	root.free()


func _test_skips_when_attacking_valid_target(failures: Array[String]) -> void:
	var director := AutoCombatDirectorScript.new()
	var root := Node2D.new()
	var attacker := _make_unit(Enums.Team.AI, Vector2(0, 0))
	var target := _make_unit(Enums.Team.PLAYER, Vector2(4, 0))
	var closer := _make_unit(Enums.Team.PLAYER, Vector2(1, 0))
	root.add_child(attacker)
	root.add_child(target)
	root.add_child(closer)
	attacker.order = Enums.OrderType.ATTACK
	attacker._attack_target = target
	director.setup(root)
	director.set_team_auto_attack(Enums.Team.AI, true)
	director.retarget_radius = 12.0
	director.tick(1.0)
	if attacker.attack_calls.size() > 0:
		failures.append("director should not reissue attack while current target is valid")
	root.free()


func _test_prefers_units_over_buildings(failures: Array[String]) -> void:
	var director := AutoCombatDirectorScript.new()
	var root := Node2D.new()
	var attacker := _make_unit(Enums.Team.AI, Vector2(0, 0))
	var building := _make_building(Enums.Team.PLAYER, Vector2(2, 0))
	var unit := _make_unit(Enums.Team.PLAYER, Vector2(8, 0))
	root.add_child(attacker)
	root.add_child(building)
	root.add_child(unit)
	director.setup(root)
	director.include_buildings = true
	director.prefer_units_over_buildings = true
	var picked: Node = director.pick_target_for_unit(attacker)
	if picked != unit:
		failures.append("director should prefer units over buildings")
	root.free()


func _test_skips_move_order(failures: Array[String]) -> void:
	var director := AutoCombatDirectorScript.new()
	var root := Node2D.new()
	var mover := _make_unit(Enums.Team.AI, Vector2(0, 0))
	var enemy := _make_unit(Enums.Team.PLAYER, Vector2(2, 0))
	mover.order = Enums.OrderType.MOVE
	root.add_child(mover)
	root.add_child(enemy)
	director.setup(root)
	director.set_team_auto_attack(Enums.Team.AI, true)
	director.tick(1.0)
	if mover.attack_calls.size() > 0:
		failures.append("director should not attack while unit is moving")
	root.free()


func _make_unit(team: Enums.Team, pos: Vector2) -> FakeEntity:
	var unit := FakeEntity.new()
	var def := UnitDef.new()
	def.id = &"swordsman"
	unit.def = def
	unit.team = team
	unit.sim_pos = pos
	unit.position = pos
	return unit


func _make_building(team: Enums.Team, pos: Vector2) -> FakeEntity:
	var building := FakeEntity.new()
	building.remove_from_group("units")
	var def := BuildingDef.new()
	def.id = &"barracks"
	building.def = def
	building.team = team
	building.sim_pos = pos
	building.position = pos
	return building
