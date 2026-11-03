extends RefCounted
## Versioned, allow-listed simulation state. No scripts, paths, object IDs or
## local configuration cross the wire. References use match-local net_id.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const VERSION := 3
const JSON_INTEGER_LIMIT := 1000000000000000
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const JobClock := preload("res://scripts/systems/age_progression.gd")
const UNIT_FIELDS := ["_sim_pos_q", "hp_q", "melee_armor_q", "pierce_armor_q", "order", "carry_type", "carry_amount_q", "carry_capacity_q", "vision_radius_override", "_move_target", "_formation_move_speed", "_gather_target", "_last_resource", "_drop_off_target", "_build_target", "_last_seen_resource_pos", "_last_seen_attack_pos", "_attack_target", "_attack_cooldown_remaining_units", "_gather_state", "_gather_resource_type", "_gather_source_depleted", "_gather_candidates", "_gather_work_points", "_automatic_gather_target", "_automatic_gather_goal", "_automatic_gather_resource_pos", "_population_registered", "_no_progress_frames", "_combat_action", "_combat_anim_time_units", "_attack_hit_applied", "_projectile_spawned", "max_hp_q", "_path", "_path_index", "_path_pending", "_nav_goal", "_stuck_repath_attempts", "_path_retry_cooldown_units", "_locomotion_velocity", "_avoidance_cache", "_stuck_seconds_units", "_repath_cooldown_units", "_requested_move_target", "_progress_elapsed_units", "_progress_distance", "_pending_crowd_route", "_path_is_crowd_route", "_has_move_command", "_goal_refresh_remaining_units", "_build_queue"]
const BUILDING_FIELDS := ["sim_pos", "hp_q", "melee_armor_q", "pierce_armor_q", "build_time_elapsed", "is_complete", "amount_q", "resource_type", "gather_rate_q", "farm_has_crops", "accepts_all_resources", "accepted_resource_type", "train_queue", "train_queue_ids", "_next_train_id", "_train_payments", "train_time_elapsed", "_construction_started", "_population_cap_registered", "_reserved_population", "spawn_retry_time", "_production_exit_blocked", "wall_orientation", "gate_state", "gate_open", "gate_time", "_last_gate_navigation", "_gather_remainder"]
const PROJECTILE_FIELDS := ["sim_pos", "aim_pos", "attacker_def", "attacker", "_consumed", "_origin", "_total_distance_fixed", "_traveled_fixed", "_impact_elapsed_time", "_stone", "_travel_remainder"]
const RESOURCE_FIELDS := ["sim_pos", "resource_type", "amount_q", "gather_rate_q", "block_size_override", "_gather_remainder"]
const TERRAIN_FIELDS := ["sim_pos", "kind", "block_size", "water_contours"]
const STATE_FIELDS := ["resources", "population", "population_cap", "population_reserved", "progression_enabled", "team_ages", "team_civilizations", "researched_technologies", "team_color_ids", "winner", "frozen"]

static func fields_for(kind: String) -> Array:
	match kind:
		"unit": return UNIT_FIELDS
		"building": return BUILDING_FIELDS
		"projectile": return PROJECTILE_FIELDS
		"resource": return RESOURCE_FIELDS
		"terrain": return TERRAIN_FIELDS
	return []

## The keyframe payload. full_digest() hashes the same state for the periodic
## exhaustive frame check; a field or section added here must be added there.
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
	if value is int:
		# Godot parses JSON numbers as doubles. The native steering cache can
		# contain 1 << 60; keep every int64 bit across a JSON relay round trip.
		return ["i", str(value)] if value <= -JSON_INTEGER_LIMIT or value >= JSON_INTEGER_LIMIT else ["i", value]
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

static func _integer_payload(value: Variant) -> bool:
	if value is String:
		if value.length() > 20 or not value.is_valid_int(): return false
		var parsed: int = value.to_int()
		return str(parsed) == value and (parsed <= -JSON_INTEGER_LIMIT or parsed >= JSON_INTEGER_LIMIT)
	return _number(value) and float(value) == floorf(float(value))

