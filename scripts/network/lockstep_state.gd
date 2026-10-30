extends RefCounted
## Versioned, allow-listed simulation state. No scripts, paths, object IDs or
## local configuration cross the wire. References use match-local net_id.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const VERSION := 2
const JobClock := preload("res://scripts/systems/age_progression.gd")
const UNIT_FIELDS := ["_sim_pos_q", "hp_q", "melee_armor_q", "pierce_armor_q", "order", "carry_type", "carry_amount_q", "carry_capacity_q", "vision_radius_override", "_move_target", "_formation_move_speed", "_gather_target", "_last_resource", "_drop_off_target", "_build_target", "_last_seen_resource_pos", "_last_seen_attack_pos", "_attack_target", "_attack_cooldown_remaining_units", "_gather_state", "_gather_resource_type", "_gather_source_depleted", "_gather_candidates", "_gather_work_points", "_automatic_gather_target", "_automatic_gather_goal", "_automatic_gather_resource_pos", "_population_registered", "_facing_dir", "_facing_flip", "_no_progress_frames", "_combat_action", "_combat_anim_time_units", "_attack_hit_applied", "_projectile_spawned", "max_hp_q", "_path", "_path_index", "_path_pending", "_nav_goal", "_stuck_repath_attempts", "_path_retry_cooldown_units", "_locomotion_velocity", "_avoidance_cache", "_stuck_seconds_units", "_repath_cooldown_units", "_requested_move_target", "_progress_elapsed_units", "_progress_distance", "_pending_crowd_route", "_path_is_crowd_route", "_has_move_command", "_goal_refresh_remaining_units", "_build_queue"]
const BUILDING_FIELDS := ["sim_pos", "hp_q", "melee_armor_q", "pierce_armor_q", "build_time_elapsed", "is_complete", "amount_q", "resource_type", "gather_rate_q", "farm_has_crops", "accepts_all_resources", "accepted_resource_type", "train_queue", "train_queue_ids", "_next_train_id", "_train_payments", "train_time_elapsed", "_construction_started", "_population_cap_registered", "_reserved_population", "spawn_retry_time", "_production_exit_blocked", "wall_orientation", "gate_state", "gate_open", "gate_time", "_last_gate_navigation", "_gather_remainder"]
const PROJECTILE_FIELDS := ["sim_pos", "aim_pos", "attacker_def", "attacker", "_consumed", "_origin", "_total_distance_fixed", "_traveled_fixed", "_impact_elapsed_time", "_stone", "_travel_remainder"]
const RESOURCE_FIELDS := ["sim_pos", "resource_type", "amount_q", "gather_rate_q", "block_size_override", "_gather_remainder"]
const TERRAIN_FIELDS := ["sim_pos", "kind", "block_size"]
const STATE_FIELDS := ["resources", "population", "population_cap", "population_reserved", "progression_enabled", "team_ages", "team_civilizations", "researched_technologies", "team_color_ids", "winner", "frozen"]

static func fields_for(kind: String) -> Array:
	match kind:
		"unit": return UNIT_FIELDS
		"building": return BUILDING_FIELDS
		"projectile": return PROJECTILE_FIELDS
		"resource": return RESOURCE_FIELDS
		"terrain": return TERRAIN_FIELDS
	return []

