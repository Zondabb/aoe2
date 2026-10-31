extends SceneTree
## FogOfWarService.footprints_fully_visible must equal footprint_visible(..., true)
## point by point, including map edges, out-of-bounds points and cell borders
## (also within a fraction of the fixed-point coordinate step).
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_map_data = {}
	session.match_ai_mode = "sandbox"
	session.online_active = false
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var state: MatchState = world.get_node("Bootstrap").match_state
	var fog: FogOfWarService = state.fog
	fog.rebuild(world.get_node("Entities").get_children())
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var anchors: Array[Vector2] = []
	for node in world.get_node("Entities").get_children():
		if node.get("team") in [0, 1] and node.get("hp") != null: anchors.append(node.sim_pos)
	var compared := 0
	var visible_count := 0
	for team in [0, 1, 7]:
		for footprint in [Vector2.ZERO, Vector2(0.5, 0.5), Vector2.ONE, Vector2(3.2, 3.2), Vector2(4, 4), Vector2(6, 2), Vector2(9.5, 9.5)]:
			var points := PackedVector2Array()
			for i in 1500:
				var point := Vector2(rng.randf_range(fog.map_origin.x - 6, fog.map_end.x + 6), rng.randf_range(fog.map_origin.y - 6, fog.map_end.y + 6))
				# Half the samples lie in and around each side's sight.
				if i % 2 == 1: point = anchors[rng.randi() % anchors.size()] + Vector2(rng.randf_range(-40, 40), rng.randf_range(-40, 40))
				if i % 5 == 0: point = (point / fog.cell_size).round() * fog.cell_size + footprint * 0.5 * (1 if i % 2 == 0 else -1)
				if i % 7 == 0: point = Vector2(fog.map_origin.x, point.y) + footprint * 0.5
				# Within a fraction of the 1/1024 coordinate step of a cell border:
				# cells follow the fixed-point lattice, not float rounding.
				if i % 11 == 0:
					var border: Vector2 = (point / fog.cell_size).round() * fog.cell_size + footprint * 0.5 * (1 if i % 3 == 0 else -1)
					point = border + Vector2([-0.0011, -0.0006, -0.0002, 0.0002, 0.0006, 0.0011][rng.randi() % 6], [-0.0006, 0.0, 0.0006][rng.randi() % 3])
				points.append(point)
			var batch := fog.footprints_fully_visible(team, points, footprint)
			var mismatches := 0
			for index in points.size():
				var expected := fog.footprint_visible(team, points[index], footprint, true)
				if expected != (batch[index] != 0): mismatches += 1
				if expected: visible_count += 1
			compared += points.size()
			check(mismatches == 0, "team %d footprint %s: batch equals footprint_visible (%d mismatches)" % [team, footprint, mismatches])
	check(visible_count > 100, "samples include visible footprints (%d)" % visible_count)
	print("FOG BATCH VISIBILITY: %d checks, %d failures, %d points compared, %d visible" % [checks, failures, compared, visible_count])
	quit(0 if failures == 0 else 1)
