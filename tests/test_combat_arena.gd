extends RefCounted

const ARENA_SCENE := preload("res://scenes/combat_arena.tscn")
const ArenaConfigScript := preload("res://scripts/data/arena_config.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_arena_spawns_configured_army(failures)
	return failures

func _test_arena_spawns_configured_army(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var arena := ARENA_SCENE.instantiate() as Node2D
	tree.root.add_child(arena)
	var bootstrap := arena.get_node("Bootstrap") as Node
	var config := ArenaConfigScript.new()
	config.unit_counts = {
		&"villager": 1,
		&"swordsman": 2,
		&"archer": 1,
	}
	bootstrap.call("_start_battle", config)
	var entities := arena.get_node("Entities") as Node2D
	if entities.get_child_count() != 8:
		failures.append("arena should spawn mirrored armies from unit counts")
	var player_units := 0
	var ai_units := 0
	for child in entities.get_children():
		if child.get("team") == Enums.Team.PLAYER:
			player_units += 1
		elif child.get("team") == Enums.Team.AI:
			ai_units += 1
	if player_units != 4 or ai_units != 4:
		failures.append("arena should spawn equal armies for player and AI")
	arena.free()