static func capture(network: Node) -> Dictionary:
	var records: Array = []
	var nodes: Dictionary = network.get("_net_entities")
	var ids: Array = nodes.keys()
	ids.sort()
	for id in ids:
		var node: Variant = nodes[id]
		if not is_instance_valid(node) or node.is_queued_for_deletion(): continue
		var kind: String = network.call("_entity_kind", node)
		var record := {"id": id, "kind": kind, "fields": _fields(node, fields_for(kind))}
		if node is UnitAgent or node is BuildingAgent:
			record["definition"] = String(node.def.id)
			record["team"] = int(node.team)
		elif node is ProjectileAgent: record["team"] = int(node.team)
		records.append(record)
	var state: MatchState = network.get("match_state")
	var root := network.get_parent()
	var data := {"version": VERSION, "next_id": int(network.get("_next_id")), "entities": records,
		"match": _fields(state, STATE_FIELDS), "age_jobs": [], "technology_jobs": [], "navigation": [], "support": {"elapsed_time": encode(0), "cooldowns": [], "healing": []}, "fog": []}
	if is_instance_valid(state.age_progression):
		for team in [0, 1]:
			if state.age_progression._jobs.has(team): data.age_jobs.append([team, encode(_job_state(state.age_progression._jobs[team]))])
	if is_instance_valid(state.technology_progression):
		for id in ids:
			var node: Variant = nodes[id]
			if not is_instance_valid(node): continue
			if state.technology_progression.jobs.has(node.get_instance_id()):
				var job: Dictionary = state.technology_progression.jobs[node.get_instance_id()].duplicate()
				job.erase("building_id")
				data.technology_jobs.append([id, encode(_job_state(job))])
	var nav := root.get_node_or_null("NavService")
	if nav != null and nav.nav != null:
		for request: Dictionary in nav.nav._pending_requests:
			var unit: Object = instance_from_id(int(request.id))
			if not is_instance_valid(unit) or unit.get_meta("net_id", 0) == 0: continue
			var record: Dictionary = request.duplicate()
			record.id = int(unit.get_meta("net_id"))
			data.navigation.append(encode(record))
		data["nav_repath"] = bool(nav._lockstep_repath)
	else: data["nav_repath"] = false
	var support := root.get_node_or_null("LandSupport")
	if support != null:
		support.sync_compatibility_state()
		data.support.elapsed_time = encode(int(support.elapsed_time))
		for id in ids:
			var node: Variant = nodes[id]
			if is_instance_valid(node) and support.cooldown_times.has(node.get_instance_id()):
				data.support.cooldowns.append([id, encode(int(support.cooldown_times[node.get_instance_id()]))])
			if is_instance_valid(node) and support.heal_remainders.has(node.get_instance_id()):
				data.support.healing.append([id, encode(int(support.heal_remainders[node.get_instance_id()]))])
	if state.fog != null:
		for team in [0, 1]:
			data.fog.append([Marshalls.raw_to_base64(state.fog.visible_now[team]), Marshalls.raw_to_base64(state.fog.explored[team])])
	return data

static func _job_state(job: Dictionary) -> Dictionary:
	var result := job.duplicate()
	JobClock._sync_job_clock(result)
	for key in ["elapsed", "duration", "progress"]: result.erase(key)
	return result

static func _fields(object: Object, names: Array) -> Dictionary:
	var result := {}
	for field in names: result[field] = encode(object.get(field))
	return result

static func encode(value: Variant) -> Variant:
	if value == null: return null
	if value is int: return ["i", value]
	if value is float:
		# Decimal JSON parsing can round a binary64 value by one ULP across
		# runtimes. Preserve the exact bits for deterministic continuation.
		return ["f", Marshalls.raw_to_base64(PackedFloat64Array([value]).to_byte_array())] if is_finite(value) else ["infinity", 1 if value > 0 else -1]
	if value is bool or value is String: return value
	if value is StringName: return ["s", String(value)]
	if value is Vector2i: return ["vi", value.x, value.y]
	if value is Vector2: return ["v", value.x, value.y]
	if value is PackedVector2Array:
		var points: Array = []
		for point in value: points.append([point.x, point.y])
		return ["p", points]
	if value is Node:
		return ["n", int(value.get_meta("net_id", 0))] if is_instance_valid(value) and not value.is_queued_for_deletion() else null
	if value is WeakRef:
		var node: Variant = value.get_ref()
		return ["w", int(node.get_meta("net_id", 0))] if is_instance_valid(node) and not node.is_queued_for_deletion() else ["w", 0]
	if value is UnitDef: return ["u", String(value.id)]
	if value is Array:
		var items: Array = []
		for item in value: items.append(encode(item))
		return ["a", items]
	if value is Dictionary:
		var entries: Array = []
		for key in value: entries.append([encode(key), encode(value[key])])
		entries.sort_custom(func(a: Array, b: Array): return JSON.stringify(a[0]) < JSON.stringify(b[0]))
		return ["d", entries]
	push_error("Unsupported lockstep state type: %s" % type_string(typeof(value)))
	return null