static func valid_encoded(value: Variant, ids: Dictionary, depth := 0) -> bool:
	if depth > 12: return false
	if value == null or value is bool or value is String: return true
	if _number(value): return true
	if value is not Array or value.size() < 2 or value.size() > 3 or value[0] is not String: return false
	match value[0]:
		"i": return value.size() == 2 and _integer_payload(value[1])
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
	if field == "water_contours":
		if not _tag(value, "a"): return false
		# valid_encoded already checked the point pair shape. Disallow other
		# element types before assigning the typed array on an existing actor.
		for loop in value[1]:
			if not _tag(loop, "p") or loop[1].size() < 3: return false
			for point in loop[1]:
				for coordinate in point:
					if absf(float(coordinate)) > 10000.0 or float(coordinate) * Fixed.SCALE != roundf(float(coordinate) * Fixed.SCALE): return false
		return true
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
		if node is PathBlocker and node.kind == &"water":
			node.apply_authoritative_water_contours(node.water_contours)
		if node.has_meta("network_replica"):
			node.remove_meta("network_replica")
			# Snapshot replicas disabled interpolation because they jumped to
			# each snapshot. Restored actors now move on simulation ticks.
			if node is UnitAgent or node is ProjectileAgent:
				node.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT
				node.reset_physics_interpolation()
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


## Per-frame consistency digest. capture() above is the exhaustive keyframe
## format (and the deep test checksum); building that Variant tree, sorting
## every dictionary and serializing ~0.5 MB of JSON on every 100 ms frame cost
## more than the three simulation steps it verified. This digest walks the same
## entities in net_id order and feeds the authoritative gameplay values
## (positions, health, orders, targets, timers, production, economy, research,
## navigation backlog and fog) through native packed arrays into SHA-256.
## Divergent hidden state is still caught once it changes any of these, and at
## the next whole simulated second, when frame_checksum() hashes everything
## with full_digest(); a mismatch repairs from the exhaustive keyframe.
static func digest(network: Node) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	var ints := PackedInt64Array()
	var floats := PackedFloat64Array()
	var nodes: Dictionary = network.get("_net_entities")
	var ids: Array = nodes.keys()
	ids.sort()
	ints.append(VERSION)
	ints.append(int(network.get("_next_id")))
	for id in ids:
		var node: Variant = nodes[id]
		if not is_instance_valid(node) or node.is_queued_for_deletion(): continue
		ints.append(id)
		if node is UnitAgent:
			_digest_unit(node, ints, floats, context)
		elif node is BuildingAgent:
			_digest_building(node, ints, floats)
		elif node is ProjectileAgent:
			var projectile: ProjectileAgent = node
			ints.append(-4)
			ints.append(projectile.team)
			floats.append(projectile.sim_pos.x)
			floats.append(projectile.sim_pos.y)
			floats.append(projectile.aim_pos.x)
			floats.append(projectile.aim_pos.y)
			ints.append(projectile._traveled_fixed)
			ints.append(projectile._total_distance_fixed)
			ints.append(projectile._impact_elapsed_time)
			ints.append(projectile._travel_remainder)
			ints.append(int(projectile._consumed))
			ints.append(int(projectile._stone))
			ints.append(_ref(projectile.attacker))
		elif node is ResourceNode:
			var resource: ResourceNode = node
			ints.append(-3)
			ints.append(resource.amount_q)
			ints.append(resource._gather_remainder)
		else:
			ints.append(-5) # Terrain blockers never change after map load.
	var state: MatchState = network.get("match_state")
	ints.append(-6)
	for field in ["resources", "population", "population_cap", "population_reserved", "team_ages", "researched_technologies", "winner", "frozen", "progression_enabled"]:
		_mix(state.get(field), ints, floats)
	if is_instance_valid(state.age_progression):
		for team in [0, 1]:
			if state.age_progression._jobs.has(team):
				ints.append(team)
				_mix(_job_state(state.age_progression._jobs[team]), ints, floats)
	if is_instance_valid(state.technology_progression):
		ints.append(-7)
		for id in ids:
			var node: Variant = nodes[id]
			if is_instance_valid(node) and state.technology_progression.jobs.has(node.get_instance_id()):
				var job: Dictionary = state.technology_progression.jobs[node.get_instance_id()].duplicate()
				job.erase("building_id")
				ints.append(id)
				_mix(_job_state(job), ints, floats)
	var root := network.get_parent()
	var nav := root.get_node_or_null("NavService") if root != null else null
	if nav != null and nav.nav != null:
		ints.append(-8)
		ints.append(int(nav._lockstep_repath))
		for request: Dictionary in nav.nav._pending_requests:
			var unit: Object = instance_from_id(int(request.id))
			ints.append(int(unit.get_meta("net_id", 0)) if is_instance_valid(unit) else 0)
	var support := root.get_node_or_null("LandSupport") if root != null else null
	if support != null:
		ints.append(-9)
		ints.append(int(support.elapsed_time))
		for id in ids:
			var node: Variant = nodes[id]
			if not is_instance_valid(node): continue
			var key: int = node.get_instance_id()
			if support.cooldown_times.has(key) or support.heal_remainders.has(key):
				ints.append(id)
				ints.append(int(support.cooldown_times.get(key, -1)))
				ints.append(int(support.heal_remainders.get(key, -1)))
	context.update(ints.to_byte_array())
	context.update(floats.to_byte_array())
	if state.fog != null:
		for team in [0, 1]:
			context.update(state.fog.visible_now[team])
			context.update(state.fog.explored[team])
	return context.finish().hex_encode()

