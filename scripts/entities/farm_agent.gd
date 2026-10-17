extends BuildingAgent

func extract(delta: float) -> float:
	if is_placement_ghost or not is_complete or hp <= 0 or amount <= 0 or has_meta("network_replica"): return 0.0
	var value := minf(amount, maxf(0,delta) * gather_rate)
	if value > 0.0:
		farm_has_crops = true
	amount -= value
	if amount <= 0.001:
		amount = 0.0
		AiEventBufferScript.push_for_entity({"type": AiProtocolScript.EVENT_RESOURCE_DEPLETED,
			"entity_id": EntityRegistryScript.id_of(self), "resource_type": "FOOD",
			"def_id": "farm", "pos": AiProtocolScript.vec2_to_array(sim_pos)}, self)
		# An exhausted farm is removed, so the same plot can be planted again.
		# The worker retains its carried food and follows the normal delivery path.
		remove_from_group("resource_nodes")
		queue_free()
	return value