static func decode(value: Variant, nodes: Dictionary) -> Variant:
	if value is not Array: return value
	match value[0]:
		"i": return int(value[1])
		"f": return Marshalls.base64_to_raw(value[1]).decode_double(0)
		"infinity": return INF if value[1] > 0 else -INF
		"s": return StringName(value[1])
		"vi": return Vector2i(int(value[1]), int(value[2]))
		"v": return Vector2(value[1], value[2])
		"p":
			var points := PackedVector2Array()
			for point in value[1]: points.append(Vector2(point[0], point[1]))
			return points
		"n": return nodes.get(int(value[1]))
		"w": return weakref(nodes.get(int(value[1])))
		"u":
			var definition := Catalog.get_unit(StringName(value[1]))
			return definition if definition != null else Catalog.building_weapon(StringName(value[1]))
		"a":
			var result: Array = []
			for item in value[1]: result.append(decode(item, nodes))
			return result
		"d":
			var result := {}
			for pair in value[1]: result[decode(pair[0], nodes)] = decode(pair[1], nodes)
			return result
	return null

static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) < 1e15

static func valid_encoded(value: Variant, ids: Dictionary, depth := 0) -> bool:
	if depth > 12: return false
	if value == null or value is bool or value is String: return true
	if _number(value): return true
	if value is not Array or value.size() < 2 or value.size() > 3 or value[0] is not String: return false
	match value[0]:
		"i": return value.size() == 2 and _number(value[1]) and float(value[1]) == floorf(float(value[1]))
		"f":
			if value.size() != 2 or value[1] is not String or value[1].length() != 12: return false
			var bytes := Marshalls.base64_to_raw(value[1])
			return bytes.size() == 8 and Marshalls.raw_to_base64(bytes) == value[1] and is_finite(bytes.decode_double(0))
		"infinity": return value.size() == 2 and _number(value[1]) and absf(float(value[1])) == 1.0
		"s": return value.size() == 2 and value[1] is String
		"n", "w": return value.size() == 2 and _number(value[1]) and float(value[1]) == floorf(float(value[1])) and (value[1] == 0 or ids.has(int(value[1])))
		"u": return value.size() == 2 and value[1] is String and (Catalog.get_unit(StringName(value[1])) != null or Catalog.building_weapon(StringName(value[1])) != null)
		"vi": return value.size() == 3 and _number(value[1]) and _number(value[2]) and value[1] == int(value[1]) and value[2] == int(value[2]) and absi(int(value[1])) <= 2147483647 and absi(int(value[2])) <= 2147483647
		"v": return value.size() == 3 and _number(value[1]) and _number(value[2])
		"p":
			if value.size() != 2 or value[1] is not Array or value[1].size() > 16384: return false
			for point in value[1]:
				if point is not Array or point.size() != 2 or not _number(point[0]) or not _number(point[1]): return false
			return true
		"a":
			if value.size() != 2 or value[1] is not Array or value[1].size() > 4096: return false
			for item in value[1]:
				if not valid_encoded(item, ids, depth + 1): return false
			return true
		"d":
			if value.size() != 2 or value[1] is not Array or value[1].size() > 4096: return false
			var keys := {}
			for pair in value[1]:
				if pair is not Array or pair.size() != 2 or not valid_encoded(pair[0], ids, depth + 1) or not valid_encoded(pair[1], ids, depth + 1): return false
				if pair[0] is not String and not _tag(pair[0], "i") and not _tag(pair[0], "s"): return false
				var key := JSON.stringify(pair[0])
				if keys.has(key): return false
				keys[key] = true
			return true
	return false

