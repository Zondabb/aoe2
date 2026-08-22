extends RefCounted

const SpatialHashScript := preload("res://scripts/systems/spatial_hash.gd")
const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")

class _Body extends RefCounted:
	var def: Resource
	var sim_pos: Vector2
	var team: Enums.Team = Enums.Team.PLAYER
	var hp := 40.0
	var is_placement_ghost := false
	var vision_radius_override: float = -1.0
	var name := "Body"

	func take_damage(_amount: float, _source: Node = null) -> void:
		pass

	func resolved_vision_radius() -> float:
		if vision_radius_override >= 0.0:
			return vision_radius_override
		var unit_def := def as UnitDef
		if unit_def != null:
			return unit_def.resolved_vision_radius()
		return 8.0


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_spatial_hash_insert_move_query(failures)
	_test_vision_nearest_hostile(failures)
	_test_vision_uses_unit_radius(failures)
	_test_vision_ignores_invalid(failures)
	_test_vision_override_and_others(failures)
	return failures


func _make_unit(pos: Vector2, team: Enums.Team, vision: float = 8.0) -> Object:
	var u := _Body.new()
	var def := UnitDef.new()
	def.vision_radius = vision
	def.footprint_radius = 0.42
	u.def = def
	u.sim_pos = pos
	u.team = team
	u.hp = 40.0
	return u


func _test_spatial_hash_insert_move_query(failures: Array[String]) -> void:
	var hash := SpatialHashScript.new()
	hash.setup(2.0)
	var a := _make_unit(Vector2(0.5, 0.5), Enums.Team.PLAYER)
	var b := _make_unit(Vector2(5.0, 0.0), Enums.Team.AI)
	var far := _make_unit(Vector2(40.0, 40.0), Enums.Team.AI)
	hash.insert(a, a.sim_pos)
	hash.insert(b, b.sim_pos)
	hash.insert(far, far.sim_pos)
	if hash.entity_count() != 3:
		failures.append("hash should track 3 entities, got %d" % hash.entity_count())
	var near := hash.query_radius(Vector2.ZERO, 6.0)
	if near.size() != 2:
		failures.append("query_radius 6 should return 2 entities, got %d" % near.size())
	b.sim_pos = Vector2(20.0, 0.0)
	hash.move(b, b.sim_pos)
	var after_move := hash.query_radius(Vector2.ZERO, 6.0)
	if after_move.size() != 1:
		failures.append("after move, query should return 1 entity, got %d" % after_move.size())
	hash.remove(a)
	if hash.entity_count() != 2:
		failures.append("after remove, entity_count should be 2, got %d" % hash.entity_count())


func _test_vision_nearest_hostile(failures: Array[String]) -> void:
	var vision := VisionServiceScript.new()
	vision.setup(2.0)
	var scout := _make_unit(Vector2.ZERO, Enums.Team.PLAYER, 8.0)
	var near_enemy := _make_unit(Vector2(3.0, 0.0), Enums.Team.AI)
	var far_enemy := _make_unit(Vector2(20.0, 0.0), Enums.Team.AI)
	var ally := _make_unit(Vector2(2.0, 0.0), Enums.Team.PLAYER)
	vision.register(scout)
	vision.register(near_enemy)
	vision.register(far_enemy)
	vision.register(ally)
	var found = vision.nearest_hostile(scout, Enums.Team.AI)
	if found != near_enemy:
		failures.append("nearest hostile should be near enemy")
	var none = vision.nearest_hostile(scout, Enums.Team.AI, 2.0)
	if none != null:
		failures.append("radius 2 should find no enemy at dist 3")


func _test_vision_uses_unit_radius(failures: Array[String]) -> void:
	var vision := VisionServiceScript.new()
	vision.setup(2.0)
	var scout := _make_unit(Vector2.ZERO, Enums.Team.PLAYER, 5.0)
	var enemy := _make_unit(Vector2(6.0, 0.0), Enums.Team.AI)
	vision.register(scout)
	vision.register(enemy)
	if vision.vision_radius_of(scout) != 5.0:
		failures.append("vision_radius_of should read UnitDef")
	if vision.nearest_hostile(scout, Enums.Team.AI) != null:
		failures.append("default vision 5 should not see enemy at 6")
	if vision.nearest_hostile(scout, Enums.Team.AI, 7.0) != enemy:
		failures.append("explicit radius 7 should see enemy at 6")


func _test_vision_ignores_invalid(failures: Array[String]) -> void:
	var vision := VisionServiceScript.new()
	vision.setup(2.0)
	var scout := _make_unit(Vector2.ZERO, Enums.Team.PLAYER, 10.0)
	var dead := _make_unit(Vector2(1.0, 0.0), Enums.Team.AI)
	dead.hp = 0.0
	var ghost := _make_unit(Vector2(1.5, 0.0), Enums.Team.AI)
	ghost.is_placement_ghost = true
	vision.register(scout)
	vision.register(dead)
	vision.register(ghost)
	if vision.hash.entity_count() != 1:
		failures.append(
			"dead/ghost should not stay indexed after register filter, got %d"
			% vision.hash.entity_count()
		)
	# Force-insert invalids to ensure query filter still drops them.
	vision.hash.insert(dead, dead.sim_pos)
	vision.hash.insert(ghost, ghost.sim_pos)
	if vision.nearest_hostile(scout, Enums.Team.AI) != null:
		failures.append("nearest_hostile must ignore dead and ghost")


func _test_vision_override_and_others(failures: Array[String]) -> void:
	var vision := VisionServiceScript.new()
	vision.setup(2.0)
	var scout := _make_unit(Vector2.ZERO, Enums.Team.PLAYER, 4.0)
	scout.set("vision_radius_override", 9.0)
	var ally := _make_unit(Vector2(5.0, 0.0), Enums.Team.PLAYER)
	var enemy := _make_unit(Vector2(7.0, 0.0), Enums.Team.AI)
	vision.register(scout)
	vision.register(ally)
	vision.register(enemy)
	if absf(vision.vision_radius_of(scout) - 9.0) > 0.001:
		failures.append("vision_radius_override should win over UnitDef")
	var others: Array = vision.others_in_radius(scout)
	if others.size() != 2:
		failures.append("others_in_radius should see ally+enemy, got %d" % others.size())
	if vision.nearest_hostile(scout, Enums.Team.AI) != enemy:
		failures.append("nearest_hostile should still find enemy via override radius")
