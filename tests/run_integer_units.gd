extends SceneTree

const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Farm := preload("res://scripts/entities/farm_agent.gd")
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
	_test_gather_remainders()
	_test_unit_clock_and_health()
	_test_movement_budget_and_range()
	print("INTEGER UNITS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_gather_remainders() -> void:
	for source in [ResourceNode.new(), Farm.new()]:
		source.amount = 10000.0
		source.gather_rate = 4.0
		if source is BuildingAgent: source.hp = 100.0
		var initial: int = source.amount_q
		var extracted: int = 0
		for tick in 30000:
			extracted += source.extract_fixed(Fixed.STEP_TIME)
		check(extracted == 4000 * Fixed.SCALE, "1000 seconds of gathering has no cumulative drift")
		check(source.amount_q + extracted == initial, "gathering conserves stock exactly")
		check(source._gather_remainder == 0, "whole seconds leave no fractional extraction debt")
		source.gather_rate_q = 1
		check(source.extract_fixed(Fixed.STEP_TIME) == 0, "sub-quantum rate accumulates rather than disappearing")
		var saved_amount: int = source.amount_q
		var saved_remainder: int = source._gather_remainder
		var first: int = 0
		for tick in 29: first += source.extract_fixed(Fixed.STEP_TIME)
		source.amount_q = saved_amount
		source._gather_remainder = saved_remainder
		var replay: int = 0
		for tick in 29: replay += source.extract_fixed(Fixed.STEP_TIME)
		check(first == 1 and replay == first, "restored fractional extraction resumes at identical tick")
		source.gather_rate = 100.0
		var before: int = source.amount_q
		var limited: int = source.extract_fixed(Fixed.STEP_TIME, 7)
		check(limited == 7 and source.amount_q == before - 7, "carrying capacity caps extraction in integer resource units")
		source.free()

func _test_unit_clock_and_health() -> void:
	var unit := UnitAgent.new()
	unit.def = GameCatalog.get_unit(&"villager")
	unit.hp = 100.0
	unit.match_state = MatchState.new()
	unit.match_state.setup_defaults()
	unit.match_state.lockstep_enabled = true
	unit.match_state.lockstep_stepping = true
	unit._attack_cooldown_remaining = 1.0
	unit._repath_cooldown = 1.0
	unit._goal_refresh_remaining = 1.0
	unit._path_retry_cooldown = 1.0
	for tick in 29: unit._physics_process(0.0001)
	check(unit._attack_cooldown_remaining_units == Fixed.STEP_TIME, "lockstep cooldown follows integer tick even with a different render delta")
	unit._physics_process(2.0)
	check(unit._attack_cooldown_remaining_units == 0 and unit._repath_cooldown_units == 0 and unit._goal_refresh_remaining_units == 0 and unit._path_retry_cooldown_units == 0, "all cooldowns expire exactly on tick 30")
	for hit in 10000: unit.take_damage_fixed(1)
	check(unit.hp_q == 100 * Fixed.SCALE - 10000, "repeated fractional damage does not drift")
	unit.free()

func _test_movement_budget_and_range() -> void:
	var unit := UnitAgent.new()
	var target := UnitAgent.new()
	unit.def = GameCatalog.get_unit(&"archer")
	unit.sim_pos = Vector2(-120, 117)
	var origin := Fixed.vector(unit.sim_pos)
	for offset in [Vector2(10, 4), Vector2(-10, -4), Vector2(0.3, -10), Vector2(0.0001, 0.0001)]:
		var position := unit._bounded_integer_step(unit.sim_pos, unit.sim_pos + offset, 137)
		check(Fixed.length_sq(Fixed.vector(position) - origin) <= 137 * 137, "quantized movement stays within its speed budget")
	target.sim_pos = unit.sim_pos + Vector2(unit.def.attack_range, 0)
	check(unit._in_attack_range(target), "exact maximum attack range is included")
	target._sim_pos_q.x += 1
	check(not unit._in_attack_range(target), "one coordinate quantum beyond attack range is excluded")
	unit.free()
	target.free()
