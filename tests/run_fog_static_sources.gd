extends SceneTree
## Compare the cached static union with a fresh per-source raster on every
## refresh. The reference owns its masks and never calls the production stamp.
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")

class Source extends Node2D:
	var def: Resource
	var sim_pos := Vector2.ZERO
	var team := 0
	var hp := 100.0
	var is_placement_ghost := false
	var is_complete := true
	var radius := 6.0
	func resolved_vision_radius() -> float:
		if radius >= 0.0: return radius
		if def is BuildingDef:
			return def.vision_radius if is_complete else def.construction_vision_radius
		return 0.0

class Reference extends RefCounted:
	var map_origin := Vector2.ZERO
	var grid_size := Vector2i.ONE
	var cell_size := 1.0
	var visible_now := {}
	var explored := {}
	var source_counts := {}
	var revision := 0
	var ready := false
	var dirty := true
	func setup_rect(minimum: Vector2, maximum: Vector2, size: float) -> void:
		map_origin = minimum
		cell_size = maxf(size, 0.1)
		grid_size = Vector2i(maxi(1, ceili((maximum.x - minimum.x) / cell_size)), maxi(1, ceili((maximum.y - minimum.y) / cell_size)))
		reset()
	func reset() -> void:
		for team in Enums.Team.values():
			var mask := PackedByteArray()
			mask.resize(grid_size.x * grid_size.y)
			mask.fill(0)
			visible_now[team] = mask.duplicate()
			explored[team] = mask.duplicate()
			source_counts[team] = 0
		ready = false
		dirty = true
		revision += 1
	func rebuild(entities: Array) -> void:
		var changed := not ready
		for team in Enums.Team.values():
			var mask := PackedByteArray()
			mask.resize(grid_size.x * grid_size.y)
			mask.fill(0)
			var count := 0
			for entity in entities:
				if not is_instance_valid(entity) or entity.team != team: continue
				if entity.is_placement_ghost or entity.hp <= 0: continue
				var radius: float = entity.resolved_vision_radius()
				if radius <= 0: continue
				count += 1
				# Original per-source circle spans, deliberately without shared
				# row coverage or persistent cached masks.
				var pos: Vector2 = entity.sim_pos
				var y0 := maxi(0, floori((pos.y - radius - map_origin.y) / cell_size))
				var y1 := mini(grid_size.y - 1, floori((pos.y + radius - map_origin.y) / cell_size))
				for y in range(y0, y1 + 1):
					var dy := map_origin.y + (y + 0.5) * cell_size - pos.y
					var remaining := radius * radius - dy * dy
					if remaining < 0: continue
					var dx := sqrt(remaining)
					var x0 := maxi(0, ceili((pos.x - dx - map_origin.x) / cell_size - 0.5))
					var x1 := mini(grid_size.x - 1, floori((pos.x + dx - map_origin.x) / cell_size - 0.5))
					for x in range(x0, x1 + 1): mask[y * grid_size.x + x] = 255
			changed = changed or visible_now[team] != mask
			visible_now[team] = mask
			var history: PackedByteArray = explored[team]
			for index in mask.size():
				if mask[index] != 0: history[index] = 255
			explored[team] = history
			source_counts[team] = count
		ready = true
		dirty = false
		if changed: revision += 1

var checks := 0
var failures: Array[String] = []
var compared_bytes := 0
var refreshes := 0
var sources: Array = []
var fog := Fog.new()
var reference := Reference.new()
var rng := RandomNumberGenerator.new()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func compare(label: String) -> void:
	fog.rebuild(sources)
	reference.rebuild(sources)
	refreshes += 1
	for team in Enums.Team.values():
		check(fog.visible_now[team] == reference.visible_now[team], "%s: visible bytes team %d" % [label, team])
		check(fog.explored[team] == reference.explored[team], "%s: explored bytes team %d" % [label, team])
		check(fog.source_counts[team] == reference.source_counts[team], "%s: source count team %d" % [label, team])
		compared_bytes += fog.visible_now[team].size() * 2
	check(fog.revision == reference.revision, "%s: mask revision" % label)
	check(fog.ready == reference.ready and fog.dirty == reference.dirty, "%s: ready and dirty" % label)

func setup_rect(minimum: Vector2, maximum: Vector2, size: float) -> void:
	fog.setup_rect(minimum, maximum, size)
	reference.setup_rect(minimum, maximum, size)
	check(fog.grid_size == reference.grid_size, "setup grid dimensions")