static func _digest_unit(unit: UnitAgent, ints: PackedInt64Array, floats: PackedFloat64Array, context: HashingContext) -> void:
	ints.append(-1)
	ints.append(String(unit.def.id).hash() if unit.def != null else 0)
	ints.append(unit.team)
	ints.append(unit._sim_pos_q.x)
	ints.append(unit._sim_pos_q.y)
	ints.append(unit.hp_q)
	ints.append(unit.max_hp_q)
	ints.append(unit.melee_armor_q)
	ints.append(unit.pierce_armor_q)
	ints.append(unit.order)
	ints.append(unit.carry_type)
	ints.append(unit.carry_amount_q)
	ints.append(unit.carry_capacity_q)
	ints.append(unit._attack_cooldown_remaining_units)
	ints.append(unit._combat_anim_time_units)
	ints.append(unit._stuck_seconds_units)
	ints.append(unit._repath_cooldown_units)
	ints.append(unit._goal_refresh_remaining_units)
	ints.append(unit._path_retry_cooldown_units)
	ints.append(unit._progress_elapsed_units)
	ints.append(unit._no_progress_frames)
	ints.append(unit._stuck_repath_attempts)
	ints.append(unit._path_index)
	ints.append(unit._path.size())
	ints.append(unit._gather_resource_type)
	ints.append(unit._gather_work_points.size())
	ints.append(unit._build_queue.size())
	ints.append(int(unit._path_pending) | int(unit._attack_hit_applied) << 1 | int(unit._projectile_spawned) << 2 | int(unit._has_move_command) << 3 | int(unit._gather_source_depleted) << 4 | int(unit._path_is_crowd_route) << 5 | int(unit._pending_crowd_route) << 6)
	ints.append(unit._gather_state.hash())
	ints.append(String(unit._combat_action).hash())
	ints.append(_ref(unit._attack_target))
	ints.append(_ref(unit._gather_target))
	ints.append(_ref(unit._build_target))
	ints.append(_ref(unit._drop_off_target))
	ints.append(_ref(unit._last_resource))
	floats.append(unit._move_target.x)
	floats.append(unit._move_target.y)
	floats.append(unit._locomotion_velocity.x)
	floats.append(unit._locomotion_velocity.y)
	floats.append(unit._formation_move_speed)
	floats.append(unit._progress_distance)
	if not unit._path.is_empty():
		context.update(unit._path.to_byte_array())

static func _digest_building(building: BuildingAgent, ints: PackedInt64Array, floats: PackedFloat64Array) -> void:
	ints.append(-2)
	ints.append(String(building.def.id).hash() if building.def != null else 0)
	ints.append(building.team)
	floats.append(building.sim_pos.x)
	floats.append(building.sim_pos.y)
	ints.append(building.hp_q)
	ints.append(building.build_time_elapsed)
	ints.append(building.amount_q)
	ints.append(building.train_time_elapsed)
	ints.append(building._next_train_id)
	ints.append(building.gate_time)
	ints.append(building.spawn_retry_time)
	ints.append(building._reserved_population)
	ints.append(building._gather_remainder)
	ints.append(building.wall_orientation)
	ints.append(building.gate_state.hash())
	ints.append(int(building.is_complete) | int(building.gate_open) << 1 | int(building.farm_has_crops) << 2 | int(building._construction_started) << 3 | int(building._population_cap_registered) << 4 | int(building._production_exit_blocked) << 5)
	ints.append(building.train_queue.size())
	for definition in building.train_queue:
		ints.append(String(definition.id).hash() if definition != null else 0)
	for queue_id in building.train_queue_ids:
		ints.append(queue_id)
	ints.append(building._train_payments.size())

