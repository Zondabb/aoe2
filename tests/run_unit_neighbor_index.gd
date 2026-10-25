extends SceneTree
## Unit-only movement queries must match filtering the full vision index, even
## when hundreds of walls share the same neighbourhood.
const Vision := preload("res://scripts/systems/vision_service.gd")

class Body extends Node2D:
	var def: Resource
	var sim_pos := Vector2.ZERO
	var hp := 40.0
	var is_placement_ghost := false
	func take_damage(_amount: float, _source: Node = null) -> void: pass

var checks := 0
var failures: Array[String] = []
var bodies: Array[Body] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)

func body(definition: Resource, pos: Vector2) -> Body:
	var value := Body.new()
	value.def = definition
	value.sim_pos = pos
	bodies.append(value)
	return value

func expected(vision: VisionService, observer: Body, radius: float) -> Array:
	return vision.others_in_radius(observer, radius).filter(func(other): return other.def is UnitDef)

func _initialize() -> void:
	var vision := Vision.new()
	vision.setup(2.0)
	var unit := UnitDef.new()
	unit.vision_radius = 8.0
	var wall := BuildingDef.new()
	var observer := body(unit, Vector2.ZERO)
	vision.register(observer)
	var units: Array[Body] = []
	for index in 80:
		var value := body(unit, Vector2(index % 10 - 5, index / 10 - 4) * 1.6)
		units.append(value)
		vision.register(value)
		# Interleave insertion order, including coincident centres.
		for piece in 8:
			vision.register(body(wall, value.sim_pos + Vector2(piece % 4, piece / 4) * 0.3))
	for radius in [0.0, 1.0, 2.5, 7.0, 8.0, 15.0]:
		for pos in [Vector2.ZERO, Vector2(2, 3), Vector2(-7, -4)]:
			observer.sim_pos = pos
			vision.sync_position(observer)
			check(vision.units_in_radius(observer, radius) == expected(vision, observer, radius), "same ordered neighbours at %s / %s" % [pos, radius])
	check(vision.unit_hash.entity_count() == 81, "only units enter movement index")
	check(vision.hash.entity_count() == 721, "full vision retains all buildings and units")
	check(vision.units_in_radius(observer) == expected(vision, observer, 8.0), "default radius uses observer vision")
	observer.sim_pos = Vector2.ZERO
	vision.sync_position(observer)
	for index in units.size():
		var value := units[index]
		value.sim_pos = Vector2.from_angle(index * 0.3) * (index % 9)
		if index % 4 == 0: value.hp = 0
		if index % 7 == 0: value.is_placement_ghost = true
		vision.sync_position(value)
		check(vision.units_in_radius(observer, 8.0) == expected(vision, observer, 8.0), "moving/dead/ghost neighbour %d" % index)
	for value in units:
		vision.unregister(value)
	check(vision.units_in_radius(observer, 20.0).is_empty(), "unregister removes movement neighbours")
	check(vision.unit_hash.entity_count() == 1, "unit index retains only observer after removals")
	for value in units:
		value.hp = 40
		value.is_placement_ghost = false
		vision.register(value)
	# Query filters still apply between mutation and the next synchronisation.
	units[0].hp = 0
	units[1].is_placement_ghost = true
	check(vision.units_in_radius(observer, 8.0) == expected(vision, observer, 8.0), "death and ghost filtering before sync")
	units[2].def = wall
	vision.sync_position(units[2])
	check(not vision.unit_hash.has_entity(units[2]), "definition change removes unit from movement index")
	check(vision.units_in_radius(observer, 8.0) == expected(vision, observer, 8.0), "definition change preserves full index")
	check(vision.units_in_radius(null, 8.0).is_empty(), "null observer")
	vision.clear()
	check(vision.hash.entity_count() == 0 and vision.unit_hash.entity_count() == 0, "clear resets both indices")
	for value in bodies: value.free()
	failures.append_array(load("res://tests/test_vision_service.gd").new().run())
	for failure in failures: push_error(failure)
	print("UNIT NEIGHBOUR INDEX: %d checks, %d failures" % [checks, failures.size()])
	quit(1 if not failures.is_empty() else 0)