func add_source(pos: Vector2, radius: float, team: int, stationary := true) -> Source:
	var value := Source.new()
	value.def = BuildingDef.new() if stationary else UnitDef.new()
	value.sim_pos = pos
	value.radius = radius
	value.team = team
	sources.append(value)
	return value

func clear_sources() -> void:
	for value in sources:
		if is_instance_valid(value): value.free()
	sources.clear()

func _initialize() -> void:
	rng.seed = 592733
	_test_overlap_and_lifecycle()
	_test_random_mutations()
	clear_sources()
	print("FOG STATIC SOURCES: %d checks, %d failures, %d refreshes, %d compared bytes" % [checks, failures.size(), refreshes, compared_bytes])
	quit(0 if failures.is_empty() else 1)

func _test_overlap_and_lifecycle() -> void:
	setup_rect(Vector2(-32, -20), Vector2(36, 28), 1.0)
	var left := add_source(Vector2(-16.5, 0.5), 5.0, 0)
	var right := add_source(Vector2(16.5, 0.5), 5.0, 0)
	var moving := add_source(Vector2(0.5, 0.5), 11.0, 0, false)
	add_source(Vector2(0.5, 12.5), 3.0, 1)
	compare("overlap and separated static circles")
	for step in 30:
		moving.sim_pos = Vector2(-28.0 + step * 2, sin(step * 0.3) * 10)
		compare("moving overlap %d" % step)
	moving.hp = 0
	compare("dynamic source dies without contaminating static mask")
	left.sim_pos = Vector2(-4.5, -2.5)
	compare("static source moves directly")
	left.team = 1
	compare("static source changes team")
	left.radius = 0
	compare("static vision removed")
	left.radius = 12
	right.is_placement_ghost = true
	compare("static ghost")
	right.is_placement_ghost = false
	right.hp = 0
	compare("static death")
	right.hp = 100
	right.radius = -1
	(right.def as BuildingDef).vision_radius = 9
	(right.def as BuildingDef).construction_vision_radius = 2
	right.is_complete = false
	compare("foundation radius")
	right.is_complete = true
	compare("construction completion radius")
	right.def = UnitDef.new()
	right.radius = 6
	compare("static becomes dynamic")
	right.def = BuildingDef.new()
	compare("dynamic becomes static")
	sources.reverse()
	compare("reordered sources")
	left.free()
	compare("freed static source remains in caller array")
	sources.append(null)
	compare("null source")
	fog.memories[0][123] = {"last_seen": true}
	fog.reset()
	reference.reset()
	check(fog.memories[0].is_empty(), "reset clears memories")
	compare("reset invalidates static union")
	setup_rect(Vector2(20, 40), Vector2(65, 73), 1.3)
	compare("resize and origin change with same sources")
	setup_rect(Vector2(-3, -2), Vector2(3, 2), 0.5)
	right.sim_pos = Vector2(0.25, 0.25)
	right.radius = 0.5
	compare("small grid and exact radius boundary")
	clear_sources()
	compare("remove every source")

func _test_random_mutations() -> void:
	for trial in 7:
		clear_sources()
		var minimum := Vector2(rng.randf_range(-50, -10), rng.randf_range(-35, 5))
		var maximum := minimum + Vector2(rng.randf_range(30, 90), rng.randf_range(24, 75))
		var size: float = [0.5, 0.7, 1.0, 1.3][trial % 4]
		setup_rect(minimum, maximum, size)
		for index in 90:
			add_source(Vector2(rng.randf_range(minimum.x - 12, maximum.x + 12), rng.randf_range(minimum.y - 12, maximum.y + 12)), rng.randf_range(0.2, 12), index % 2, index % 4 != 0)
		compare("random %d initial" % trial)
		for step in 45:
			var value: Source = sources[rng.randi_range(0, sources.size() - 1)]
			match step % 9:
				0: value.sim_pos += Vector2(rng.randf_range(-8, 8), rng.randf_range(-8, 8))
				1: value.radius = rng.randf_range(0, 18)
				2: value.team = 1 - value.team
				3: value.is_placement_ghost = not value.is_placement_ghost
				4: value.hp = 100 if value.hp <= 0 else 0
				5: value.def = UnitDef.new() if value.def is BuildingDef else BuildingDef.new()
				6: sources.reverse()
				7: add_source((minimum + maximum) * 0.5, rng.randf_range(1, 14), step % 2)
				8:
					if step == 35:
						fog.reset()
						reference.reset()
					else:
						sources.erase(value)
						value.free()
			compare("random %d mutation %d" % [trial, step])
			compare("random %d unchanged %d" % [trial, step])
