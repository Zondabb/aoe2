class_name AiBlackboard
extends RefCounted

const FogAccess := preload("res://scripts/systems/fog_access.gd")

## 每 tick 从场面快照的「黑板」：AiDirector.evaluate() 开头调用 refresh()，
## 各 manager 只读 ctx.blackboard，不直接扫 Entities。
##
## 数据流：
##   AiDirector._process (0.5s) → evaluate() → blackboard.refresh()
##   → Economy / Build / Production / Army / Combat 读黑板决策
##   → _update_phase() 用 villager_count、military_count、threat_near_base 切阶段

var match_time := 0.0
var ai_team: Enums.Team = Enums.Team.AI
var enemy_team: Enums.Team = Enums.Team.PLAYER

## 本方资源与人口（来自 MatchState）。
var food := 0
var wood := 0
var gold := 0
var stone := 0
var pop_used := 0
var pop_cap := 0

## 单位统计；incomplete_buildings 用于建造/派工优先级。
var villager_count := 0
var military_count := 0
var incomplete_buildings := 0

## 双方城镇中心位置；threat_near_base 驱动 DEFEND 阶段。
var own_tc_pos := Vector2.ZERO
var enemy_tc_pos := Vector2.ZERO
var map_bounds := Rect2()
var threat_near_base := false

## 本方实体列表 + 全图资源点（资源不分阵营）。
var team_units: Array[Node2D] = []
var team_villagers: Array[Node2D] = []
var team_buildings: Array[Node2D] = []
var resource_nodes: Array[Node2D] = []


## 重建黑板：清空后遍历 Entities 子节点，分类统计。
## defend_radius：敌方存活单位距 own_tc_pos 在此范围内则 threat_near_base=true。
func refresh(
	match_state: MatchState,
	entities: Node2D,
	team: Enums.Team,
	enemy: Enums.Team,
	match_time_seconds: float,
	defend_radius: float
) -> void:
	match_time = match_time_seconds
	ai_team = team
	enemy_team = enemy
	team_units.clear()
	team_villagers.clear()
	team_buildings.clear()
	resource_nodes.clear()
	villager_count = 0
	military_count = 0
	incomplete_buildings = 0
	own_tc_pos = Vector2.ZERO
	enemy_tc_pos = Vector2.ZERO
	threat_near_base = false

	if match_state == null or entities == null:
		return
	map_bounds = match_state.map_bounds

	food = match_state.get_resource(team, Enums.ResourceType.FOOD)
	wood = match_state.get_resource(team, Enums.ResourceType.WOOD)
	gold = match_state.get_resource(team, Enums.ResourceType.GOLD)
	stone = match_state.get_resource(team, Enums.ResourceType.STONE)
	pop_used = int(match_state.population.get(team, 0))
	pop_cap = int(match_state.population_cap.get(team, 0))

	var holder := _fog_holder(match_state, entities)
	var candidates: Array = holder.live_entities() if holder != null else entities.get_children()
	for node in candidates:
		# Generated forests dominate the snapshot. Use the match's static fog
		# result instead of rediscovering properties and footprint cells per tree.
		if node is ResourceNode:
			if not match_state.fog_enabled or (holder.entity_visible_for(team, node, node.sim_pos, node.block_size) if holder != null else FogAccess.state_can_see(match_state, team, node)):
				resource_nodes.append(node)
			continue
		if node is BuildingAgent and node.def != null:
			if node.is_placement_ghost:
				continue
			if match_state.fog_enabled and not (holder.entity_visible_for(team, node, node.sim_pos, node.def.footprint) if holder != null else FogAccess.state_can_see(match_state, team, node)):
				continue
			if node.has_method("extract") and node.is_complete:
				resource_nodes.append(node)
			_read_building(node, node.def, node.team, node.sim_pos, node.is_complete, team, enemy)
			continue
		if node is UnitAgent and node.def != null:
			# A living owned unit is always visible. Hostile/dead units still use
			# the current mask so moving across fog never reuses static visibility.
			if match_state.fog_enabled and not (node.team == team and node.hp > 0.0) and not FogAccess.state_can_see(match_state, team, node):
				continue
			_read_unit(node, node.def, node.team, node.hp, node.sim_pos, team, defend_radius)
			continue
		# Legacy arenas and observation fixtures may expose def/extract without
		# extending the runtime entity classes. Preserve their original behavior.
		if not FogAccess.state_can_see(match_state, team, node) or node.get("is_placement_ghost") == true:
			continue
		# 资源：有 extract() 即 ResourceNode，全局可见供采集分配。
		if node.has_method("extract"):
			if not node is BuildingAgent or node.is_complete: resource_nodes.append(node as Node2D)
			if not node is BuildingAgent: continue
		if node.get("def") is BuildingDef:
			var building := node as Node2D
			var building_def := building.get("def") as BuildingDef
			var building_team: Enums.Team = building.get("team")
			# TC 位置双方都要记（集结点 / 进攻目标 / 防守圆心）。
			if building_def != null and building_def.id == &"town_center":
				if building_team == team:
					own_tc_pos = building.get("sim_pos")
				elif building_team == enemy:
					enemy_tc_pos = building.get("sim_pos")
			if building_team != team:
				continue
			team_buildings.append(building)
			if not bool(building.get("is_complete")):
				incomplete_buildings += 1
			continue
		if node.get("def") is UnitDef:
			# 敌方单位：仅用于威胁检测，不加入 team_units。
			if node.get("team") != team:
				if float(node.get("hp")) > 0.0 and own_tc_pos != Vector2.ZERO:
					var dist: float = own_tc_pos.distance_to(node.get("sim_pos"))
					if dist <= defend_radius:
						threat_near_base = true
				continue
			team_units.append(node as Node2D)
			var unit_def := node.get("def") as UnitDef
			if unit_def.id == &"villager":
				villager_count += 1
				team_villagers.append(node as Node2D)
			else:
				military_count += 1


func _fog_holder(state: MatchState, entity_root: Node2D) -> Node:
	if not state.fog_enabled or state.fog == null:
		return null
	var parent := entity_root.get_parent()
	if parent == null or not parent.has_meta("fog_holder"):
		return null
	var holder: Variant = parent.get_meta("fog_holder")
	if not is_instance_valid(holder) or not holder is Node or not holder.has_method("live_entities") or not holder.has_method("entity_visible_for"):
		return null
	# Other worlds and externally supplied masks must retain the live fallback.
	return holder if holder.get("fog") == state.fog and holder.get("entities") == entity_root else null


func _read_building(building: Node2D, definition: BuildingDef, building_team: int, position: Vector2, complete: bool, team: int, enemy: int) -> void:
	if definition.id == &"town_center":
		if building_team == team:
			own_tc_pos = position
		elif building_team == enemy:
			enemy_tc_pos = position
	if building_team != team:
		return
	team_buildings.append(building)
	if not complete:
		incomplete_buildings += 1


func _read_unit(unit: Node2D, definition: UnitDef, unit_team: int, health: float, position: Vector2, team: int, defend_radius: float) -> void:
	if unit_team != team:
		if health > 0.0 and own_tc_pos != Vector2.ZERO and own_tc_pos.distance_to(position) <= defend_radius:
			threat_near_base = true
		return
	team_units.append(unit)
	if definition.id == &"villager":
		villager_count += 1
		team_villagers.append(unit)
	else:
		military_count += 1
