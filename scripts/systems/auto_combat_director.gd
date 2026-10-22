class_name AutoCombatDirector
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

## Periodic hostile scan + command_attack for arena / skirmish demos.

const ArenaConfigScript := preload("res://scripts/data/arena_config.gd")

const DEFAULT_TICK_INTERVAL := 0.5
const DEFAULT_AGGRO_RADIUS := 40.0
const DEFAULT_RETARGET_RADIUS := 12.0
## Scorpions remain anti-unit weapons; demolition siege acquires structures.
const DEMOLITION_UNITS := ["battering_ram", "capped_ram", "siege_ram", "mangonel", "onager", "siege_onager", "trebuchet", "bombard_cannon"]

var tick_interval := DEFAULT_TICK_INTERVAL
var aggro_radius := DEFAULT_AGGRO_RADIUS
var retarget_radius := DEFAULT_RETARGET_RADIUS
var include_buildings := true
var prefer_units_over_buildings := true

var _entities: Node2D
var _match_state: MatchState
var _team_auto: Dictionary = {}
var _tick_accum := 0.0
var _enabled := true


func setup(entities: Node2D, match_state: MatchState = null) -> void:
	_entities = entities
	_match_state = match_state
	_tick_accum = 0.0


func apply_arena_config(config: ArenaConfigScript) -> void:
	if config == null:
		return
	set_team_auto_attack(Enums.Team.PLAYER, config.player_auto_attack)
	set_team_auto_attack(Enums.Team.AI, config.ai_auto_attack)
	tick_interval = config.tick_interval
	aggro_radius = config.aggro_radius
	include_buildings = config.include_buildings


func set_team_auto_attack(team: Enums.Team, enabled: bool) -> void:
	_team_auto[team] = enabled


func is_team_auto_enabled(team: Enums.Team) -> bool:
	return bool(_team_auto.get(team, false))


func set_enabled(enabled: bool) -> void:
	_enabled = enabled


func reset_timer() -> void:
	_tick_accum = 0.0


func tick(delta: float) -> void:
	if not _enabled or _entities == null:
		return
	if _match_state != null and _match_state.frozen:
		return
	_tick_accum += delta
	if _tick_accum < tick_interval:
		return
	_tick_accum = 0.0
	_run_tick()


func _run_tick() -> void:
	for unit in _living_units():
		if not _unit_wants_auto_combat(unit):
			continue
		var current: Variant = unit.get("_attack_target")
		if _should_keep_current_target(unit, current):
			continue
		var target := pick_target_for_unit(unit)
		if target == null:
			continue
		if unit.has_method("command_attack"):
			unit.call("command_attack", target)


func _unit_wants_auto_combat(unit: Object) -> bool:
	var team: Enums.Team = unit.get("team")
	if not is_team_auto_enabled(team):
		return false
	var order: Enums.OrderType = unit.get("order")
	if order == Enums.OrderType.MOVE or order == Enums.OrderType.GATHER or order == Enums.OrderType.BUILD:
		return false
	return true


func _should_keep_current_target(unit: Object, current: Variant) -> bool:
	if current == null or not (current is Node):
		return false
	var target := current as Node
	if not _is_valid_hostile(unit, target):
		return false
	return unit.get("order") == Enums.OrderType.ATTACK


func pick_target_for_unit(unit: Object) -> Node:
	var hostiles := _hostiles_in_aggro(unit)
	hostiles = hostiles.filter(func(target): return _friendly_blast_clear(unit, target))
	if hostiles.is_empty():
		return null
	var unit_pos: Vector2 = unit.get("sim_pos")
	var definition := unit.get("def") as UnitDef
	if definition != null and String(definition.id) in DEMOLITION_UNITS:
		var structures: Array[Node] = []
		for hostile in hostiles:
			if hostile.get("def") is BuildingDef:
				structures.append(hostile)
		if not structures.is_empty():
			return _nearest_from(unit_pos, structures)
		# Rams cannot catch fleeing workers and deal negligible unit damage.
		# Their escort engages those targets while the ram awaits a structure.
		if not definition.is_ranged:
			return null
	if prefer_units_over_buildings:
		var units_only: Array[Node] = []
		for hostile in hostiles:
			if hostile.get("def") is UnitDef:
				units_only.append(hostile)
		if not units_only.is_empty():
			return _nearest_from(unit_pos, units_only)
		if include_buildings:
			var buildings_only: Array[Node] = []
			for hostile in hostiles:
				if hostile.get("def") is BuildingDef:
					buildings_only.append(hostile)
			if not buildings_only.is_empty():
				return _nearest_from(unit_pos, buildings_only)
		return null
	return _nearest_from(unit_pos, hostiles)


