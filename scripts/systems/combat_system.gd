class_name CombatSystem
extends RefCounted

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
	var damage := CombatMath.apply_armor(float(attacker_def.attack), armor)
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
			damage += maxf(0.0, float(attacker_def.attack_class_bonuses[armor_class]) - float(class_armors[armor_class]))
	damage *= clampf(float(context.get("damage_multiplier", 1.0)), 0.0, 1.0)
	var source: Variant = context.get("attacker", null)
	if is_instance_valid(source) and not source.is_queued_for_deletion():
		target.call("take_damage", damage, source)
	else:
		target.call("take_damage", damage)
	return damage
