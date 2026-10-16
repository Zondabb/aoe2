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
const MAX_FRONTIERS := 12
const POSITIONS_PER_BUILDING := 3
const MAX_ROUTE_CHECKS_PER_BUILDING := 4
const MILITARY_BUILDINGS := ["barracks", "archery_range", "stable", "siege_workshop", "castle"]
const PLANNING_SCALE := 4.0
const FARM_RESERVE_RADIUS := 22.0
const LANE_WIDTH := 3.0
const BUILD_PRIORITY := ["barracks", "house", "farm", "mill", "lumber_camp", "mining_camp", "archery_range", "stable", "blacksmith", "market", "siege_workshop", "castle", "town_center", "monastery", "university"]

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


static func build(state: MatchState, entities: Node2D, team: int, snapshots: Array, derived: Dictionary, defend_radius: float) -> Dictionary:
	var own: Array[Node2D] = []
	var builders: Array[Node2D] = []
	var known_static: Array = []
	var placement_blockers: Array = []
	var civ: CivDef
	var observed_ids := {}
	for snapshot: Dictionary in snapshots: observed_ids[snapshot.id] = true
	for node in entities.get_children():
		if not node is Node2D or node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: continue
		var definition: Variant = node.get("def")
		if definition is UnitDef or definition is BuildingDef:
			if float(node.get("hp")) <= 0: continue
			if int(node.get("team")) == team:
				own.append(node)
				if civ == null: civ = node.get("civ") as CivDef
				if definition is UnitDef and definition.id == &"villager": builders.append(node)
		if not FogAccess.state_can_see(state, team, node): continue
		if (definition is BuildingDef or definition is UnitDef or node.has_method("extract")) and not observed_ids.has(Registry.id_of(node)): continue
		if definition is BuildingDef or node.is_in_group("terrain_regions"):
			placement_blockers.append(node)
			known_static.append(node)
		elif node.has_method("extract"):
			known_static.append(node)
	var catalog := _catalog(state, entities, team, civ)
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
	nav.rebuild_from_blockers(known_static)
	var army := _army(own, snapshots, derived, team, defend_radius, bounds, nav)
	return {
		"catalog": catalog,
		"construction_options": _construction_options(state, team, builders, catalog.buildings, placement_blockers, bounds, nav, derived, snapshots),
		"layout": {"base": derived.get("own_tc_pos", [0, 0]), "farm_reserve_radius": FARM_RESERVE_RADIUS, "lane_width": LANE_WIDTH, "planning_scale": PLANNING_SCALE},
		"scouting": _scouting(state, team, own, bounds, nav, army.scout_ids, derived),
		"army": army,
	}


static func _catalog(state: MatchState, entities: Node2D, team: int, civ: CivDef) -> Dictionary:
	var age := state.age_of(team)
	var civ_id: StringName = civ.id if civ != null else StringName(state.team_civilizations.get(team, ""))
	var buildings: Array = []
	for id in BUILD_PRIORITY:
		var definition := Catalog.get_building(id)
		if definition == null or (state.progression_enabled and definition.required_age > age + 1): continue
		if civ_id != &"" and not definition.civilizations.is_empty() and civ_id not in definition.civilizations: continue
		var reason := Catalog.building_reason(state, team, civ, definition, entities)
		buildings.append({"id": id, "cost": _cost(definition), "footprint": Protocol.vec2_to_array(definition.footprint), "build_time": definition.build_time, "population_provided": definition.population_provided, "required_age": definition.required_age, "prerequisites": definition.prerequisites, "required_technology": Catalog.building_record(definition.id).get("required_technology", ""), "available": reason.is_empty(), "blocked_reason": reason})
		buildings[-1]["planning_footprint"] = Protocol.vec2_to_array(planning_footprint(definition))
		buildings[-1]["blocks_movement"] = definition.blocks_movement
		buildings[-1]["has_drop_off"] = definition.has_drop_off
	var units: Array = []
	for definition: UnitDef in Catalog.units().values():
		if state.progression_enabled and definition.required_age > age + 1: continue
		if civ_id != &"" and not definition.civilizations.is_empty() and civ_id not in definition.civilizations: continue
		units.append({"id": String(definition.id), "cost": _cost(definition), "population": definition.population, "train_at": String(definition.train_at), "train_time": definition.train_time, "required_age": definition.required_age, "required_technology": String(definition.required_technology), "unlocked": state.unit_unlocked(team, definition, civ_id), "attack": definition.attack, "attack_range": definition.attack_range, "vision_radius": definition.resolved_vision_radius(age)})
		units[-1]["is_ranged"] = definition.is_ranged
		units[-1]["minimum_range"] = definition.minimum_attack_range
		units[-1]["attack_class_bonuses"] = definition.attack_class_bonuses
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
	var direction := (bounds.get_center() - base).normalized()
	if direction == Vector2.ZERO: direction = Vector2.RIGHT
	for record: Dictionary in records:
		# Resource shortages do not invalidate geometry: the planner can save up.
		if not record.available and record.blocked_reason != "资源不足": continue
		var definition := Catalog.get_building(record.id)
		var zone := "military" if record.id in MILITARY_BUILDINGS else "farm" if record.id == "farm" else "residential"
		var anchors: Array = [{"pos": base, "resource_id": null}]
		var radii: Array = [26.0, 30.0, 34.0, 44.0]
		if zone == "farm":
			radii = [18.0, 22.0, 28.0, 36.0, 44.0]
			anchors = _farm_anchors(snapshots, team, base, int(derived.get("own_tc_id", -1)))
		if record.id in ["lumber_camp", "mining_camp", "mill"]:
			zone = "resource_drop_off"
			anchors = _resource_anchors(record.id, snapshots, base)
			radii = [10.0, 14.0, 18.0]
			if anchors.is_empty() and record.id == "mill": anchors = [{"pos": base, "resource_id": null}]
			if record.id == "mill" and anchors.size() == 1 and anchors[0].resource_id == null: radii = [26.0, 34.0]
		var candidates: Array = []
		var seen := {}
		for anchor: Dictionary in anchors:
			for radius in anchor.get("radii", radii):
				for sector in 16:
					var point: Vector2 = (anchor.pos + Vector2.from_angle(TAU * (sector + 0.5) / 16.0) * float(radius)).round()
					if seen.has(point): continue
					seen[point] = true
					if zone == "military" and point.distance_to(base) < FARM_RESERVE_RADIUS + planning_footprint(definition).length() * 0.25: continue
					if not _planning_clear(definition, point, base, blockers, bounds): continue
					if state.fog_enabled and (state.fog == null or not state.fog.footprint_visible(team, point, definition.footprint, true)): continue
					if not Build.can_place(definition.footprint, point, blockers) or not _footprint_walkable(point, definition.footprint, nav): continue
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


