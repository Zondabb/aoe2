# scripts/systems/ai_controller.gd
class_name AiController
extends Node

enum Phase { ECO, MILITARY, ATTACK }

const TICK_INTERVAL := 0.5
const VILLAGER_TARGET := 8
const HIGH_FOOD_STOCKPILE := 400
const MILITARY_ATTACK_COUNT := 6
const ATTACK_TIME_SECONDS := 180.0
const RETARGET_RADIUS := 8.0
const FOOD_RATIO := 0.5
const WOOD_RATIO := 0.3
const GOLD_RATIO := 0.2

const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const ARCHERY_RANGE: BuildingDef = preload("res://data/buildings/archery_range.tres")
const STABLE: BuildingDef = preload("res://data/buildings/stable.tres")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const SWORDSMAN: UnitDef = preload("res://data/units/swordsman.tres")
const ARCHER: UnitDef = preload("res://data/units/archer.tres")
const BuildSystemScript := preload("res://scripts/systems/build_system.gd")

var match_state: MatchState
var entities: Node2D
var ai_civ: CivDef
var player_team: Enums.Team = Enums.Team.PLAYER
var ai_team: Enums.Team = Enums.Team.AI
var phase: Phase = Phase.ECO
var match_time := 0.0
var enabled := true

var _tick_accum := 0.0
var _next_build_slot := 0

func setup(
	state: MatchState,
	entities_root: Node2D,
	civ: CivDef,
	ai_side: Enums.Team = Enums.Team.AI,
	player_side: Enums.Team = Enums.Team.PLAYER
) -> void:
	match_state = state
	entities = entities_root
	ai_civ = civ
	ai_team = ai_side
	player_team = player_side
	phase = Phase.ECO
	match_time = 0.0
	_tick_accum = 0.0
	_next_build_slot = 0
	enabled = true
	set_process(true)

func stop() -> void:
	enabled = false
	set_process(false)

func _process(delta: float) -> void:
	if not enabled or match_state == null:
		return
	if match_state.winner != -1:
		stop()
		return
	match_time += delta
	_tick_accum += delta
	if _tick_accum < TICK_INTERVAL:
		return
	_tick_accum = 0.0
	evaluate()

func evaluate() -> void:
	if not enabled or match_state == null or entities == null:
		return
	if match_state.winner != -1:
		stop()
		return
	_update_phase()
	_assign_builders()
	_assign_idle_villagers()
	match phase:
		Phase.ECO:
			_eco_actions()
		Phase.MILITARY:
			_military_actions()
		Phase.ATTACK:
			_military_actions()
			_attack_actions()

func _update_phase() -> void:
	if phase == Phase.ATTACK:
		return
	var military_count := _count_military()
	if military_count >= MILITARY_ATTACK_COUNT or match_time >= ATTACK_TIME_SECONDS:
		phase = Phase.ATTACK
		return
	if phase == Phase.ECO:
		var food := match_state.get_resource(ai_team, Enums.ResourceType.FOOD)
		if _count_villagers() >= VILLAGER_TARGET or food >= HIGH_FOOD_STOCKPILE:
			phase = Phase.MILITARY

func _eco_actions() -> void:
	_train_villagers()
	_ensure_house_if_pop_blocked(VILLAGER)

func _military_actions() -> void:
	_ensure_military_buildings()
	_train_military()
	_ensure_house_if_pop_blocked(_preferred_military_unit())

func _attack_actions() -> void:
	var enemy_tc := _find_town_center(player_team)
	for unit in _ai_units():
		var unit_def := unit.get("def") as UnitDef
		if unit_def == null or unit_def.id == &"villager":
			continue
		var nearby := _nearest_hostile_in_radius(unit, RETARGET_RADIUS)
		if nearby != null:
			if unit.get("order") != Enums.OrderType.ATTACK or unit.get("_attack_target") != nearby:
				unit.call("command_attack", nearby)
			continue
		if enemy_tc != null:
			if unit.get("order") != Enums.OrderType.ATTACK or unit.get("_attack_target") != enemy_tc:
				unit.call("command_attack", enemy_tc)
		else:
			unit.call("command_move", Vector2(-40.0, -40.0))

func _train_villagers() -> void:
	if _count_villagers() >= VILLAGER_TARGET:
		return
	var town_center := _find_town_center(ai_team)
	if town_center == null:
		return
	_try_enqueue(town_center, VILLAGER)

func _train_military() -> void:
	var unique := ai_civ.unique_unit if ai_civ != null else null
	if unique != null:
		var unique_building := _find_building_for_unit(unique)
		if unique_building != null and _try_enqueue(unique_building, unique):
			return
	var barracks := _find_complete_building(&"barracks")
	if barracks != null and _try_enqueue(barracks, SWORDSMAN):
		return
	var archery := _find_complete_building(&"archery_range")
	if archery != null:
		_try_enqueue(archery, ARCHER)

