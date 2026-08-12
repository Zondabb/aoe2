extends RefCounted

const ARENA_SCENE := preload("res://scenes/combat_duel_arena.tscn")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_duel_arena_spawns_lanes(failures)
	return failures

func _test_duel_arena_spawns_lanes(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var arena := ARENA_SCENE.instantiate() as Node2D
	tree.root.add_child(arena)
	var bootstrap := arena.get_node("Bootstrap") as Node
	var entities := arena.get_node("Entities") as Node2D
	# SceneTree._initialize does not reliably run child _ready; spawn explicitly.
	bootstrap.call("_spawn_scenarios")
	var units := 0
	var buildings := 0
	var player_units := 0
	var ai_units := 0
	for child in entities.get_children():
		var team = child.get("team")
		if child.get("def") is BuildingDef:
			buildings += 1
			continue
		units += 1
		if team == Enums.Team.PLAYER:
			player_units += 1
		elif team == Enums.Team.AI:
			ai_units += 1
	# 4+3+1+3+2 player = 13; AI 4+3+1+2 = 10; +1 barracks
	if units != 23:
		failures.append("duel arena should spawn 23 units across three lanes (got %d)" % units)
	if buildings != 1:
		failures.append("duel arena should spawn the AI barracks siege target")
	if player_units != 13 or ai_units != 10:
		failures.append(
			"duel arena team split should be 13 player / 10 AI (got %d / %d)"
			% [player_units, ai_units]
		)
	bootstrap.call("_spawn_scenarios")
	if entities.get_child_count() != 24:
		failures.append(
			"duel arena R-reset should recreate 24 entities (got %d)"
			% entities.get_child_count()
		)
	arena.free()