static func _planning_clear(definition: BuildingDef, pos: Vector2, base: Vector2, blockers: Array, bounds: Rect2) -> bool:
	var size := planning_footprint(definition)
	var area := Rect2(pos - size * 0.5, size)
	if not bounds.encloses(area.grow(1.0)): return false
	# Reserve cross-base traffic lanes even around walkable farms; this keeps
	# future walls and solid foundations from sealing the base's four exits.
	var offset := pos - base
	if absf(offset.x) < size.x * 0.5 + LANE_WIDTH * 0.5 or absf(offset.y) < size.y * 0.5 + LANE_WIDTH * 0.5: return false
	for blocker in blockers:
		var other: BuildingDef = blocker.get("def")
		if other == null: continue
		var other_pos: Vector2 = blocker.get("sim_pos")
		var other_size := planning_footprint(other)
		if area.grow(LANE_WIDTH * 0.5).intersects(Rect2(other_pos - other_size * 0.5, other_size)): return false
		if String(other.id) in MILITARY_BUILDINGS:
			# Preserve the default east-facing production exit. The authoritative
			# producer can use other exits, but planners should not force a retry.
			var exit := Rect2(other_pos + Vector2(other.footprint.x * 0.5, -1.5), Vector2(5.0, 3.0))
			if area.intersects(exit): return false
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
	var explored_count := 0
	for value in mask:
		if value != 0: explored_count += 1
	result.explored_ratio = snappedf(float(explored_count) / mask.size(), 0.0001)
	var candidates: Array = []
	var origin: Vector2 = fog.get("map_origin")
	var size: float = fog.get("cell_size")
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
			# A small outward probe reveals new cells. Its direction is derived only
			# from exploration history; it does not claim the unknown land is clear.
			var point := origin + (Vector2(x, y) + Vector2.ONE * 0.5) * size + direction.normalized() * 4.0
			point = point.clamp(bounds.position + Vector2.ONE * 2, bounds.end - Vector2.ONE * 2)
			if nav.is_world_solid(point): continue
			var distance: float = scout.get("sim_pos").distance_to(point)
			candidates.append({"pos": Protocol.vec2_to_array(point), "unknown_neighbors": unknown, "distance": distance})
	candidates.sort_custom(func(a, b): return a.distance < b.distance)
	var selected: Array = []
	_append_frontiers(candidates, selected, scout, nav, 4)
	candidates.sort_custom(func(a, b): return Protocol.array_to_vec2(a.pos).distance_to(center) + a.distance * 0.15 < Protocol.array_to_vec2(b.pos).distance_to(center) + b.distance * 0.15)
	_append_frontiers(candidates, selected, scout, nav, 8)
	candidates.sort_custom(func(a, b): return Protocol.array_to_vec2(a.pos).distance_to(opposite) + a.distance * 0.15 < Protocol.array_to_vec2(b.pos).distance_to(opposite) + b.distance * 0.15)
	_append_frontiers(candidates, selected, scout, nav, MAX_FRONTIERS)
	result.frontiers = selected
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
		selected.append(entry)
