extends SceneTree
## Boundary/long-run tests for arithmetic that must not depend on libm or FPS.
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const State := preload("res://scripts/network/lockstep_state.gd")
const Projectile := preload("res://scenes/entities/projectile_view.tscn")
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
	check(Fixed.mul_div(1, 1, 2) == 1 and Fixed.mul_div(-1, 1, 2) == -1, "half ties have a defined signed rounding rule")
	check(Fixed.mul_div(-5, 7, -3) == 12 and Fixed.mul_div(5, 7, -3) == -12, "division handles either denominator sign")
	check(Fixed.mul_div(480 * 1024, 480 * 1024, 1024) == 235929600, "map coordinate products use int64")
	for n in [0, 1, 2, 3, 4, 8, 9, 15, 16, 17, 1000000000000, 9223372036854775807]:
		var r := Fixed.isqrt(n)
		@warning_ignore("integer_division")
		var lower_ok: bool = r == 0 or r <= n / r
		@warning_ignore("integer_division")
		var upper_ok: bool = (r + 1) > n / (r + 1)
		check(lower_ok and upper_ok, "integer square root bounds %d" % n)
	check(Fixed.distance_squared(Vector2(-480, -480), Vector2(480, 480)) == 1932735283200, "large negative-to-positive squared distance does not overflow int32")
	check(Fixed.normalize_step(Vector2(-3, -4), Vector2.ZERO, 1024) == Vector2(-2.400390625, -3.2001953125), "integer normalization has stable negative rounding")
	var elapsed := 0
	for _i in 108000: elapsed += Fixed.delta_time(0.0, true)
	check(elapsed == 3600 * Fixed.TIME_SCALE, "one hour of 30 Hz time is exact")
	var encoded: Variant = JSON.parse_string(JSON.stringify(State.encode(Vector2i(-491520, 491520))))
	check(State.valid_encoded(encoded, {}) and State.decode(encoded, {}) == Vector2i(-491520, 491520), "integer vector survives JSON")
	check(not State.valid_encoded(["vi", 2147483648, 0], {}) and not State.valid_encoded(["vi", 1.5, 0], {}), "integer vector rejects overflow and fractions")
	for path in ["res://tests/test_combat_math.gd", "res://tests/test_combat_system.gd", "res://tests/test_projectile_impact.gd"]:
		var problems: Array = load(path).new().run()
		check(problems.is_empty(), "%s: %s" % [path, problems])
	var unit := UnitAgent.new()
	unit.hp = 1000
	for _i in 2000: unit.take_damage_fixed(64)
	check(unit.hp_q == 875 * Fixed.SCALE, "repeated fractional damage has no accumulated rounding drift")
	unit.free()
	var world := Node2D.new()
	root.add_child(world)
	var definition := UnitDef.new()
	definition.projectile_speed = 28.0
	var shot: ProjectileAgent = Projectile.instantiate()
	world.add_child(shot)
	shot.setup(Vector2.ZERO, Vector2(500, 0), definition, Enums.Team.PLAYER)
	shot.set_physics_process(false)
	for _i in 300: shot._physics_process(1.0 / 30.0)
	check(shot._traveled_fixed == 280 * Fixed.SCALE and shot._travel_remainder == 0 and shot.sim_pos == Vector2(280, 0), "ten seconds of projectile travel preserves fractional step remainders")
	var slow: ProjectileAgent = Projectile.instantiate()
	world.add_child(slow)
	definition = definition.duplicate()
	definition.projectile_speed = 1.0 / Fixed.SCALE
	slow.setup(Vector2.ZERO, Vector2(1, 0), definition, Enums.Team.PLAYER)
	slow.set_physics_process(false)
	for _i in 29: slow._physics_process(1.0 / 30.0)
	check(slow._traveled_fixed == 0 and slow._travel_remainder > 0, "sub-grid projectile distance is retained until payable")
	slow._physics_process(1.0 / 30.0)
	check(slow._traveled_fixed == 1 and slow._travel_remainder == 0, "sub-grid motion pays out exactly on the thirtieth step")
	world.free()
	print("INTEGER SIMULATION: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