static func validate(data: Variant, world: Dictionary) -> bool:
	if data is not Dictionary or int(data.get("version", -1)) != VERSION or not _number(data.get("next_id")) or data.next_id < 1: return false
	if data.get("entities") is not Array or data.get("match") is not Dictionary: return false
	var ids := {}
	for record in world.get("entities", []):
		if record is not Dictionary or not _number(record.get("id")): return false
		ids[int(record.id)] = String(record.get("kind", ""))
	if data.entities.size() != ids.size(): return false
	var seen := {}
	for record in data.entities:
		if record is not Dictionary or not _number(record.get("id")) or not ids.has(int(record.id)) or seen.has(int(record.id)) or record.get("kind") != ids[int(record.id)]: return false
		if record.id >= data.next_id: return false
		seen[int(record.id)] = true
		if not _valid_fields(record.get("fields"), fields_for(record.kind), ids): return false
	if not _valid_fields(data.match, STATE_FIELDS, ids): return false
	for name in ["age_jobs", "technology_jobs", "navigation"]:
		if data.get(name) is not Array or data[name].size() > 2000: return false
	for job in data.age_jobs:
		if job is not Array or job.size() != 2 or not _number(job[0]) or float(job[0]) != floorf(float(job[0])) or int(job[0]) not in [0, 1] or not valid_encoded(job[1], ids): return false
	for job in data.technology_jobs:
		if job is not Array or job.size() != 2 or not _number(job[0]) or ids.get(int(job[0])) != "building" or not valid_encoded(job[1], ids): return false
	for request in data.navigation:
		if not valid_encoded(request, ids): return false
	if data.get("nav_repath") is not bool or data.get("support") is not Dictionary or not _tag(data.support.get("elapsed_time"), "i") or not valid_encoded(data.support.get("elapsed_time"), ids) or data.support.get("cooldowns") is not Array or data.support.get("healing") is not Array: return false
	for item in data.support.cooldowns + data.support.healing:
		if item is not Array or item.size() != 2 or not _number(item[0]) or not ids.has(int(item[0])) or not _tag(item[1], "i") or not valid_encoded(item[1], ids): return false
	if data.get("fog") is not Array or data.fog.size() not in [0, 2]: return false
	for masks in data.fog:
		if masks is not Array or masks.size() != 2: return false
		for mask in masks:
			if mask is not String or mask.length() > 90000: return false
	return true

static func _tag(value: Variant, tag: String) -> bool:
	return value is Array and value.size() >= 2 and value[0] == tag

static func _valid_field_type(field: String, value: Variant) -> bool:
	if field == "_sim_pos_q": return _tag(value, "vi")
	if field in ["hp_q", "melee_armor_q", "pierce_armor_q", "carry_amount_q", "carry_capacity_q", "max_hp_q", "amount_q", "gather_rate_q", "build_time_elapsed", "train_time_elapsed", "spawn_retry_time", "gate_time", "_total_distance_fixed", "_traveled_fixed", "_impact_elapsed_time", "_attack_cooldown_remaining_units", "_combat_anim_time_units", "_path_retry_cooldown_units", "_stuck_seconds_units", "_repath_cooldown_units", "_progress_elapsed_units", "_goal_refresh_remaining_units", "_gather_remainder", "_travel_remainder"]: return _tag(value, "i")
	if field in ["sim_pos", "_move_target", "_last_seen_resource_pos", "_last_seen_attack_pos", "_automatic_gather_goal", "_automatic_gather_resource_pos", "_nav_goal", "_locomotion_velocity", "_requested_move_target", "_last_gate_navigation", "aim_pos", "_origin", "block_size_override", "block_size"]: return _tag(value, "v")
	if field in ["_gather_target", "_last_resource", "_drop_off_target", "_build_target", "_attack_target", "attacker"]: return value == null or _tag(value, "n")
	if field in ["_gather_work_points", "_path"]: return _tag(value, "p")
	if field in ["_gather_candidates", "_build_queue", "train_queue", "train_queue_ids"]: return _tag(value, "a")
	if field in ["_avoidance_cache", "_train_payments", "resources", "population", "population_cap", "population_reserved", "team_ages", "team_civilizations", "researched_technologies", "team_color_ids"]: return _tag(value, "d")
	if field in ["_gather_source_depleted", "_automatic_gather_target", "_population_registered", "_facing_flip", "_attack_hit_applied", "_projectile_spawned", "_path_pending", "_pending_crowd_route", "_path_is_crowd_route", "_has_move_command", "is_complete", "farm_has_crops", "accepts_all_resources", "_construction_started", "_population_cap_registered", "_production_exit_blocked", "gate_open", "_consumed", "_stone", "progression_enabled", "frozen"]: return value is bool
	if field in ["order", "carry_type", "_gather_resource_type", "_facing_dir", "_no_progress_frames", "_path_index", "_stuck_repath_attempts", "resource_type", "accepted_resource_type", "_next_train_id", "_reserved_population", "wall_orientation", "winner"]: return _tag(value, "i")
	if field in ["_gather_state", "gate_state"]: return value is String
	if field in ["_combat_action", "kind"]: return _tag(value, "s")
	if field == "attacker_def": return _tag(value, "u")
	if field == "_progress_distance" and _tag(value, "infinity"): return true
	return _tag(value, "f")

