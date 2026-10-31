class_name CombatSystem
extends RefCounted
const Fixed := preload("res://scripts/core/sim_fixed.gd")

## Applies armor-reduced damage. Optional context["attacker"] enables idle retaliation.
static func apply_hit(attacker_def: UnitDef, target: Node, context: Dictionary = {}) -> float:
	if (
		attacker_def == null
		or not is_instance_valid(target)
		or not target.has_method("take_damage")
	):
		return 0.0
	var armor := CombatMath.armor_for(
		attacker_def.is_ranged and not attacker_def.attack_uses_melee_armor,
		float(target.get("melee_armor")),
		float(target.get("pierce_armor"))
	)
	var damage_fixed := CombatMath.apply_armor_fixed(Fixed.from_float(attacker_def.attack), Fixed.from_float(armor))
	if not attacker_def.attack_class_bonuses.is_empty():
		var target_def: Resource = target.get("def")
		var record: Dictionary = {}
		if target_def is UnitDef:
			record = GameCatalog.unit_record(target_def.id)
		elif target_def is BuildingDef:
			record = GameCatalog.building_record(target_def.id)
		var class_armors: Dictionary = record.get("source_armors", {})
		for armor_class in attacker_def.attack_class_bonuses:
			if armor_class in ["UNITS_MELEE", "UNITS_PIERCE"] or not class_armors.has(armor_class):
				continue
			damage_fixed += maxi(0, Fixed.from_float(float(attacker_def.attack_class_bonuses[armor_class])) - Fixed.from_float(float(class_armors[armor_class])))
	var multiplier: int = int(context.get("damage_multiplier_fixed", Fixed.from_float(float(context.get("damage_multiplier", 1.0)))))
	damage_fixed = Fixed.mul(damage_fixed, clampi(multiplier, 0, Fixed.SCALE))
	var source: Variant = context.get("attacker", null)
	if not is_instance_valid(source) or source.is_queued_for_deletion(): source = null
	if target.has_method("take_damage_fixed"):
		target.call("take_damage_fixed", damage_fixed, source)
	elif source != null:
		target.call("take_damage", Fixed.to_float(damage_fixed), source)
	else:
		target.call("take_damage", Fixed.to_float(damage_fixed))
	return Fixed.to_float(damage_fixed)
