extends BuildingAgent

func extract(delta: float) -> float:
	return Fixed.to_float(extract_fixed(Fixed.delta_time(delta)))

@warning_ignore("integer_division")
func extract_fixed(time_units: int, capacity_q: int = 2147483647) -> int:
	if is_placement_ghost or not is_complete or hp_q <= 0 or amount_q <= 0 or time_units <= 0 or gather_rate_q <= 0 or capacity_q <= 0 or has_meta("network_replica"): return 0
	var numerator: int = gather_rate_q * time_units + _gather_remainder
	var value: int = mini(mini(amount_q, capacity_q), numerator / Fixed.TIME_SCALE)
	_gather_remainder = numerator % Fixed.TIME_SCALE
	if value > 0:
		farm_has_crops = true
	amount_q -= value
	if amount_q == 0:
		AiEventBufferScript.push_for_entity({"type": AiProtocolScript.EVENT_RESOURCE_DEPLETED,
			"entity_id": EntityRegistryScript.id_of(self), "resource_type": "FOOD",
			"def_id": "farm", "pos": AiProtocolScript.vec2_to_array(sim_pos)}, self)
		# An exhausted farm is removed, so the same plot can be planted again.
		# The worker retains its carried food and follows the normal delivery path.
		remove_from_group("resource_nodes")
		queue_free()
	return value