func _preferred_military_unit() -> UnitDef:
	if ai_civ != null and ai_civ.unique_unit != null:
		return ai_civ.unique_unit
	return SWORDSMAN

func _ensure_military_buildings() -> void:
	_ensure_building(BARRACKS)
	_ensure_building(ARCHERY_RANGE)
	if ai_civ != null and ai_civ.id == &"teutons":
		_ensure_building(STABLE)

func _ensure_house_if_pop_blocked(unit_def: UnitDef) -> void:
	if unit_def == null or match_state == null:
		return
	if not match_state.can_afford(
		ai_team, unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold
	):
		return
	if match_state.can_train(ai_team, unit_def):
		return
	_ensure_building(HOUSE)

func _ensure_building(building_def: BuildingDef) -> void:
	if building_def == null:
		return
	if building_def.id != &"house" and _has_building(building_def.id):
		return
	if _has_incomplete_building(building_def.id):
		return
	if not match_state.can_afford(
		ai_team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold
	):
		return
	var builder := _idle_villager()
	if builder == null:
		builder = _any_villager()
	if builder == null:
		return
	var place_position: Variant = _next_build_position(building_def)
	if place_position == null:
		return
	if not match_state.spend(
		ai_team,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold
	):
		return
	var foundation := BUILDING_VIEW.instantiate() as Node2D
	foundation.name = "Ai%sFoundation%d" % [
		String(building_def.id).to_pascal_case(),
		_next_build_slot,
	]
	foundation.set("team", ai_team)
	foundation.set("def", building_def)
	foundation.set("civ", ai_civ)
	foundation.set("match_state", match_state)
	foundation.set("sim_pos", place_position)
	foundation.call("start_construction")
	entities.add_child(foundation)
	builder.call("command_build", foundation)
	_next_build_slot += 1

func _next_build_position(building_def: BuildingDef) -> Variant:
	var town_center := _find_town_center(ai_team)
	if town_center == null or entities == null:
		return null
	var existing: Array = []
	for node in entities.get_children():
		if node.get("def") is BuildingDef:
			existing.append(node)
	var offsets := [
		Vector2(-8.0, 0.0),
		Vector2(-8.0, -6.0),
		Vector2(-6.0, 8.0),
		Vector2(0.0, -8.0),
		Vector2(-12.0, 2.0),
		Vector2(-10.0, -10.0),
		Vector2(-4.0, 10.0),
		Vector2(-14.0, -4.0),
		Vector2(2.0, -10.0),
		Vector2(-16.0, 6.0),
	]
	var origin: Vector2 = town_center.get("sim_pos")
	for index in offsets.size():
		var slot := (_next_build_slot + index) % offsets.size()
		var candidate: Vector2 = origin + offsets[slot]
		if BuildSystemScript.can_place(building_def.footprint, candidate, existing):
			return candidate
	return null

func _assign_builders() -> void:
	for building in _ai_buildings():
		if bool(building.get("is_complete")):
			continue
		var has_builder := false
		for villager in _ai_villagers():
			if (
				villager.get("order") == Enums.OrderType.BUILD
				and villager.get("_build_target") == building
			):
				has_builder = true
				break
		if has_builder:
			continue
		var idle := _idle_villager()
		if idle != null:
			idle.call("command_build", building)

func _assign_idle_villagers() -> void:
	var counts := {
		Enums.ResourceType.FOOD: 0,
		Enums.ResourceType.WOOD: 0,
		Enums.ResourceType.GOLD: 0,
	}
	var idle: Array[Node2D] = []
	for villager in _ai_villagers():
		var order: Enums.OrderType = villager.get("order")
		if order == Enums.OrderType.NONE:
			idle.append(villager)
			continue
		if order != Enums.OrderType.GATHER:
			continue
		var resource := villager.get("_last_resource") as Node2D
		if resource == null or not is_instance_valid(resource):
			continue
		var resource_type: int = int(resource.get("resource_type"))
		if counts.has(resource_type):
			counts[resource_type] = int(counts[resource_type]) + 1
	var assigned := (
		int(counts[Enums.ResourceType.FOOD])
		+ int(counts[Enums.ResourceType.WOOD])
		+ int(counts[Enums.ResourceType.GOLD])
	)
	for villager in idle:
		var total := assigned + 1
		var target_type := _underfilled_resource_type(counts, total)
		var resource := _nearest_resource(villager, target_type)
		if resource == null:
			resource = _nearest_any_resource(villager)
		if resource == null:
			continue
		villager.call("command_gather", resource)
		var resource_type: int = int(resource.get("resource_type"))
		if counts.has(resource_type):
			counts[resource_type] = int(counts[resource_type]) + 1
		assigned += 1

