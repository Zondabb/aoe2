extends SceneTree
## The exhaustive lockstep digest (LockstepState.full_digest) must notice exactly
## the state changes the original checksum did: SHA-256 of capture() as JSON.
## Every field of sampled units, buildings, resources, terrain and projectiles
## is changed and restored, then the match, job, navigation, support and fog
## sections; both must change together and agree after restoring. Frames carry
## the compact digest except at whole simulated seconds, which carry this one.
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const State := preload("res://scripts/network/lockstep_state.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
var checks := 0
var failures := 0
var runtime: Node
var sim: RefCounted
var base_old := ""
var base_new := ""
var mutations := 0
var detected := 0
var mismatches := 0
var by_type := {}
var unnoticed: Array = []
var compact_missed := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("LOCKSTEP DIGEST: " + label)

func _old() -> String:
	return JSON.stringify(State.capture(runtime), "", true, true).sha256_text()

func _rebase() -> void:
	sim.index_entities()
	base_old = _old()
	base_new = State.full_digest(runtime)

## One change: both digests must move together, and agree again once restored.
func _probe(label: String, change: Callable, restore: Callable) -> void:
	var compact_before := State.digest(runtime)
	change.call()
	var old_changed := _old() != base_old
	var new_changed := State.full_digest(runtime) != base_new
	if old_changed and State.digest(runtime) == compact_before: compact_missed += 1
	mutations += 1
	if old_changed: detected += 1
	else: unnoticed.append(label)
	if old_changed != new_changed:
		mismatches += 1
		if mismatches <= 12: push_error("LOCKSTEP DIGEST: %s: original checksum %s, exhaustive digest %s" % [label, "changed" if old_changed else "unchanged", "changed" if new_changed else "unchanged"])
	restore.call()
	var old_back := _old() == base_old
	var new_back := State.full_digest(runtime) == base_new
	if old_back != new_back:
		mismatches += 1
		push_error("LOCKSTEP DIGEST: %s: after restoring, original checksum %s, exhaustive digest %s" % [label, "agrees" if old_back else "differs", "agrees" if new_back else "differs"])
	# A setter may leave a side effect behind; both digests then saw it.
	if not old_back: _rebase()

func _run() -> void:
	var game := root.get_node("GameSession")
	game.online_active = false
	game.online_spectator = false
	game.match_ai_mode = "sandbox"
	game.match_map_data = {}
	game.pending_save_data = {}
	var scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	await process_frame
	var bootstrap: Node = scene.get_node("Bootstrap")
	runtime = Runtime.new()
	runtime.name = "NetworkMatch"
	scene.add_child(runtime)
	runtime.match_state = bootstrap.match_state
	runtime.entities = scene.get_node("Entities")
	runtime.map_bounds = bootstrap.map_bounds
	runtime._civs = {0: bootstrap.player_civ, 1: bootstrap.ai_civ}
	runtime.is_host = true
	runtime._playing = true
	runtime.set_process(false)
	sim = Simulation.new()
	sim.setup(runtime)
	runtime.simulation = sim
	# A world in motion: walking and gathering units, production with paid
	# queues, technology and age jobs, a projectile and a gate.
	var units: Array = []
	var centers: Array = []
	for entity in runtime.entities.get_children():
		if entity is UnitAgent: units.append(entity)
		if entity is BuildingAgent and entity.def.id == &"town_center": centers.append(entity)
	runtime.match_state.set_age(1, 2)
	for team in 2:
		for resource in 4: runtime.match_state.resources[team][resource] = 10000
	for index in units.size():
		var unit: UnitAgent = units[index]
		if index % 2 == 0: unit.command_move(unit.sim_pos + Vector2(6, -4))
	check(centers[0].enqueue_train(load("res://data/units/villager.tres")), "production queued")
	# Castle Age needs two Feudal buildings besides the one researching.
	var research: BuildingAgent
	for index in 3:
		var building := load("res://scenes/entities/building_view.tscn").instantiate() as BuildingAgent
		building.def = Catalog.get_building([&"archery_range", &"university", &"monastery"][index])
		building.team = 1
		building.civ = runtime._civs[1]
		building.match_state = runtime.match_state
		building.sim_pos = Vector2(160, 120 + index * 20)
		runtime.entities.add_child(building)
		if index == 0: research = building
	check(runtime.match_state.technology_progression.start_research(research, "crossbowman"), "technology job started")
	check(runtime.match_state.age_progression.start_advance(centers[1]), "age job started")
	var gate := load("res://scenes/entities/building_view.tscn").instantiate() as BuildingAgent
	gate.def = Catalog.get_building(&"gate")
	gate.team = 0
	gate.civ = runtime._civs[0]
	gate.match_state = runtime.match_state
	gate.sim_pos = centers[0].sim_pos + Vector2(10, 0)
	runtime.entities.add_child(gate)
	var projectile: Node = load("res://scenes/entities/projectile_view.tscn").instantiate()
	runtime.entities.add_child(projectile)
	projectile.setup(units[0].sim_pos, units[0].sim_pos + Vector2(20, 0), load("res://data/units/archer.tres"), units[0].team, units[0])
	for _step in 12: sim.step()
	# A searching villager keeps weak references to candidate resources.
	var villager: UnitAgent
	for unit in units:
		if unit.def.id == &"villager" and unit.team == 0: villager = unit
	var resources: Array = runtime.entities.get_children().filter(func(node): return node is ResourceNode and float(node.amount) > 0)
	var candidates: Array[WeakRef] = [weakref(resources[0]), weakref(resources[1])]
	villager.set("_gather_candidates", candidates)
	_rebase()
	check(State.full_digest(runtime) == base_new and State.full_digest(runtime) == base_new, "the digest is repeatable")
	check(base_new.length() == 64 and base_new.is_valid_hex_number(), "the digest is a SHA-256 hex string")

	# Every field of sampled entities of each kind.
	var samples := _samples(units, centers, gate, research, projectile)
	samples.append(villager)
	var others: Array = runtime.entities.get_children().filter(func(node): return node is UnitAgent)
	for node: Node in samples:
		var kind: String = runtime._entity_kind(node)
		for field in State.fields_for(kind):
			var original: Variant = node.get(field)
			var changed: Variant = _changed(original, node, others)
			if changed == null: continue
			var type := type_string(typeof(original))
			by_type[type] = int(by_type.get(type, 0)) + 1
			_probe("%s %s.%s (%s)" % [kind, node.name, field, type], func(): node.set(field, changed), func(): node.set(field, original))
			# References inside containers: same length, another target.
			if original is Array and not original.is_empty() and typeof(original[0]) == TYPE_OBJECT:
				var swapped: Variant = _changed(original[0], node, others)
				if swapped == null: continue
				var items: Array = original.duplicate()
				items[0] = swapped
				var reference_type := "WeakRef in Array" if original[0] is WeakRef else "reference in Array"
				by_type[reference_type] = int(by_type.get(reference_type, 0)) + 1
				_probe("%s %s.%s[0] reference" % [kind, node.name, field], func(): node.set(field, items), func(): node.set(field, original))

	# Zero signs and dictionary order: what the previous decimal JSON ignored.
	var mover: UnitAgent = units[0]
	var velocity: Vector2 = mover.get("_locomotion_velocity")
	_probe("Vector2 zero sign", func(): mover.set("_locomotion_velocity", Vector2(-0.0, velocity.y)), func(): mover.set("_locomotion_velocity", velocity))
	mover.set("_locomotion_velocity", Vector2(0.0, velocity.y))
	_rebase()
	_probe("Vector2 negative zero", func(): mover.set("_locomotion_velocity", Vector2(0.0 * -1.0, velocity.y)), func(): mover.set("_locomotion_velocity", Vector2(0.0, velocity.y)))
	mover.set("_locomotion_velocity", velocity)
	_rebase()
	# A scalar keeps its exact bits, sign of zero included, as base64 did.
	var float_field := ""
	for field in State.UNIT_FIELDS:
		if typeof(mover.get(field)) == TYPE_FLOAT and is_finite(mover.get(field)): float_field = field
	check(not float_field.is_empty(), "a unit has a scalar float field")
	var scalar: float = mover.get(float_field)
	mover.set(float_field, 0.0)
	_rebase()
	_probe("float negative zero", func(): mover.set(float_field, 0.0 * -1.0), func(): mover.set(float_field, 0.0))
	mover.set(float_field, scalar)
	_rebase()
	var payments: Dictionary = centers[0].get("_train_payments")
	check(not payments.is_empty() and payments.values()[0].size() >= 2, "the queued villager carries its payment record")
	var reordered := {}
	for queue_id in payments:
		var cost: Dictionary = payments[queue_id]
		var keys := cost.keys()
		keys.reverse()
		var reversed := {}
		for key in keys: reversed[key] = cost[key]
		reordered[queue_id] = reversed
	_probe("dictionary insertion order", func(): centers[0].set("_train_payments", reordered), func(): centers[0].set("_train_payments", payments))

	# Match, jobs, navigation, land support and fog.
	var state: MatchState = runtime.match_state
	for field in State.STATE_FIELDS:
		var original: Variant = state.get(field)
		var changed: Variant = _changed(original, null, others)
		if changed == null: continue
		_probe("match " + field, func(): state.set(field, changed), func(): state.set(field, original))
	var age_job: Dictionary = state.age_progression._jobs[1]
	# The seconds field is the compatibility input _sync_job_clock reads.
	var age_elapsed: float = age_job.elapsed
	_probe("age job clock", func(): age_job.elapsed = age_elapsed + 0.5, func(): age_job.elapsed = age_elapsed)
	var tech_job: Dictionary = state.technology_progression.jobs[research.get_instance_id()]
	var tech_elapsed: float = tech_job.elapsed
	_probe("technology job clock", func(): tech_job.elapsed = tech_elapsed + 0.5, func(): tech_job.elapsed = tech_elapsed)
	var nav: Node = scene.get_node("NavService")
	var pending: Array = nav.nav._pending_requests
	var request := {"id": units[1].get_instance_id(), "from": Vector2(1, 2), "to": Vector2(3, 4)}
	_probe("pending route request", func(): pending.append(request), func(): pending.erase(request))
	var repath: bool = nav._lockstep_repath
	_probe("pending repath", func(): nav._lockstep_repath = not repath, func(): nav._lockstep_repath = repath)
	var support: Node = scene.get_node("LandSupport")
	var support_elapsed: int = support.elapsed_time
	_probe("land support clock", func(): support.elapsed_time = support_elapsed + 1, func(): support.elapsed_time = support_elapsed)
	var healed: int = units[2].get_instance_id()
	_probe("land support healing", func(): support.heal_remainders[healed] = 7, func(): support.heal_remainders.erase(healed))
	for team in 2:
		for mask_name in ["visible_now", "explored"]:
			var masks: Dictionary = state.fog.get(mask_name)
			var mask: PackedByteArray = masks[team]
			var cell := mask.size() / 2
			var value := mask[cell]
			_probe("fog %s %d" % [mask_name, team], func():
				var copy := mask.duplicate()
				copy[cell] = 0 if value != 0 else 2
				masks[team] = copy, func(): masks[team] = mask)
	var next_id: int = runtime._next_id
	_probe("next network id", func(): runtime._next_id = next_id + 1, func(): runtime._next_id = next_id)
	# Removing an entity cannot be undone; probe it last.
	var tree: Node = samples.filter(func(node): return runtime._entity_kind(node) == "resource")[0]
	tree.queue_free()
	check(_old() != base_old and State.full_digest(runtime) != base_new, "an entity leaving the world changes both")

	check(by_type.has("WeakRef in Array"), "a weak reference target was changed")
	# Which digest a frame carries depends on its tick alone.
	var saved_tick: int = runtime.tick
	runtime.tick = 30
	check(sim.frame_checksum() == State.full_digest(runtime), "a frame ending on a whole second carries the exhaustive digest")
	runtime.tick = 33
	check(sim.frame_checksum() == State.digest(runtime), "frames in between carry the compact digest")
	check(State.digest(runtime) != State.full_digest(runtime), "the two digests are distinguishable")
	# A hidden field outside the compact digest is caught at the next whole second.
	var armored: BuildingAgent = centers[0]
	var armor: int = armored.melee_armor_q
	runtime.tick = 30
	var whole_second: String = sim.frame_checksum()
	armored.melee_armor_q = armor + 1
	check(sim.frame_checksum() != whole_second, "hidden state differences are caught at the next whole second")
	armored.melee_armor_q = armor
	runtime.tick = saved_tick
	check(mutations >= 150, "probed %d state changes" % mutations)
	check(detected >= 140, "the original checksum noticed %d of them" % detected)
	check(mismatches == 0, "the exhaustive digest agrees with the original checksum on every change (%d disagreements)" % mismatches)
	print("LOCKSTEP DIGEST: changes neither digest notices: %s; the compact per-frame digest misses %d of the %d noticed" % [unnoticed, compact_missed, detected])
	# Speed, on this default map.
	var started := Time.get_ticks_usec()
	for _i in 5: _old()
	var old_ms := (Time.get_ticks_usec() - started) / 5000.0
	started = Time.get_ticks_usec()
	for _i in 5: State.full_digest(runtime)
	var new_ms := (Time.get_ticks_usec() - started) / 5000.0
	started = Time.get_ticks_usec()
	for _i in 5: State.digest(runtime)
	var compact_ms := (Time.get_ticks_usec() - started) / 5000.0
	print("LOCKSTEP DIGEST %s: %d checks, %d changes probed (%d noticed), %d disagreements, types %s; original %.1f ms, exhaustive %.1f ms, compact %.1f ms" % ["PASSED" if failures == 0 else "FAILED", checks, mutations, detected, mismatches, by_type, old_ms, new_ms, compact_ms])
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

## Two of each kind, preferring ones whose containers are filled.
func _samples(units: Array, centers: Array, gate: Node, research: Node, projectile: Node) -> Array:
	var result: Array = [centers[0], centers[1], gate, research]
	if is_instance_valid(projectile) and not projectile.is_queued_for_deletion(): result.append(projectile)
	var busy: Array = units.filter(func(unit): return not unit.get("_path").is_empty())
	var gathering: Array = units.filter(func(unit): return not unit.get("_gather_candidates").is_empty())
	result.append_array(busy.slice(0, 1) + gathering.slice(0, 1) + units.slice(0, 1))
	var counts := {"resource": 0, "terrain": 0}
	for node in runtime.entities.get_children():
		var kind: String = runtime._entity_kind(node)
		if counts.has(kind) and counts[kind] < 2:
			counts[kind] += 1
			result.append(node)
	return result

## A different value of the same type, or null when none can be made.
func _changed(value: Variant, node: Node, others: Array) -> Variant:
	match typeof(value):
		TYPE_INT: return value + 1
		TYPE_FLOAT: return value + 0.5 if is_finite(value) else 1.0
		TYPE_BOOL: return not value
		TYPE_STRING: return value + "x"
		TYPE_STRING_NAME: return StringName(String(value) + "x")
		TYPE_VECTOR2: return value + Vector2(0.25, 0)
		TYPE_VECTOR2I: return value + Vector2i(1, 0)
		TYPE_PACKED_VECTOR2_ARRAY:
			var points := PackedVector2Array(value)
			points.append(Vector2(1.5, 2.5))
			return points
		TYPE_ARRAY:
			var items: Array = value.duplicate()
			if not items.is_empty(): items.append(items[0])
			elif not items.is_typed(): items.append(1)
			elif items.get_typed_builtin() == TYPE_INT: items.append(3)
			elif items.get_typed_builtin() == TYPE_VECTOR2: items.append(Vector2(3, 4))
			else: return null
			return items
		TYPE_DICTIONARY:
			if value.is_typed(): return null
			var entries: Dictionary = value.duplicate()
			entries["digest_probe"] = 1
			return entries
		TYPE_OBJECT:
			if value is Node:
				for other in others:
					if other != value and other != node: return other
			if value is WeakRef:
				for other in others:
					if other != value.get_ref() and other != node: return weakref(other)
			if value is UnitDef: return load("res://data/units/archer.tres") if value.id != &"archer" else load("res://data/units/villager.tres")
	return null