static func _valid_fields(value: Variant, names: Array, ids: Dictionary) -> bool:
	if value is not Dictionary or value.size() != names.size(): return false
	for field in names:
		if not value.has(field) or not valid_encoded(value[field], ids) or not _valid_field_type(field, value[field]): return false
	return true

static func restore(network: Node, data: Dictionary) -> bool:
	var nodes: Dictionary = network.get("_net_entities")
	var state: MatchState = network.get("match_state")
	for record in data.entities:
		var node: Node = nodes.get(int(record.id))
		if node == null: return false
		_apply_fields(node, record.fields, nodes)
		if node.has_meta("network_replica"): node.remove_meta("network_replica")
		node.set_meta("lockstep_entity", true)
		node.set_physics_process(false)
		if node is BuildingAgent:
			node.set_process(false)
			node._sync_block_half()
	_apply_fields(state, data.match, nodes)
	network.set("_next_id", int(data.next_id))
	if is_instance_valid(state.age_progression):
		state.age_progression.network_replica = false
		state.age_progression._jobs.clear()
		for job in data.age_jobs:
			var restored: Dictionary = decode(job[1], nodes)
			JobClock._sync_job_clock(restored)
			state.age_progression._jobs[int(job[0])] = restored
	if is_instance_valid(state.technology_progression):
		state.technology_progression.replica = false
		state.technology_progression.jobs.clear()
		for item in data.technology_jobs:
			var job: Dictionary = decode(item[1], nodes)
			var building: Node = nodes[int(item[0])]
			JobClock._sync_job_clock(job)
			job.progress = float(job.elapsed_time) / maxi(1, int(job.duration_time))
			job.building_id = building.get_instance_id()
			state.technology_progression.jobs[building.get_instance_id()] = job
	var root := network.get_parent()
	var nav := root.get_node_or_null("NavService")
	if nav != null and nav.nav != null:
		nav._last_building_check_frame = -1
		nav.rebuild_from_scene()
		nav._lockstep_repath = data.nav_repath
		nav.nav._pending_requests.clear()
		for record in data.navigation:
			var request: Dictionary = decode(record, nodes)
			var unit: Node = nodes.get(int(request.id))
			if unit == null: return false
			request.id = unit.get_instance_id()
			nav.nav._pending_requests.append(request)
	var vision := root.get_node_or_null("VisionService")
	if vision != null: vision.rebuild_from_scene()
	var support := root.get_node_or_null("LandSupport")
	if support != null:
		support.elapsed_time = int(decode(data.support.elapsed_time, nodes))
		support.cooldown_times.clear()
		support.heal_remainders.clear()
		for item in data.support.cooldowns: support.cooldown_times[nodes[int(item[0])].get_instance_id()] = int(decode(item[1], nodes))
		for item in data.support.healing: support.heal_remainders[nodes[int(item[0])].get_instance_id()] = int(decode(item[1], nodes))
		support.refresh_compatibility_state()
	if state.fog != null and data.fog.size() == 2:
		var cells: int = state.fog.grid_size.x * state.fog.grid_size.y
		for team in [0, 1]:
			var visible_mask := Marshalls.base64_to_raw(data.fog[team][0])
			var explored_mask := Marshalls.base64_to_raw(data.fog[team][1])
			if visible_mask.size() != cells or explored_mask.size() != cells: return false
			state.fog.visible_now[team] = visible_mask
			state.fog.explored[team] = explored_mask
		state.fog.dirty = true
		state.fog.revision += 1
	return true

static func _apply_fields(object: Object, fields: Dictionary, nodes: Dictionary) -> void:
	for field in fields:
		var value: Variant = decode(fields[field], nodes)
		var current: Variant = object.get(field)
		if current is Array and value is Array: current.assign(value)
		else: object.set(field, value)
