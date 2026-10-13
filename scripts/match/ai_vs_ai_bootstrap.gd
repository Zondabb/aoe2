# scripts/match/ai_vs_ai_bootstrap.gd
## AI vs AI 验证场景入口（scenes/ai_vs_ai.tscn）。
##
## 启动流程：
##   _ready → 地面 / Nav / Vision → 双方基地 → 相机 & AiGateway → UI
##   _finish_setup（deferred）→ 障碍网格 & 视野重建 → 寻路调试 overlay
##
## 中国方挂在 Enums.Team.PLAYER，条顿方挂在 Enums.Team.AI；AiGateway 经 HTTP 驱动双方，
## 共用 decision_log，本地 embedded 服务见 scripts/ai_gateway/local_ai_server.gd。
extends Node

const FogHolder := preload("res://scripts/systems/fog_of_war_holder.gd")
const TerrainVisual := preload("res://scripts/presentation/terrain_visual.gd")


const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const NavServiceHolderScript := preload("res://scripts/systems/nav_service_holder.gd")
const VisionServiceHolderScript := preload("res://scripts/systems/vision_service_holder.gd")
const NavDebugOverlayScript := preload("res://scripts/presentation/nav_debug_overlay.gd")
const AiGatewayScript := preload("res://scripts/ai_gateway/ai_gateway.gd")
const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const GameSettingsScript := preload("res://scripts/core/game_settings.gd")
const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")
const UnitDebugFocusScript := preload("res://scripts/debug/unit_debug_focus.gd")

const GROUND_MIN := -60
const GROUND_MAX := 60

var match_state := MatchState.new()
## 双方 AI 共用的决策日志，绑定右侧 AiDebugLog 面板。
var decision_log := AiDecisionLogScript.new()


## 场景启动总入口：先搭世界，再生成实体，最后挂 AI 与 UI。
func _ready() -> void:
	match_state.fog_enabled = true
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	_setup_ground()
	_setup_nav()
	_setup_vision()
	_spawn_entities()
	# 等 Nav/Vision holder 进树后再 rebuild，避免空网格。
	call_deferred("_finish_setup")
	_focus_camera()
	# AiGateway 必须在父节点 _ready 结束后再 add_child，否则会被引擎拒绝入树。
	call_deferred("_setup_ai_gateway")
	_setup_hud()


## 创建 NavGridService（A* 寻路），地图范围与 GROUND_* 一致。
func _setup_nav() -> void:
	var holder := NavServiceHolderScript.new()
	holder.name = "NavService"
	holder.setup(GROUND_MIN, GROUND_MAX, 1.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.call_deferred("add_child", holder)


## 创建视野服务（Fog / 空间查询），供调试 overlay 与 AI 探敌。
func _setup_vision() -> void:
	var holder := VisionServiceHolderScript.new()
	holder.name = "VisionService"
	holder.setup(2.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.call_deferred("add_child", holder)


## 实体生成后的收尾：烘焙障碍、挂 G 键调试层。
func _finish_setup() -> void:
	var nav_holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	if nav_holder != null:
		nav_holder.rebuild_from_scene()
	var vision_holder := get_tree().get_first_node_in_group("vision_service") as VisionServiceHolderScript
	if vision_holder != null:
		vision_holder.rebuild_from_scene()
	_setup_debug_overlay()
	FogHolder.install(get_parent(), match_state, GROUND_MIN, GROUND_MAX, -1)


## 按 G/N/B/P… 切换的 NavDebugOverlay；与 PathfindingDebugPanel 绑定。

func _setup_debug_overlay() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	if get_tree().get_first_node_in_group("nav_debug_overlay") != null:
		return
	var nav_holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	var vision_holder := get_tree().get_first_node_in_group("vision_service") as VisionServiceHolderScript
	var overlay := NavDebugOverlayScript.new()
	overlay.name = "NavDebugOverlay"
	if nav_holder != null:
		overlay.nav = nav_holder.nav
	if vision_holder != null:
		overlay.vision = vision_holder.vision
	match_root.add_child(overlay)
	var panel := match_root.get_node_or_null("UILayer/PathfindingDebugPanel")
	if panel != null:
		panel.call_deferred("_bind_overlay")


func _focus_camera() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2.ZERO)
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2.ZERO)


## 与正常对局共用连续草地及原版贴图密度。
func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as Node2D
	if ground == null:
		return
	TerrainVisual.setup_grass(
		ground,
		Rect2(Vector2(GROUND_MIN, GROUND_MIN), Vector2.ONE * (GROUND_MAX - GROUND_MIN))
	)

## 对称生成双方开局：中国 (-40,-40) vs 条顿 (40,40)。
func _spawn_entities() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null or entities.get_child_count() > 0:
		return
	_spawn_base(
		entities, Enums.Team.PLAYER, CHINESE_CIV,
		Vector2(-40.0, -40.0), "Chinese", 1.0
	)
	_spawn_base(
		entities, Enums.Team.AI, TEUTONS_CIV,
		Vector2(40.0, 40.0), "Teutons", -1.0
	)