func _friendly_blast_clear(unit: Object, target: Node) -> bool:
	var definition := unit.get("def") as UnitDef
	if definition == null or not definition.is_ranged or not definition.projectile_friendly_fire:
		return true
	var impact := ProjectileAgent.aim_point_for_target(unit.get("sim_pos"), target as Node2D)
	var radius := maxf(0.15, definition.projectile_splash_radius)
	for ally in _entities.get_children():
		if ally == unit or ally.get("team") != unit.get("team") or not ally.has_method("take_damage"):
			continue
		if float(ally.get("hp")) <= 0 or ally.get("is_placement_ghost") == true:
			continue
		var center: Vector2 = ally.get("sim_pos")
		var building := ally.get("def") as BuildingDef
		if building != null:
			var half: Vector2 = (ally.get_placement_footprint() if ally.has_method("get_placement_footprint") else building.footprint) * 0.5
			center += (impact - center).clamp(-half, half)
		if center.distance_to(impact) <= radius:
			return false
	return true


func _hostiles_in_aggro(unit: Object) -> Array[Node]:
	var result: Array[Node] = []
	var enemy_team: Enums.Team = (
		Enums.Team.AI if unit.get("team") == Enums.Team.PLAYER else Enums.Team.PLAYER
	)
	var vision := _vision_service()
	if vision != null and vision.has_method("hostiles_in_radius"):
		for hostile in vision.call("hostiles_in_radius", unit, enemy_team, aggro_radius):
			var node := hostile as Node
			if node == null:
				continue
			if node.get("def") is BuildingDef and not include_buildings:
				continue
			result.append(node)
		return result
	for hostile in _hostiles_for_unit(unit):
		var unit_pos: Vector2 = unit.get("sim_pos")
		var hostile_pos: Vector2 = hostile.get("sim_pos")
		if unit_pos.distance_squared_to(hostile_pos) <= aggro_radius * aggro_radius:
			result.append(hostile)
	return result


func _vision_service() -> Object:
	if _entities == null or not _entities.is_inside_tree():
		return null
	var holders := _entities.get_tree().get_nodes_in_group("vision_service")
	if holders.is_empty():
		return null
	var holder := holders[0]
	if holder.has_meta("vision"):
		return holder.get_meta("vision")
	return null


func _hostiles_for_unit(unit: Object) -> Array[Node]:
	var result: Array[Node] = []
	if _entities == null:
		return result
	for child in _entities.get_children():
		var node := child as Node
		if node == null or not is_instance_valid(node):
			continue
		if not _is_valid_hostile(unit, node):
			continue
		if node.get("def") is BuildingDef and not include_buildings:
			continue
		result.append(node)
	return result


static func _is_valid_hostile(unit: Object, target: Node) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not FogAccess.can_see(unit, target):
		return false
	if target.get("team") == unit.get("team"):
		return false
	if target.get("is_placement_ghost") == true:
		return false
	if not target.has_method("take_damage"):
		return false
	if float(target.get("hp")) <= 0.0:
		return false
	return true


static func _nearest_from(from_pos: Vector2, candidates: Array[Node]) -> Node:
	var best: Node = null
	var best_dist := INF
	for candidate in candidates:
		if candidate == null or not is_instance_valid(candidate):
			continue
		var dist := from_pos.distance_squared_to(candidate.get("sim_pos"))
		if dist < best_dist:
			best_dist = dist
			best = candidate
	return best


func _living_units() -> Array[Node]:
	var result: Array[Node] = []
	if _entities == null:
		return result
	for child in _entities.get_children():
		if not child.is_in_group("units"):
			continue
		if float(child.get("hp")) <= 0.0:
			continue
		if child.get("def") is UnitDef:
			result.append(child as Node)
	return result
