extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_world_hp_bar_shows_after_damage(failures)
	_test_swordsman_attack_frames_loaded(failures)
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
	var bar := unit.get_node_or_null("WorldHpBar") as Node2D
	if bar == null:
		failures.append("unit should have WorldHpBar node")
		root.free()
		return
	if bar.visible:
		failures.append("hp bar should stay hidden at full health")
	unit.take_damage(5.0)
	if not bar.visible:
		failures.append("hp bar should appear after taking damage")
	var top_y: float = unit.call("_sprite_top_local_y")
	if bar.position.y >= top_y - 4.0:
		failures.append("hp bar should render above the unit sprite top")
	root.free()


func _test_swordsman_attack_frames_loaded(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = SWORDSMAN
	unit.sim_pos = Vector2.ZERO
	root.add_child(unit)
	unit._ready()
	var billboard := unit.get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard == null or billboard.sprite_frames == null:
		failures.append("swordsman should use billboard presentation")
	elif not billboard.sprite_frames.has_animation(&"attack_dir_0"):
		failures.append("swordsman should load attack_dir_0 combat animation")
	else:
		unit._facing_dir = 0
		unit._combat_action = &"attack"
		unit._combat_anim_time = 0.1
		unit.call("_apply_billboard_frame", true, &"attack", false)
		if billboard.animation != &"attack_dir_0":
			failures.append("swordsman should play attack_dir_0 when attacking")
	root.free()
