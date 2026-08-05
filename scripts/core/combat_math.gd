# scripts/core/combat_math.gd
class_name CombatMath
static func apply_armor(raw_damage: float, armor: float) -> float:
	if raw_damage <= 0.0:
		return 0.0
	return maxf(0.5, raw_damage - armor)