## Targets may already be freed; validity first ('is' on a freed instance errors).
static func _ref(value: Variant) -> int:
	if is_instance_valid(value) and value is Node and not value.is_queued_for_deletion():
		return int(value.get_meta("net_id", 0))
	return 0

## Small match-level containers only (economy, ages, research, job clocks).
static func _mix(value: Variant, ints: PackedInt64Array, floats: PackedFloat64Array) -> void:
	match typeof(value):
		TYPE_NIL: ints.append(-11)
		TYPE_BOOL: ints.append(1 if value else 0)
		TYPE_INT: ints.append(value)
		TYPE_FLOAT: floats.append(value)
		TYPE_STRING, TYPE_STRING_NAME: ints.append(String(value).hash())
		TYPE_VECTOR2I:
			ints.append(value.x)
			ints.append(value.y)
		TYPE_VECTOR2:
			floats.append(value.x)
			floats.append(value.y)
		TYPE_ARRAY:
			ints.append(-12)
			ints.append(value.size())
			for item in value: _mix(item, ints, floats)
		TYPE_DICTIONARY:
			ints.append(-13)
			ints.append(value.size())
			var keys: Array = value.keys()
			keys.sort_custom(func(a: Variant, b: Variant): return var_to_str(a) < var_to_str(b))
			for key in keys:
				_mix(key, ints, floats)
				_mix(value[key], ints, floats)
		TYPE_OBJECT:
			if not is_instance_valid(value): ints.append(0)
			elif value is Node: ints.append(_ref(value))
			elif value.get("id") != null: ints.append(String(value.get("id")).hash())
			else: ints.append(-14)
		_:
			ints.append(-15 - typeof(value))


## Exhaustive digest: SHA-256 over the same state as capture(), without
## building wire records or JSON. capture() stays the keyframe payload; this
## digest only has to agree between peers and change whenever capture() would
## (tests/run_lockstep_digest.gd). frame_checksum() uses it at every whole
## simulated second; digest() below covers the frames in between. Values are hashed in their binary
## Variant form (var_to_bytes), mapped as encode() maps them: references become
## net IDs, dictionaries are ordered by key, non-finite floats keep encode()'s
## two classes, and Vector2 zero signs are dropped as capture()'s decimal JSON
## drops them. Any change here must keep the two in step.
static func full_digest(network: Node) -> String:
	var nodes: Dictionary = network.get("_net_entities")
	var ids: Array = nodes.keys()
	ids.sort()
	var entities: Array = []
	for id in ids:
		var node: Variant = nodes[id]
		if not is_instance_valid(node) or node.is_queued_for_deletion(): continue
		var kind: String = network.call("_entity_kind", node)
		var row: Array = [id, kind]
		if node is UnitAgent or node is BuildingAgent:
			row.append(String(node.def.id))
			row.append(int(node.team))
		elif node is ProjectileAgent: row.append(int(node.team))
		for field: StringName in _field_names(kind):
			var value: Variant = node.get(field)
			var type := typeof(value)
			# Most fields are plain scalars; keep them off the generic path.
			if type == TYPE_INT or type == TYPE_BOOL or type == TYPE_NIL or type == TYPE_STRING or type == TYPE_STRING_NAME or type == TYPE_VECTOR2I: row.append(value)
			elif type == TYPE_VECTOR2: row.append(value + Vector2.ZERO)
			# Idle queues and caches: the same result as _digestible, no call.
			elif type == TYPE_ARRAY and value.is_empty(): row.append(_empty_array)
			elif type == TYPE_DICTIONARY and value.is_empty(): row.append(_empty_dictionary)
			else: row.append(_digestible(value))
		entities.append(row)
	var state: MatchState = network.get("match_state")
	var root := network.get_parent()
	var match_fields: Array = []
	for field in STATE_FIELDS: match_fields.append(_digestible(state.get(field)))
	var age_jobs: Array = []
	if is_instance_valid(state.age_progression):
		for team in [0, 1]:
			if state.age_progression._jobs.has(team): age_jobs.append([team, _digestible(_job_state(state.age_progression._jobs[team]))])
	var technology_jobs: Array = []
	if is_instance_valid(state.technology_progression):
		for id in ids:
			var node: Variant = nodes[id]
			if not is_instance_valid(node): continue
			if state.technology_progression.jobs.has(node.get_instance_id()):
				var job: Dictionary = state.technology_progression.jobs[node.get_instance_id()].duplicate()
				job.erase("building_id")
				technology_jobs.append([id, _digestible(_job_state(job))])
	var navigation: Array = []
	var nav_repath := false
	var nav := root.get_node_or_null("NavService")
	if nav != null and nav.nav != null:
		for request: Dictionary in nav.nav._pending_requests:
			var unit: Object = instance_from_id(int(request.id))
			if not is_instance_valid(unit) or unit.get_meta("net_id", 0) == 0: continue
			var record: Dictionary = request.duplicate()
			record.id = int(unit.get_meta("net_id"))
			navigation.append(_digestible(record))
		nav_repath = bool(nav._lockstep_repath)
	var support_state: Array = [0, [], []]
	var support := root.get_node_or_null("LandSupport")
	if support != null:
		support.sync_compatibility_state()
		support_state[0] = int(support.elapsed_time)
		for id in ids:
			var node: Variant = nodes[id]
			if is_instance_valid(node) and support.cooldown_times.has(node.get_instance_id()):
				support_state[1].append([id, int(support.cooldown_times[node.get_instance_id()])])
			if is_instance_valid(node) and support.heal_remainders.has(node.get_instance_id()):
				support_state[2].append([id, int(support.heal_remainders[node.get_instance_id()])])
	var fog: Array = []
	if state.fog != null:
		for team in [0, 1]: fog.append_array([state.fog.visible_now[team], state.fog.explored[team]])
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(var_to_bytes([VERSION, int(network.get("_next_id")), entities, match_fields, age_jobs, technology_jobs, navigation, nav_repath, support_state, fog]))
	return hashing.finish().hex_encode()