func _underfilled_resource_type(counts: Dictionary, total: int) -> Enums.ResourceType:
	var targets := {
		Enums.ResourceType.FOOD: FOOD_RATIO,
		Enums.ResourceType.WOOD: WOOD_RATIO,
		Enums.ResourceType.GOLD: GOLD_RATIO,
	}
	var best_type: Enums.ResourceType = Enums.ResourceType.FOOD
	var best_deficit := -INF
	for resource_type in targets.keys():
		var actual := float(counts[resource_type]) / float(maxi(total, 1))
		var deficit: float = float(targets[resource_type]) - actual
		if deficit > best_deficit:
			best_deficit = deficit
			best_type = resource_type
	return best_type

func _try_enqueue(building: Node2D, unit_def: UnitDef) -> bool:
	if building == null or unit_def == null:
		return false
	if not bool(building.get("is_complete")):
		return false
	if not (building.get("train_queue") as Array).is_empty():
		return false
	return bool(building.call("enqueue_train", unit_def))

func _find_building_for_unit(unit_def: UnitDef) -> Node2D:
	if unit_def == null:
		return null
	if unit_def.id == &"teutonic_knight":
		return _find_complete_building(&"stable")
	if unit_def.id == &"chu_ko_nu" or unit_def.id == &"archer":
		return _find_complete_building(&"archery_range")
	if unit_def.id == &"swordsman":
		return _find_complete_building(&"barracks")
	if unit_def.id == &"villager":
		return _find_town_center(ai_team)
	return null

func _count_villagers() -> int:
	return _ai_villagers().size()

func _count_military() -> int:
	var count := 0
	for unit in _ai_units():
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id != &"villager":
			count += 1
	return count

func _ai_units() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if entities == null:
		return result
	for node in entities.get_children():
		if node.get("team") != ai_team:
			continue
		if node.get("def") is UnitDef:
			result.append(node as Node2D)
	return result

func _ai_villagers() -> Array[Node2D]:
	var result: Array[Node2D] = []
	for unit in _ai_units():
		var unit_def := unit.get("def") as UnitDef
		if unit_def != null and unit_def.id == &"villager":
			result.append(unit)
	return result

func _ai_buildings() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if entities == null:
		return result
	for node in entities.get_children():
		if node.get("team") != ai_team:
			continue
		if node.get("def") is BuildingDef:
			result.append(node as Node2D)
	return result

func _idle_villager() -> Node2D:
	for villager in _ai_villagers():
		if villager.get("order") == Enums.OrderType.NONE:
			return villager
	return null

func _any_villager() -> Node2D:
	var villagers := _ai_villagers()
	return villagers[0] if not villagers.is_empty() else null

func _has_building(building_id: StringName) -> bool:
	for building in _ai_buildings():
		var building_def := building.get("def") as BuildingDef
		if building_def != null and building_def.id == building_id:
			return true
	return false

func _has_incomplete_building(building_id: StringName) -> bool:
	for building in _ai_buildings():
		var building_def := building.get("def") as BuildingDef
		if (
			building_def != null
			and building_def.id == building_id
			and not bool(building.get("is_complete"))
		):
			return true
	return false

func _find_complete_building(building_id: StringName) -> Node2D:
	for building in _ai_buildings():
		var building_def := building.get("def") as BuildingDef
		if (
			building_def != null
			and building_def.id == building_id
			and bool(building.get("is_complete"))
		):
			return building
	return null

func _find_town_center(team: Enums.Team) -> Node2D:
	if entities == null:
		return null
	for node in entities.get_children():
		if node.get("team") != team:
			continue
		var building_def := node.get("def") as BuildingDef
		if building_def != null and building_def.id == &"town_center":
			return node as Node2D
	return null

func _nearest_resource(from_unit: Node2D, resource_type: Enums.ResourceType) -> Node2D:
	var nearest: Node2D
	var nearest_distance := INF
	for node in _resource_nodes():
		if int(node.get("resource_type")) != int(resource_type):
			continue
		if float(node.get("amount")) <= 0.0:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest

func _nearest_any_resource(from_unit: Node2D) -> Node2D:
	var nearest: Node2D
	var nearest_distance := INF
	for node in _resource_nodes():
		if float(node.get("amount")) <= 0.0:
			continue
		var distance: float = from_unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance < nearest_distance:
			nearest = node
			nearest_distance = distance
	return nearest

func _resource_nodes() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if entities == null:
		return result
	for node in entities.get_children():
		if node.has_method("extract"):
			result.append(node as Node2D)
	return result

func _nearest_hostile_in_radius(unit: Node2D, radius: float) -> Node2D:
	var nearest: Node2D
	var nearest_distance := INF
	var radius_squared := radius * radius
	for node in entities.get_children():
		if node.get("team") != player_team:
			continue
		if node.get("is_placement_ghost") == true:
			continue
		if not node.has_method("take_damage"):
			continue
		if float(node.get("hp")) <= 0.0:
			continue
		var distance: float = unit.get("sim_pos").distance_squared_to(node.get("sim_pos"))
		if distance <= radius_squared and distance < nearest_distance:
			nearest = node as Node2D
			nearest_distance = distance
	return nearest
