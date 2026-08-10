extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_command_stop_clears_move(failures)
	return failures

func _test_command_stop_clears_move(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.sim_pos = Vector2.ZERO
	root.add_child(unit)
	unit.command_move(Vector2(5, 0))
	if unit.order != Enums.OrderType.MOVE:
		failures.append("setup move order failed")
	unit.command_stop()
	if unit.order != Enums.OrderType.NONE:
		failures.append("command_stop should clear MOVE order")
	root.free()
