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
		attacker_def.is_ranged,
		float(target.get("melee_armor")),
		float(target.get("pierce_armor"))
	)
	var damage := CombatMath.apply_armor(float(attacker_def.attack), armor)
	var source: Variant = context.get("attacker", null)
	if source != null:
		target.call("take_damage", damage, source)
	else:
		target.call("take_damage", damage)
	return damage
