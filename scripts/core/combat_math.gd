# scripts/core/combat_math.gd
class_name CombatMath
const Fixed := preload("res://scripts/core/sim_fixed.gd")

static func apply_armor_fixed(raw_damage: int, armor: int) -> int:
	return 0 if raw_damage <= 0 else maxi(Fixed.SCALE / 2, raw_damage - armor)

static func apply_armor(raw_damage: float, armor: float) -> float:
	return Fixed.to_float(apply_armor_fixed(Fixed.from_float(raw_damage), Fixed.from_float(armor)))

static func armor_for(
	is_ranged_attack: bool,
	melee_armor: float,
	pierce_armor: float
) -> float:
	return pierce_armor if is_ranged_attack else melee_armor
