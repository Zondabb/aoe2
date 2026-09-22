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
var pop_used := 0
var pop_cap := 0

## 单位统计；incomplete_buildings 用于建造/派工优先级。
var villager_count := 0
var military_count := 0
var incomplete_buildings := 0

## 双方城镇中心位置；threat_near_base 驱动 DEFEND 阶段。
var own_tc_pos := Vector2.ZERO
var enemy_tc_pos := Vector2.ZERO
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

	food = match_state.get_resource(team, Enums.ResourceType.FOOD)
	wood = match_state.get_resource(team, Enums.ResourceType.WOOD)
	gold = match_state.get_resource(team, Enums.ResourceType.GOLD)
	pop_used = int(match_state.population.get(team, 0))
	pop_cap = int(match_state.population_cap.get(team, 0))

	for node in entities.get_children():
		if not FogAccess.state_can_see(match_state, team, node) or node.get("is_placement_ghost") == true:
			continue
		# 资源：有 extract() 即 ResourceNode，全局可见供采集分配。
		if node.has_method("extract"):
			resource_nodes.append(node as Node2D)
			continue
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
