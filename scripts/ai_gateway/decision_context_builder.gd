extends RefCounted

## Bounded planning hints derived from this team's sight, not the opponent's state.
## They suggest legal primitive arguments; they never select a strategic phase.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const Build := preload("res://scripts/systems/build_system.gd")
const Nav := preload("res://scripts/systems/nav_grid_service.gd")
const Age := preload("res://scripts/systems/age_progression.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Perimeter := preload("res://scripts/ai_gateway/defense_perimeter.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Shore := preload("res://scripts/world/shore_geometry.gd")
const MAX_FRONTIERS := 12
const POSITIONS_PER_BUILDING := 3
const MAX_ROUTE_CHECKS_PER_BUILDING := 4
const MILITARY_BUILDINGS := ["barracks", "archery_range", "stable", "siege_workshop", "castle"]
const PLANNING_SCALE := 4.0
const FARM_RESERVE_RADIUS := 22.0
const LANE_WIDTH := 3.0
## Bucket size (simulation units) of the per-call construction site index.
const SITE_BUCKET := 16.0
const BUILD_PRIORITY := ["barracks", "house", "farm", "mill", "lumber_camp", "mining_camp", "archery_range", "stable", "blacksmith", "market", "siege_workshop", "castle", "town_center", "monastery", "university"]
const FRONTIER_CACHE_META := &"ai_observation_frontier_geometry"

## Optional main-thread planning slices. References collected before a frame
## boundary may die in that frame; prune every shared list on both sides.
class PreparationBudget extends RefCounted:
	var callback: Callable
	var budget_usec: int
	var started_usec: int
	var entities_ref: WeakRef
	var node_lists: Array
	func _init(frame_callback: Callable, budget: int, entities: Node2D, lists: Array) -> void:
		callback = frame_callback
		budget_usec = budget
		started_usec = Time.get_ticks_usec()
		entities_ref = weakref(entities)
		node_lists = lists
	func expired() -> bool:
		return Time.get_ticks_usec() - started_usec >= budget_usec
	func checkpoint() -> bool:
		if not expired(): return true
		_prune_nodes()
		if not callback.is_valid(): return false
		var keep_going := bool(await callback.call())
		_prune_nodes()
		if not keep_going: return false
		var entities: Node = entities_ref.get_ref()
		if entities == null or not entities.is_inside_tree() or entities.is_queued_for_deletion(): return false
		started_usec = Time.get_ticks_usec()
		return true
	func _prune_nodes() -> void:
		for nodes: Array in node_lists:
			for index in range(nodes.size() - 1, -1, -1):
				var node: Variant = nodes[index]
				if not is_instance_valid(node) or node.is_queued_for_deletion():
					nodes.remove_at(index)

class ObservationNav extends NavGridService:
	var fog: RefCounted
	var team := 0
	var _visible_layers: Dictionary = {}

	func _get_or_build_solid_for_radius(radius: float) -> PackedByteArray:
		var key := _radius_key(radius)
		var cached := _solid_by_radius.has(key)
		var layer := super._get_or_build_solid_for_radius(radius)
		if fog == null or (cached and _visible_layers.has(key)): return layer
		var kept := PackedInt32Array()
		var bounds := Rect2(Vector2(_origin_cell) * cell_size, Vector2(_width, _height) * cell_size)
		var clearance := Vector2.ONE * (cell_size + radius * 2.0)
		# Seeing one end of a large blocker cannot disclose its hidden extent.
		# Keep only obstacles whose cell and inflation neighborhood are visible;
		# public map edges remain known. Unknown land is an optimistic route.
		for index in _solid_indices_by_radius.get(key, PackedInt32Array()):
			var point := cell_to_world_center(_cell_from_index(index))
			if not bounds.encloses(Rect2(point - clearance * 0.5, clearance)) or fog.footprint_visible(team, point, clearance, true):
				kept.append(index)
			else:
				layer[index] = 0
		_solid_by_radius[key] = layer
		_solid_indices_by_radius[key] = kept
		_visible_layers[key] = true
		return layer


## GDScript marks a function containing await as a coroutine even when that
## branch is disabled. The legacy entry invokes the shared implementation with
## no callback through a Callable: that path cannot yield and returns a Dictionary
## immediately. build_budgeted is the explicit asynchronous public entry.
static func build(state: MatchState, entities: Node2D, team: int, snapshots: Array, derived: Dictionary, defend_radius: float, defense_only: bool = false) -> Dictionary:
	var implementation := Callable(load("res://scripts/ai_gateway/decision_context_builder.gd"), &"_build_impl")
	return implementation.call(state, entities, team, snapshots, derived, defend_radius, defense_only, Callable(), 0)


static func build_budgeted(state: MatchState, entities: Node2D, team: int, snapshots: Array, derived: Dictionary, defend_radius: float, defense_only: bool = false, yield_frame: Callable = Callable(), budget_usec: int = 4000) -> Dictionary:
	return await _build_impl(state, entities, team, snapshots, derived, defend_radius, defense_only, yield_frame, budget_usec)


static func _build_impl(state: MatchState, entities: Node2D, team: int, snapshots: Array, derived: Dictionary, defend_radius: float, defense_only: bool, yield_frame: Callable, budget_usec: int) -> Dictionary:
	if not is_instance_valid(entities) or entities.is_queued_for_deletion(): return {}
	var own: Array[Node2D] = []
	var builders: Array[Node2D] = []
	var known_static: Array = []
	var placement_blockers: Array = []
	var civ: CivDef
	var observed_ids := {}
	var budget: PreparationBudget
	if yield_frame.is_valid() and budget_usec > 0:
		if not entities.is_inside_tree(): return {}
		budget = PreparationBudget.new(yield_frame, budget_usec, entities, [own, builders, known_static, placement_blockers])
	var fog_holder := FogAccess.holder_for_snapshot(state, entities)
	for snapshot: Dictionary in snapshots: observed_ids[snapshot.id] = true
	for node in entities.get_children():
		if budget != null and budget.expired():
			if not await budget.checkpoint(): return {}
			fog_holder = FogAccess.holder_for_snapshot(state, entities)
		# The saved child list can contain a node deleted during the callback.
		if not is_instance_valid(node) or not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		var definition: Variant = node.get("def")
		if definition is UnitDef or definition is BuildingDef:
			if float(node.get("hp")) <= 0: continue
			if int(node.get("team")) == team:
				own.append(node)
				if civ == null: civ = node.get("civ") as CivDef
				if definition is UnitDef and definition.id == &"villager": builders.append(node)
		if not FogAccess.snapshot_can_see(state, team, node, fog_holder): continue
		if (definition is BuildingDef or definition is UnitDef or node.has_method("extract")) and not observed_ids.has(Registry.id_of(node)): continue
		if definition is BuildingDef or node.is_in_group("terrain_regions"):
			placement_blockers.append(node)
			known_static.append(node)
		elif node.has_method("extract"):
			known_static.append(node)
	var catalog := {} if defense_only else _catalog(state, entities, team, civ)
	if budget != null and not await budget.checkpoint(): return {}
	var bounds := state.map_bounds
	if not bounds.has_area():
		var base := Protocol.array_to_vec2(derived.get("own_tc_pos", [0, 0])) as Vector2
		bounds = Rect2(base - Vector2.ONE * 60, Vector2.ONE * 120)
	# This grid deliberately excludes unseen terrain/resources and all mobile enemies.
	# It provides optimistic routes through unknown land without an obstacle oracle.
	var nav := ObservationNav.new()
	nav.team = team
	nav.fog = state.fog if state.fog_enabled else null
	const CELL := 2.0
	nav.setup_rect(Vector2i((bounds.position / CELL).floor()), Vector2i((bounds.end / CELL).ceil()), CELL)
	if budget != null and not await budget.checkpoint(): return {}
	nav.rebuild_from_blockers(known_static)
	if budget != null and not await budget.checkpoint(): return {}
	var army := {} if defense_only else _army(own, snapshots, derived, team, defend_radius, bounds, nav)
	if budget != null and not await budget.checkpoint(): return {}
	var defense := _defense_planning(state, entities, team, civ, builders, derived, bounds, nav)
	if budget != null and not await budget.checkpoint(): return {}
	if defense_only:
		return {"defense_options": defense.options, "defense_plan": defense.plan, "defense_scout_options": defense.scouts}
	var construction := _construction_options(state, team, builders, catalog.buildings, placement_blockers, bounds, nav, derived, snapshots)
	# This boundary is also immediately before scouting. No partial stage
	# dictionary escapes if cancellation/scene teardown happens while yielding.
	if budget != null and not await budget.checkpoint(): return {}
	var scouting := _scouting(state, team, own, bounds, nav, army.scout_ids, derived)
	return {
		"catalog": catalog,
		"defense_options": defense.options,
		"defense_plan": defense.plan,
		"defense_scout_options": defense.scouts,
		"construction_options": construction,
		"layout": {"base": derived.get("own_tc_pos", [0, 0]), "farm_reserve_radius": FARM_RESERVE_RADIUS, "lane_width": LANE_WIDTH, "planning_scale": PLANNING_SCALE},
		"scouting": scouting,
		"army": army,
	}


static func _catalog(state: MatchState, entities: Node2D, team: int, civ: CivDef) -> Dictionary:
	var age := state.age_of(team)
	var civ_id: StringName = civ.id if civ != null else StringName(state.team_civilizations.get(team, ""))
	var buildings: Array = []
	for id in BUILD_PRIORITY + ["palisade_wall", "stone_wall", "fortified_wall", "gate"]:
		var definition := Catalog.get_building(id)
		if definition == null or (state.progression_enabled and definition.required_age > age + 1): continue
		if civ_id != &"" and not definition.civilizations.is_empty() and civ_id not in definition.civilizations: continue
		var reason := Catalog.building_reason(state, team, civ, definition, entities)
		buildings.append({"id": id, "cost": _cost(definition), "footprint": Protocol.vec2_to_array(definition.footprint), "build_time": definition.build_time, "population_provided": definition.population_provided, "required_age": definition.required_age, "prerequisites": definition.prerequisites, "required_technology": Catalog.building_record(definition.id).get("required_technology", ""), "available": reason.is_empty(), "blocked_reason": reason})
		buildings[-1]["planning_footprint"] = Protocol.vec2_to_array(planning_footprint(definition))
		buildings[-1]["blocks_movement"] = definition.blocks_movement
		buildings[-1]["has_drop_off"] = definition.has_drop_off
		var weapon := Catalog.building_weapon(definition.id)
		if weapon != null:
			buildings[-1]["attack"] = weapon.attack
			buildings[-1]["attack_range"] = weapon.attack_range
			buildings[-1]["minimum_range"] = weapon.minimum_attack_range
			buildings[-1]["cooldown"] = weapon.attack_cooldown
			buildings[-1]["is_ranged"] = weapon.is_ranged
	var units: Array = []
	for definition: UnitDef in Catalog.units().values():
		if state.progression_enabled and definition.required_age > age + 1: continue
		if civ_id != &"" and not definition.civilizations.is_empty() and civ_id not in definition.civilizations: continue
		units.append({"id": String(definition.id), "cost": _cost(definition), "population": definition.population, "train_at": String(definition.train_at), "train_time": definition.train_time, "required_age": definition.required_age, "required_technology": String(definition.required_technology), "unlocked": state.unit_unlocked(team, definition, civ_id), "attack": definition.attack, "attack_range": definition.attack_range, "vision_radius": definition.resolved_vision_radius(age)})
		units[-1]["is_ranged"] = definition.is_ranged
		units[-1]["minimum_range"] = definition.minimum_attack_range
		units[-1]["cooldown"] = definition.attack_cooldown
		units[-1]["attack_class_bonuses"] = definition.attack_class_bonuses
		units[-1]["projectile_splash_radius"] = definition.projectile_splash_radius if definition.is_ranged else 0.0
		units[-1]["projectile_friendly_fire"] = definition.is_ranged and definition.projectile_friendly_fire
	var technologies: Array = []
	for id in Catalog.technologies():
		if not state.progression_enabled: break
		var record: Dictionary = Catalog.technologies()[id]
		if int(record.get("required_age", 0)) > age + 1 or (civ_id != &"" and not Catalog.civilization_allows(record, civ_id)): continue
		if state.has_technology(team, StringName(id)): continue
		var prerequisite := String(record.get("prerequisite_technology", ""))
		if not prerequisite.is_empty() and not state.has_technology(team, StringName(prerequisite)): continue
		technologies.append({"id": id, "cost": record.get("cost", {}), "research_at": record.get("research_at", ""), "required_age": record.get("required_age", 0), "prerequisite_technology": prerequisite, "time": record.get("time", 0), "upgrades": record.get("upgrades", [])})
	var upgrade := Age.requirements_for(age + 1) if state.progression_enabled else {}
	if not upgrade.is_empty():
		upgrade["cost"] = {"food": upgrade.get("food", 0), "wood": 0, "gold": upgrade.get("gold", 0), "stone": 0}
		upgrade["target_age"] = age + 1
		upgrade["required_distinct_buildings"] = 2
		upgrade["castle_alternative"] = age + 1 == Enums.Age.IMPERIAL
	return {"buildings": buildings, "units": units, "technologies": technologies, "age_upgrade": upgrade, "progression_enabled": state.progression_enabled, "train_queue_limit": BuildingAgent.MAX_TRAIN_QUEUE}


static func _cost(definition: Resource) -> Dictionary:
	return {"food": definition.get("cost_food"), "wood": definition.get("cost_wood"), "gold": definition.get("cost_gold"), "stone": definition.get("cost_stone")}


static func planning_footprint(definition: BuildingDef) -> Vector2:
	# Original sprites cover four simulation units per source tile. This is a
	# planning preference, never a change to authoritative placement legality.
	return definition.footprint * PLANNING_SCALE


static func _construction_options(state: MatchState, team: int, builders: Array[Node2D], records: Array, blockers: Array, bounds: Rect2, nav: RefCounted, derived: Dictionary, snapshots: Array = []) -> Array:
	var result: Array = []
	var free_builders := builders.filter(func(unit): return unit.get("order") in [Enums.OrderType.NONE, Enums.OrderType.GATHER] and float(unit.get("carry_amount")) <= 0.001 and String(unit.get("_gather_state")) != "to_drop_off")
	if free_builders.is_empty(): return result
	var base := Protocol.array_to_vec2(derived.get("own_tc_pos", [0, 0])) as Vector2
	if int(derived.get("own_tc_id", -1)) < 0: base = free_builders[0].get("sim_pos")
	var stored_plans: Dictionary = state.get_meta(Perimeter.META_KEY, {})
	var wall_plan: Dictionary = stored_plans.get("%d:%d" % [team, int(derived.get("own_tc_id", -1))], {})
	var direction := (bounds.get_center() - base).normalized()
	if direction == Vector2.ZERO: direction = Vector2.RIGHT
	# Measure spoke angles from the map-center direction, not from world +X.
	# Many plots tie on score and only the first few per building are offered,
	# so a world-fixed start gave the two bases of a rotationally symmetric map
	# different choices (e.g. one team's opening mill on the far side of its
	# berries). Relative angles keep both teams' options symmetric.
	var start_angle := direction.angle()
	# Hundreds of candidate points share one pass over the observed blockers.
	var sites := _site_index(blockers)
	var wall_strips := Perimeter.wall_strips(wall_plan)
	for record: Dictionary in records:
		if Walls.is_fortification(StringName(record.id)): continue
		# Resource shortages do not invalidate geometry: the planner can save up.
		if not record.available and record.blocked_reason != "资源不足": continue
		var definition := Catalog.get_building(record.id)
		var zone := "military" if record.id in MILITARY_BUILDINGS else "farm" if record.id == "farm" else "residential"
		var anchors: Array = [{"pos": base, "resource_id": null}]
		# Growing bases exhaust the inner rings before castle-age infrastructure
		# unlocks. Include bounded outer alternatives, still requiring own sight,
		# clear delivery lanes and a reachable builder; nearer plots score first.
		var radii: Array = [26.0, 30.0, 34.0, 44.0, 50.0, 56.0, 68.0]
		if zone == "farm":
			radii = [18.0, 22.0, 28.0, 36.0, 44.0]
			anchors = _farm_anchors(snapshots, team, base, int(derived.get("own_tc_id", -1)))
		if record.id in ["lumber_camp", "mining_camp", "mill"]:
			zone = "resource_drop_off"
			anchors = _resource_anchors(record.id, snapshots, base)
			radii = [10.0, 14.0, 18.0]
			if record.id == "mill":
				# A reserved wall band can cover both old 26/34 fallback rings.
				# Keep inner and outer alternatives even after berries disappear,
				# so a missing mill cannot permanently block farms and enclosure.
				anchors.append({"pos": base, "resource_id": null, "radii": [18.0, 22.0, 26.0, 34.0, 44.0, 50.0], "score_bonus": -10.0})
		var candidates: Array = []
		var seen := {}
		for anchor: Dictionary in anchors:
			for radius in anchor.get("radii", radii):
				# At larger radii the original 16 spokes leave wide gaps, missing
				# legal plots along the irregular edge of the team's current sight.
				var sectors := 32 if float(radius) > 44.0 else 16
				for sector in sectors:
					var point: Vector2 = (anchor.pos + Vector2.from_angle(start_angle + TAU * (sector + 0.5) / float(sectors)) * float(radius)).round()
					if seen.has(point): continue
					seen[point] = true
					if zone == "military" and point.distance_to(base) < FARM_RESERVE_RADIUS + planning_footprint(definition).length() * 0.25: continue
					if not _planning_clear(definition, point, base, sites, bounds): continue
					# Reserve the actual wall line, including production exit clearance,
					# before the first foundation is paid for.
					if not Perimeter.strips_clear(wall_strips, point, definition.footprint + Vector2.ONE * 4): continue
					if state.fog_enabled and (state.fog == null or not state.fog.footprint_visible(team, point, definition.footprint, true)): continue
					if not _can_place(definition.footprint, point, sites) or not _footprint_walkable(point, definition.footprint, nav): continue
					var facing := (point - base).normalized().dot(direction)
					var score: float = 100.0 - point.distance_to(anchor.pos) - point.distance_to(base) * 0.1 + float(anchor.get("score_bonus", 0))
					if zone == "military": score += facing * 10.0
					elif zone == "residential": score -= facing * 8.0
					candidates.append({"point": point, "score": score, "resource_id": anchor.resource_id, "drop_off_id": anchor.get("drop_off_id")})
		candidates.sort_custom(func(a, b): return a.score > b.score)
		var found := 0
		var checked := 0
		for candidate: Dictionary in candidates:
			if found >= POSITIONS_PER_BUILDING or checked >= MAX_ROUTE_CHECKS_PER_BUILDING: break
			var point: Vector2 = candidate.point
			var builder: Node2D = free_builders[0]
			for unit in free_builders:
				if unit.get("sim_pos").distance_squared_to(point) < builder.get("sim_pos").distance_squared_to(point): builder = unit
			checked += 1
			var route: PackedVector2Array = nav.find_path(builder.get("sim_pos"), point, builder.get("def").resolved_footprint_radius())
			if route.is_empty() or route[-1].distance_to(point) > 2: continue
			var exit_pos := point + Vector2.RIGHT * (definition.footprint.x * 0.5 + 2.0)
			if definition.id in MILITARY_BUILDINGS and not nav.is_world_walkable_with_radius(exit_pos, 0.6): continue
			result.append({"building_def_id": record.id, "builder_id": Registry.id_of(builder), "pos": Protocol.vec2_to_array(point),
				"zone": zone, "planning_footprint": Protocol.vec2_to_array(planning_footprint(definition)),
				"score": snappedf(candidate.score, 0.1), "resource_target_id": candidate.resource_id,
				"drop_off_id": candidate.drop_off_id,
				"exit_pos": Protocol.vec2_to_array(exit_pos), "reasons": ["visible_legal_footprint", "known_route", "farm_and_lane_reserve"]})
			found += 1
	return result


static func _defense_options(state: MatchState, entities: Node2D, team: int, civ: CivDef, builders: Array[Node2D], derived: Dictionary, bounds: Rect2, nav: RefCounted) -> Array:
	return _defense_planning(state, entities, team, civ, builders, derived, bounds, nav).options


static func _defense_planning(state: MatchState, entities: Node2D, team: int, civ: CivDef, builders: Array[Node2D], derived: Dictionary, bounds: Rect2, nav: RefCounted) -> Dictionary:
	var options: Array = []
	var scouts: Array = []
	var result := {"options": options, "scouts": scouts, "plan": {}}
	if int(derived.get("own_tc_id", -1)) < 0: return result
	var available := builders.filter(func(unit): return unit.get("order") in [Enums.OrderType.NONE, Enums.OrderType.GATHER] and unit.get_build_queue_ids().is_empty() and float(unit.get("carry_amount")) <= 0.001 and String(unit.get("_gather_state")) != "to_drop_off")
	var ctx := Context.new()
	ctx.match_state = state
	ctx.entities = entities
	ctx.team = team as Enums.Team
	ctx.civ = civ
	var base: Vector2 = Protocol.array_to_vec2(derived.own_tc_pos)
	var perimeter := Perimeter.get_plan(state, entities, team, base, int(derived.own_tc_id), bounds, "palisade_wall")
	if perimeter.rect.size.x < 12 or perimeter.rect.size.y < 12:
		result.plan = {"id": perimeter.id, "closed": false, "phase": "blocked", "blocked_reason": "map_too_small_for_access_gates", "total_segments": 0, "missing_segments": 0, "blocked_segments": 0, "complete_segments": 0}
		return result
	# Hundreds of wall pieces share one scene pass (nothing is placed here).
	var scene := Walls.scene_index(ctx)
	var gate_reason := Catalog.building_reason(state, team, civ, Catalog.get_building(&"gate"), entities)
	var gate_unlocked := gate_reason.is_empty() or gate_reason == "资源不足"
	var seen: Dictionary = perimeter.seen_complete
	var unique := {}
	var complete := 0
	var blocked_keys := {}
	var unseen_keys := {}
	var pending := 0
	for batch: Dictionary in Perimeter.batches(perimeter):
		var missing := 0
		var missing_keys: Array[String] = []
		var repair := false
		var connected := false
		var visible := true
		for piece: Dictionary in batch.pieces:
			var key := "%s:%s" % [piece.building_def_id, piece.pos]
			var existing := Walls.existing_segment(piece, ctx, scene)
			if existing != null: connected = true
			if existing == null:
				missing += 1
				missing_keys.append(key)
				if seen.has(key): repair = true
			# Completed/pending owned pieces need no new placement or survey. Their
			# visibility matters only when this batch also contains a missing piece.
			# Defer the footprint checks until missing is known below.
			if unique.has(key): continue
			unique[key] = true
			if existing != null:
				if bool(existing.get("is_complete")):
					complete += 1
					seen[key] = true
				else: pending += 1
		if missing == 0: continue
		for piece: Dictionary in batch.pieces:
			var footprint := Walls.footprint_for(Catalog.get_building(piece.building_def_id), int(piece.orientation))
			if state.fog_enabled and (state.fog == null or not state.fog.footprint_visible(team, piece.pos, footprint + Vector2.ONE * 2, true)):
				visible = false
				break
		if not visible:
			for key in missing_keys: unseen_keys[key] = true
			if not available.is_empty():
				var point: Vector2 = (batch.start + batch.end) * 0.5 - batch.normal * 4
				var builder: Node2D = available[0]
				for unit in available:
					if unit.get("sim_pos").distance_squared_to(point) < builder.get("sim_pos").distance_squared_to(point): builder = unit
				# A survey is a short move within a leased builder task, rather than
				# sending a villager across an entire unseen side in one order.
				point = builder.get("sim_pos").move_toward(point, 14.0)
				if not scouts.any(func(option): return option.side == batch.side):
					scouts.append({"unit_id": Registry.id_of(builder), "pos": Protocol.vec2_to_array(point), "side": batch.side, "reason": "reveal_perimeter"})
			continue
		if batch.include_gate and not gate_unlocked:
			for key in missing_keys: blocked_keys[key] = true
			continue
		# Only consult authoritative geometry after the entire footprint and its
		# inflation neighborhood are visible; hidden terrain cannot leak via hints.
		if not Walls.validate_plan(batch.pieces, ctx, false, scene).is_empty():
			for key in missing_keys: blocked_keys[key] = true
			continue
		if available.is_empty(): continue
		var approach: Vector2 = (batch.start + batch.end) * 0.5 - batch.normal * 3.0
		var builder: Node2D = available[0]
		for unit in available:
			if unit.get("sim_pos").distance_squared_to(approach) < builder.get("sim_pos").distance_squared_to(approach): builder = unit
		var route: PackedVector2Array = nav.find_path(builder.get("sim_pos"), approach, builder.get("def").resolved_footprint_radius())
		if route.is_empty() or route[-1].distance_to(approach) > 2:
			for key in missing_keys: blocked_keys[key] = true
			continue
		var price := Walls.cost(batch.pieces, ctx, scene)
		options.append({"building_def_id": perimeter.material, "builder_id": Registry.id_of(builder),
			"start": Protocol.vec2_to_array(batch.start), "end": Protocol.vec2_to_array(batch.end), "include_gate": batch.include_gate,
			"cost": price, "segment_count": missing, "orientation": batch.pieces[0].orientation,
			"zone": "defensive_perimeter", "preserves_access": true, "perimeter_id": perimeter.id, "side": batch.side,
			"repair": repair, "connected": connected, "priority": 1000 if repair else 100 if connected else 0})
	var rectangle: Rect2 = perimeter.rect
	var unseen := unseen_keys.size()
	var closed := unique.size() > 0 and complete == unique.size()
	result.plan = {"id": perimeter.id, "material": perimeter.material, "total_segments": unique.size(), "complete_segments": complete,
		"missing_segments": unique.size() - complete - pending, "pending_segments": pending, "blocked_segments": blocked_keys.size(),
		"unseen_segments": unseen, "closed": closed, "phase": "closed" if closed else "survey" if unseen > 0 and options.is_empty() else "building",
		"bounds": [rectangle.position.x, rectangle.position.y, rectangle.size.x, rectangle.size.y]}
	options.sort_custom(func(a, b): return a.priority > b.priority)
	return result


static func _farm_anchors(snapshots: Array, team: int, base: Vector2, tc_id: int) -> Array:
	# Housing and military can occupy the first TC rings. Existing food drop-offs
	# provide bounded secondary farm districts instead of stopping food production.
	var result: Array = [{"pos": base, "resource_id": null, "drop_off_id": tc_id, "score_bonus": 4.0}]
	var drop_offs: Array = snapshots.filter(func(item): return item.get("kind") == "building" and int(item.get("team", -1)) == team and item.get("def_id") in ["mill", "town_center"] and bool(item.get("is_complete", false)) and int(item.get("id", -1)) != tc_id)
	drop_offs.sort_custom(func(a, b): return Protocol.array_to_vec2(a.pos).distance_squared_to(base) < Protocol.array_to_vec2(b.pos).distance_squared_to(base))
	for drop_off: Dictionary in drop_offs:
		var point: Vector2 = Protocol.array_to_vec2(drop_off.pos)
		if result.any(func(anchor): return anchor.pos.distance_to(point) < 12.0): continue
		result.append({"pos": point, "resource_id": null, "drop_off_id": drop_off.id,
			"radii": [14.0, 18.0, 22.0, 28.0] if drop_off.def_id == "mill" else [18.0, 22.0, 28.0, 36.0]})
		if result.size() >= 3: break
	return result


static func _resource_anchors(building_id: String, snapshots: Array, base: Vector2) -> Array:
	var allowed: Array = ["WOOD"] if building_id == "lumber_camp" else ["GOLD", "STONE"] if building_id == "mining_camp" else ["FOOD"]
	var resources: Array = snapshots.filter(func(item): return item.get("kind") == "resource" and String(item.get("resource_type", "")).to_upper() in allowed and float(item.get("amount", 0)) > 0)
	resources.sort_custom(func(a, b): return Protocol.array_to_vec2(a.pos).distance_squared_to(base) < Protocol.array_to_vec2(b.pos).distance_squared_to(base))
	var result: Array = []
	for resource: Dictionary in resources:
		var point: Vector2 = Protocol.array_to_vec2(resource.pos)
		if result.any(func(anchor): return anchor.pos.distance_to(point) < 12.0): continue
		result.append({"pos": point, "resource_id": resource.id})
		if result.size() >= 3: break
	return result


## Plain-geometry snapshot of the observed blockers for one site search.
## "planning": building planning footprints (and military exits) for
## _planning_clear; "placement" and "water": the same footprints and shore
## contours that Build.can_place reads. Entries are bucketed by every bucket
## their rectangles touch, so a query visits only nearby blockers; both tests
## are any-match, so an entry seen in several buckets cannot change a result.
static func _site_index(blockers: Array) -> Dictionary:
	var planning := {}
	var placement := {}
	var water: Array = []
	for value in blockers:
		var blocker := value as Node2D
		if blocker == null: continue
		var other := blocker.get("def") as BuildingDef
		var pos: Vector2 = blocker.get("sim_pos")
		if other != null:
			var other_size := planning_footprint(other)
			var rect := Rect2(pos - other_size * 0.5, other_size)
			var exit: Variant = null
			var covered := rect
			if String(other.id) in MILITARY_BUILDINGS:
				# Preserve the default east-facing production exit. The authoritative
				# producer can use other exits, but planners should not force a retry.
				exit = Rect2(pos + Vector2(other.footprint.x * 0.5, -1.5), Vector2(5.0, 3.0))
				covered = covered.merge(exit)
			_bucket_insert(planning, covered, [rect, exit])
		if blocker.is_queued_for_deletion() or blocker.get("is_placement_ghost") == true: continue
		if blocker.has_method("get_water_contours") and not blocker.get_water_contours().is_empty():
			water.append(blocker.get_water_contours())
			continue
		var footprint: Vector2 = other.footprint if other != null else (blocker.get("block_size") if blocker.get("block_size") is Vector2 else Vector2.ONE)
		if blocker.has_method("get_placement_footprint"):
			footprint = blocker.call("get_placement_footprint")
		var half := footprint * 0.5
		_bucket_insert(placement, Rect2(pos - half, footprint), [pos, half])
	return {"planning": planning, "placement": placement, "water": water}

static func _bucket_cells(rect: Rect2) -> Rect2i:
	# Padding only adds buckets, so float rounding at a bucket edge cannot
	# drop an overlapping blocker.
	var padded := rect.grow(0.01)
	var lo := Vector2i(floori(padded.position.x / SITE_BUCKET), floori(padded.position.y / SITE_BUCKET))
	var hi := Vector2i(floori(padded.end.x / SITE_BUCKET), floori(padded.end.y / SITE_BUCKET))
	return Rect2i(lo, hi - lo + Vector2i.ONE)

static func _bucket_insert(buckets: Dictionary, rect: Rect2, entry: Array) -> void:
	var cells := _bucket_cells(rect)
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var key := Vector2i(x, y)
			if not buckets.has(key): buckets[key] = []
			buckets[key].append(entry)

static func _planning_clear(definition: BuildingDef, pos: Vector2, base: Vector2, sites: Dictionary, bounds: Rect2) -> bool:
	var size := planning_footprint(definition)
	var area := Rect2(pos - size * 0.5, size)
	if not bounds.encloses(area.grow(1.0)): return false
	# Reserve cross-base traffic lanes even around walkable farms; this keeps
	# future walls and solid foundations from sealing the base's four exits.
	var offset := pos - base
	if absf(offset.x) < size.x * 0.5 + LANE_WIDTH * 0.5 or absf(offset.y) < size.y * 0.5 + LANE_WIDTH * 0.5: return false
	var lane := area.grow(LANE_WIDTH * 0.5)
	var planning: Dictionary = sites.planning
	var cells := _bucket_cells(lane)
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			for entry: Array in planning.get(Vector2i(x, y), []):
				if lane.intersects(entry[0]): return false
				if entry[1] is Rect2 and area.intersects(entry[1]): return false
	return true

## Build.can_place over the site index: same footprints and strict overlap.
static func _can_place(footprint: Vector2, center: Vector2, sites: Dictionary) -> bool:
	var candidate_half := footprint * 0.5
	var rect := Rect2(center - candidate_half, footprint)
	for contours in sites.water:
		if Shore.intersects_rect(rect, contours): return false
	var placement: Dictionary = sites.placement
	var cells := _bucket_cells(rect)
	for y in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			for entry: Array in placement.get(Vector2i(x, y), []):
				var building_pos: Vector2 = entry[0]
				var existing_half: Vector2 = entry[1]
				if absf(center.x - building_pos.x) < candidate_half.x + existing_half.x and absf(center.y - building_pos.y) < candidate_half.y + existing_half.y:
					return false
	return true


static func _footprint_walkable(pos: Vector2, footprint: Vector2, nav: RefCounted) -> bool:
	var lo: Vector2i = nav.world_to_cell(pos - footprint * 0.5)
	var hi: Vector2i = nav.world_to_cell(pos + footprint * 0.5 - Vector2.ONE * 0.001)
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			if nav.is_cell_solid(Vector2i(x, y)): return false
	return true


static func _army(own: Array[Node2D], snapshots: Array, derived: Dictionary, team: int, defend_radius: float, bounds: Rect2, nav: RefCounted) -> Dictionary:
	var ready: Array = []
	var scouts: Array = []
	var fallback_scouts: Array = []
	var strength := 0.0
	for unit in own:
		var definition := unit.get("def") as UnitDef
		if definition == null: continue
		var id := Registry.id_of(unit)
		if definition.id == &"villager":
			if unit.get("order") == Enums.OrderType.NONE: fallback_scouts.append(id)
			continue
		if definition.id in [&"scout_cavalry", &"light_cavalry", &"hussar"] and unit.get("order") in [Enums.OrderType.NONE, Enums.OrderType.MOVE]: scouts.append(id)
		if float(unit.get("hp")) >= definition.max_hp * 0.45: ready.append(id)
		strength += float(unit.get("hp")) / maxf(definition.max_hp, 1) * maxf(definition.attack, 1)
	if scouts.is_empty() and ready.is_empty() and not fallback_scouts.is_empty(): scouts.append(fallback_scouts[0])
	var enemies: Array = []
	var nearby: Array = []
	var enemy_strength := 0.0
	var base := Protocol.array_to_vec2(derived.get("own_tc_pos", [0, 0])) as Vector2
	for entity: Dictionary in snapshots:
		if entity.get("kind", "") not in ["unit", "building"] or int(entity.get("team", team)) == team: continue
		enemies.append(entity.id)
		if entity.kind == "unit":
			var definition := Catalog.get_unit(StringName(entity.def_id))
			if definition != null: enemy_strength += float(entity.hp) / maxf(definition.max_hp, 1) * maxf(definition.attack, 1)
			if base.distance_to(Protocol.array_to_vec2(entity.pos)) <= defend_radius: nearby.append(entity.id)
	var direction := (bounds.get_center() - base).normalized()
	if direction == Vector2.ZERO: direction = Vector2.RIGHT
	var rally: Vector2 = nav.nearest_walkable_world((base + direction * 12).clamp(bounds.position + Vector2.ONE * 2, bounds.end - Vector2.ONE * 2))
	if rally == Vector2.INF: rally = base
	return {"ready_unit_ids": ready, "scout_ids": scouts, "rally_point": Protocol.vec2_to_array(rally), "visible_enemy_ids": enemies, "enemy_near_base_ids": nearby, "own_strength": snappedf(strength, 0.1), "visible_enemy_strength": snappedf(enemy_strength, 0.1)}


static func _scouting(state: MatchState, team: int, own: Array[Node2D], bounds: Rect2, nav: RefCounted, scout_ids: Array, derived: Dictionary) -> Dictionary:
	var result := {"explored_ratio": 1.0, "frontiers": [], "probes": [], "scout_ids": scout_ids}
	if not state.fog_enabled or state.fog == null: return result
	var fog: RefCounted = state.fog
	var mask: PackedByteArray = fog.get("explored").get(team, PackedByteArray())
	var grid: Vector2i = fog.get("grid_size")
	if mask.is_empty():
		result.explored_ratio = 0.0
		return result
	var geometry := _frontier_geometry(state, team, mask, grid, bounds)
	result.explored_ratio = geometry.explored_ratio
	var candidates: Array = []
	var scout: Node2D
	for node in own:
		if Registry.id_of(node) in scout_ids:
			scout = node
			break
	if scout == null:
		# Compute viable frontiers for an emergency infantry scout, without
		# permanently reserving that soldier from the army's formation count.
		for node in own:
			if node.get("def") is UnitDef and node.get("def").id != &"villager" and node.get("order") in [Enums.OrderType.NONE, Enums.OrderType.MOVE]:
				scout = node
				break
	if scout == null: return result
	var base := Protocol.array_to_vec2(derived.get("own_tc_pos", [0, 0])) as Vector2
	var center := bounds.get_center()
	var opposite := (center * 2 - base).clamp(bounds.position + Vector2.ONE * 2, bounds.end - Vector2.ONE * 2)
	for probe in [{"kind": "map_center", "point": center}, {"kind": "opposite_sector", "point": opposite}]:
		var point: Vector2 = nav.nearest_walkable_world(probe.point, scout.get("def").resolved_footprint_radius())
		if not bounds.has_point(point) or fog.state_at(team, point) != FogOfWarService.State.UNEXPLORED: continue
		# These are public geometric guesses. The actual enemy position is never
		# consulted, even on maps whose starts are not symmetric.
		result.probes.append({"kind": probe.kind, "pos": Protocol.vec2_to_array(point)})
	for frontier: Dictionary in geometry.frontiers:
		var point: Vector2 = frontier.point
		if nav.is_world_solid(point): continue
		var distance: float = scout.get("sim_pos").distance_to(point)
		candidates.append({"pos": Protocol.vec2_to_array(point), "unknown_neighbors": frontier.unknown_neighbors, "distance": distance,
			"center_score": point.distance_to(center) + distance * 0.15, "opposite_score": point.distance_to(opposite) + distance * 0.15})
	candidates.sort_custom(func(a, b): return a.distance < b.distance)
	var selected: Array = []
	_append_frontiers(candidates, selected, scout, nav, 4)
	candidates.sort_custom(func(a, b): return a.center_score < b.center_score)
	_append_frontiers(candidates, selected, scout, nav, 8)
	candidates.sort_custom(func(a, b): return a.opposite_score < b.opposite_score)
	_append_frontiers(candidates, selected, scout, nav, MAX_FRONTIERS)
	result.frontiers = selected
	return result


## Pure exploration geometry changes only when the explored mask or map geometry
## changes. Current scout positions, blockers and routes are checked every call.
## Retain an explicit mask copy: fog exploration writes into packed arrays in
## place, so retaining the live array would hide those changes from comparison.
static func _frontier_geometry(state: MatchState, team: int, mask: PackedByteArray, grid: Vector2i, bounds: Rect2) -> Dictionary:
	var origin: Vector2 = state.fog.get("map_origin")
	var size: float = state.fog.get("cell_size")
	var caches: Dictionary = state.get_meta(FRONTIER_CACHE_META, {})
	var previous: Dictionary = caches.get(team, {})
	if not previous.is_empty() and previous.mask == mask and previous.grid == grid and previous.origin == origin and previous.cell_size == size and previous.bounds == bounds:
		return previous
	var count := 0
	for value in mask:
		if value != 0: count += 1
	var frontiers: Array = []
	var stride := maxi(1, ceili(4.0 / size))
	for y in range(1, grid.y - 1, stride):
		for x in range(1, grid.x - 1, stride):
			var index := y * grid.x + x
			if mask[index] == 0: continue
			var unknown := 0
			var direction := Vector2.ZERO
			for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if mask[index + offset.y * grid.x + offset.x] == 0:
					unknown += 1
					direction += Vector2(offset)
			if unknown == 0: continue
			var point := origin + (Vector2(x, y) + Vector2.ONE * 0.5) * size + direction.normalized() * 4.0
			point = point.clamp(bounds.position + Vector2.ONE * 2, bounds.end - Vector2.ONE * 2)
			frontiers.append({"point": point, "unknown_neighbors": unknown})
	var result := {"mask": mask.duplicate(), "grid": grid, "origin": origin, "cell_size": size, "bounds": bounds,
		"explored_ratio": snappedf(float(count) / mask.size(), 0.0001), "frontiers": frontiers}
	caches[team] = result
	state.set_meta(FRONTIER_CACHE_META, caches)
	return result


static func _append_frontiers(candidates: Array, selected: Array, scout: Node2D, nav: RefCounted, limit: int) -> void:
	var route_checks := 0
	for candidate: Dictionary in candidates:
		if selected.size() >= limit or route_checks >= 12: return
		var point := Protocol.array_to_vec2(candidate.pos) as Vector2
		if selected.any(func(item): return point.distance_to(Protocol.array_to_vec2(item.pos)) < 10): continue
		route_checks += 1
		var path: PackedVector2Array = nav.find_path(scout.get("sim_pos"), point, scout.get("def").resolved_footprint_radius())
		if path.is_empty() or path[-1].distance_to(point) > 2: continue
		var entry := candidate.duplicate()
		entry.erase("distance")
		entry.erase("center_score")
		entry.erase("opposite_score")
		selected.append(entry)
