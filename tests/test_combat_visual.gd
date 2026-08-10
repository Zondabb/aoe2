extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_world_hp_bar_shows_after_damage(failures)
	return failures

func _test_world_hp_bar_shows_after_damage(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = SWORDSMAN
	unit.sim_pos = Vector2.ZERO
	root.add_child(unit)
	unit._ready()
	var bar := unit.get_node_or_null("WorldHpBar") as Control
	if bar == null:
		failures.append("unit should have WorldHpBar node")
		root.free()
		return
	if bar.visible:
		failures.append("hp bar should stay hidden at full health")
	unit.take_damage(5.0)
	if not bar.visible:
		failures.append("hp bar should appear after taking damage")
	root.free()