## 单方基地包：城镇中心 + 起始村民 + 附近三资源。
## direction：资源/村民相对 TC 的摆放方向（中国 +1，条顿 -1 镜像）。
func _spawn_base(
	entities: Node2D,
	team: Enums.Team,
	civ: CivDef,
	origin: Vector2,
	prefix: String,
	direction: float
) -> void:
	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.name = "%sTownCenter" % prefix
	town_center.set("team", team)
	town_center.set("def", TOWN_CENTER_DEF)
	town_center.set("civ", civ)
	town_center.set("match_state", match_state)
	town_center.set("accepts_all_resources", true)
	town_center.set("sim_pos", origin)
	entities.add_child(town_center)

	var villager_count := 3 + civ.extra_starting_villagers
	var villager_offsets := [
		Vector2(5.0, 0.0),
		Vector2(3.5, 3.5),
		Vector2(0.0, 5.0),
		Vector2(5.0, 5.0),
	]
	for index in villager_count:
		var villager := UNIT_VIEW.instantiate() as Node2D
		villager.name = "%sVillager%d" % [prefix, index + 1]
		villager.set("team", team)
		villager.set("def", VILLAGER_DEF)
		villager.set("civ", civ)
		villager.set("match_state", match_state)
		villager.set("sim_pos", origin + villager_offsets[index] * direction)
		entities.add_child(villager)

	_spawn_resource(
		entities, "%sFoodBush" % prefix, Enums.ResourceType.FOOD,
		origin + Vector2(16.0, 6.0) * direction,
		Color(0.35, 0.75, 0.20)
	)
	_spawn_resource(
		entities, "%sTree" % prefix, Enums.ResourceType.WOOD,
		origin + Vector2(10.0, -6.0) * direction,
		Color(0.12, 0.42, 0.12)
	)
	_spawn_resource(
		entities, "%sGoldMine" % prefix, Enums.ResourceType.GOLD,
		origin + Vector2(0.0, 16.0) * direction,
		Color(0.92, 0.72, 0.12)
	)


func _spawn_resource(
	parent: Node2D,
	node_name: String,
	resource_type: Enums.ResourceType,
	spawn_position: Vector2,
	color: Color
) -> void:
	var resource := ResourceNodeScript.new()
	resource.name = node_name
	resource.resource_type = resource_type
	resource.amount = 200.0
	resource.gather_rate = 4.0
	resource.sim_pos = spawn_position
	resource.add_child(_make_marker(color))
	parent.add_child(resource)


func _make_marker(color: Color) -> Polygon2D:
	var marker := Polygon2D.new()
	marker.name = "Marker"
	marker.color = color
	marker.polygon = PackedVector2Array([
		Vector2(-10, -10),
		Vector2(10, -10),
		Vector2(10, 10),
		Vector2(-10, 10),
	])
	return marker


## 创建 AiGateway：双方 team 各 tick，debug 来自 HTTP response。
func _setup_ai_gateway() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var entities := match_root.get_node_or_null("Entities") as Node2D
	if entities == null:
		return
	if match_root.get_node_or_null("AiGateway") != null:
		return
	# Autoload GameSession only loads cfg once; re-read so F6 / 重进场景能吃到改动。
	GameSettingsScript.apply_from_config()
	var gateway := AiGatewayScript.new()
	gateway.name = "AiGateway"
	match_root.add_child(gateway)
	var teams: Array = [
		{
			"team": Enums.Team.PLAYER,
			"enemy_team": Enums.Team.AI,
			"civ": CHINESE_CIV,
			"label": "Chinese",
		},
		{
			"team": Enums.Team.AI,
			"enemy_team": Enums.Team.PLAYER,
			"civ": TEUTONS_CIV,
			"label": "Teutons",
		},
	]
	var ai_config := AiConfigScript.from_game_session()
	print(
		"AiVsAi: protocol=%s backend=%s url=%s model=%s"
		% [ai_config.protocol, ai_config.backend, ai_config.display_url(), ai_config.model]
	)
	gateway.setup(match_state, entities, teams, ai_config, decision_log)
	_setup_debug_panel(gateway)


## 右侧 RichTextLabel 订阅 decision_log；顶部显示 Gateway 状态。
func _setup_debug_panel(gateway: Node = null) -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var panel := match_root.get_node_or_null("UILayer/AiDebugLog") as RichTextLabel
	if panel != null and panel.has_method("setup"):
		panel.call("setup", decision_log)
	var status := match_root.get_node_or_null("UILayer/AiGatewayStatus") as Label
	if gateway == null:
		gateway = match_root.get_node_or_null("AiGateway")
	if status != null and status.has_method("bind_gateway") and gateway != null:
		status.call("bind_gateway", gateway)


## 顶部资源条等 HUD；隐藏胜负面板（本场景无玩家操作）。
func _setup_hud() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	UnitDebugFocusScript.set_spectator_mode(true)
	var selection := match_root.get_node_or_null("UILayer/SelectionController") as Control
	var hud := match_root.get_node_or_null("UILayer/HUD") as Control
	if hud == null:
		return
	if hud.has_method("setup"):
		hud.call("setup", match_state, CHINESE_CIV, null, selection, true)
	var result_panel := hud.get_node_or_null("ResultPanel") as Control
	if result_panel != null:
		result_panel.visible = false
	var unit_log := match_root.get_node_or_null("UILayer/UnitDebugLog") as RichTextLabel
	if unit_log != null and unit_log.has_method("bind_selection") and selection != null:
		unit_log.call("bind_selection", selection)