static var _names_by_kind := {}

static func _field_names(kind: String) -> Array:
	if not _names_by_kind.has(kind): _names_by_kind[kind] = fields_for(kind).map(func(name: String): return StringName(name))
	return _names_by_kind[kind]

## encode() for the digest: the same value classes, as hashable Variants.
## Marker types (packed arrays) never occur as state values, so a reference or
## a dictionary cannot be confused with a plain value or an array.
static func _digestible(value: Variant) -> Variant:
	if value == null: return null
	match typeof(value):
		TYPE_INT, TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2I: return value
		TYPE_FLOAT: return value if is_finite(value) else (INF if value > 0 else -INF)
		TYPE_VECTOR2: return value + Vector2.ZERO
		TYPE_PACKED_VECTOR2_ARRAY:
			var points := PackedVector2Array(value)
			for index in points.size(): points[index] += Vector2.ZERO
			return points
		TYPE_ARRAY:
			var items: Array = []
			for item in value:
				var type := typeof(item)
				if type == TYPE_INT or type == TYPE_BOOL or type == TYPE_STRING or type == TYPE_STRING_NAME or type == TYPE_VECTOR2I: items.append(item)
				elif type == TYPE_VECTOR2: items.append(item + Vector2.ZERO)
				else: items.append(_digestible(item))
			return items
		TYPE_DICTIONARY:
			var entries: Array = []
			for key in value:
				var digest_key: Variant = _digestible(key)
				var digest_value: Variant = _digestible(value[key])
				entries.append([var_to_bytes(digest_key).hex_encode() + ":" + var_to_bytes(digest_value).hex_encode(), digest_key, digest_value])
			entries.sort_custom(func(a: Array, b: Array): return a[0] < b[0])
			var flat: Array = [_dictionary_marker]
			for entry in entries: flat.append_array([entry[1], entry[2]])
			return flat
	if value is Node:
		return PackedInt64Array([1, int(value.get_meta("net_id", 0))]) if is_instance_valid(value) and not value.is_queued_for_deletion() else null
	if value is WeakRef:
		var node: Variant = value.get_ref()
		return PackedInt64Array([2, int(node.get_meta("net_id", 0)) if is_instance_valid(node) and not node.is_queued_for_deletion() else 0])
	if value is UnitDef: return PackedStringArray(["u", String(value.id)])
	push_error("Unsupported lockstep state type: %s" % type_string(typeof(value)))
	return null

static var _dictionary_marker := PackedByteArray([100])
static var _empty_array: Array = []
static var _empty_dictionary: Array = [_dictionary_marker]
