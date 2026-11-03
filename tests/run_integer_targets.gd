extends SceneTree

const Fixed := preload("res://scripts/core/sim_fixed.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _run() -> void:
	_test_direction_independent_clock()
	_test_attack_targets()
	_test_integer_rings()
	_test_reserved_targets()
	print("INTEGER TARGETS: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _test_direction_independent_clock() -> void:
	var unit := UnitAgent.new()
	unit.def = GameCatalog.get_unit(&"trebuchet")
	check(unit._combat_anim_duration_units(&"attack") == Fixed.time_from_seconds(2.2), "a unit without a billboard uses the canonical 22-frame trebuchet clock")
	var billboard := AnimatedSprite2D.new()
	billboard.name = "Billboard"
	var frames := SpriteFrames.new()
	for name in ["attack_dir_0", "attack_dir_1", "die_dir_0", "die_dir_1", "chop_dir_0", "chop_dir_1"]:
		frames.add_animation(name)
		var count := 5 if name.ends_with("0") else 13
		for _i in count: frames.add_frame(name, null)
	billboard.sprite_frames = frames
	unit.add_child(billboard)
	for villager in [false, true]:
		unit.def = GameCatalog.get_unit(&"villager" if villager else &"trebuchet")
		unit._villager_actions = villager
		if villager: frames.remove_animation("attack_dir_0")
		for action in [&"attack", &"die"]:
			unit._facing_dir = 0
			var expected := unit._combat_anim_duration_units(action)
			for direction in range(1, 8):
				unit._facing_dir = direction
				unit._facing_flip = direction % 2 == 0
				check(unit._combat_anim_duration_units(action) == expected, "facing never changes strike or corpse duration")
			unit.remove_child(billboard)
			check(unit._combat_anim_duration_units(action) == expected, "removing presentation mid-action leaves the game clock unchanged")
			unit.add_child(billboard)
	unit.free()

func _test_attack_targets() -> void:
	var unit := UnitAgent.new()
	var target := UnitAgent.new()
	target.def = GameCatalog.get_unit(&"villager")
	target.sim_pos = Vector2(-12.25, 8.125)
	unit.def = GameCatalog.get_unit(&"swordsman")
	unit.sim_pos = Vector2(-19.75, 11.375)
	var seen := {}
	for slot in 12:
		unit.set_meta("net_id", slot)
		var point := unit._attack_approach_point(target)
		check(point == Fixed.quantize_vector(point), "melee approach is a lattice coordinate")
		seen[point] = true
		unit._facing_dir = slot % 5
		check(unit._attack_approach_point(target) == point, "melee approach ignores visual facing")
	check(seen.size() == 12, "twelve melee slots remain distinct")
	unit.def = GameCatalog.get_unit(&"archer")
	unit.sim_pos = target.sim_pos + Vector2(-40, 13)
	var ranged := unit._attack_approach_point(target)
	check(ranged == Fixed.quantize_vector(ranged) and ranged.x < target.sim_pos.x, "ranged approach remains on the near side of the target")
	unit.sim_pos = target.sim_pos
	check(unit._attack_approach_point(target) == unit.sim_pos, "zero-minimum-range overlap remains stationary")
	var quantum := 1.0 / Fixed.SCALE
	check(UnitAgent._within_distance(Vector2.ZERO, Vector2(1, 0), 1.0), "exact arrival boundary is inside")
	check(not UnitAgent._within_distance(Vector2.ZERO, Vector2(1 + quantum, 0), 1.0), "one quantum beyond arrival is outside")
	unit.free()
	target.free()

func _test_integer_rings() -> void:
	for direction in [Vector2i(1024, 0), Vector2i(-1024, 0), UnitAgent._direction_q(Vector2i(31744, -23552))]:
		for ring in range(1, 13):
			var seen := {}
			for slot in ring * 8:
				var offset := UnitAgent._ring_offset_q(ring, slot, 1536, direction)
				seen[offset] = true
				check(UnitAgent._ring_offset_q(ring, (slot + ring * 4) % (ring * 8), 1536, direction) == -offset, "ring opposite slots are exactly symmetric")
			check(seen.size() == ring * 8, "ring candidates have no duplicate positions")

func _test_reserved_targets() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var units: Array[UnitAgent] = []
	for index in 12:
		var unit := UnitAgent.new()
		unit.def = GameCatalog.get_unit(&"villager")
		unit.sim_pos = Vector2(-20, index - 6)
		unit.set_meta("net_id", index + 1)
		world.add_child(unit)
		unit.set_physics_process(false)
		units.append(unit)
	var goals := {}
	for unit in units:
		unit.command_move(Vector2(10.00001, -9.99999))
		var goal := unit._move_target
		check(unit._requested_move_target == Vector2(10, -10) and goal == Fixed.quantize_vector(goal), "input and reserved goal use the same integer lattice")
		check(not goals.has(goal), "shared command reserves distinct destinations")
		goals[goal] = true
		unit.command_move(Vector2(10.00002, -9.99998))
		check(unit._move_target == goal, "equivalent input quantum does not reshuffle destinations")
	world.free()
