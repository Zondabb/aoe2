# tests/test_combat_math.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var d := CombatMath.apply_armor(10.0, 2.0)
	if not is_equal_approx(d, 8.0):
		failures.append("expected 8 got %s" % d)
	var chip := CombatMath.apply_armor(1.0, 5.0)
	if not is_equal_approx(chip, 0.5):
		failures.append("expected chip 0.5 got %s" % chip)
	var zero := CombatMath.apply_armor(0.0, 5.0)
	if not is_equal_approx(zero, 0.0):
		failures.append("expected 0 got %s" % zero)
	return failures
