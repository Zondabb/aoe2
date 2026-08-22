# scripts/match/ai_vs_ai_bootstrap.gd
extends Node

const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const NavServiceHolderScript := preload("res://scripts/systems/nav_service_holder.gd")
const VisionServiceHolderScript := preload("res://scripts/systems/vision_service_holder.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const AiDirectorScript := preload("res://scripts/systems/ai/ai_director.gd")
const AiDecisionLogScript := preload("res://scripts/systems/ai/ai_decision_log.gd")

const GROUND_MIN := -60
const GROUND_MAX := 60
const GROUND_STEP := 8

var match_state := MatchState.new()
var decision_log := AiDecisionLogScript.new()


func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	_setup_ground()
	_setup_nav()
	_setup_vision()
	_spawn_entities()
	call_deferred("_finish_nav_setup")
	call_deferred("_finish_vision_setup")
	_focus_camera()
	_setup_ais()
	_setup_debug_panel()
	_setup_hud()


func _setup_nav() -> void:
	var holder := NavServiceHolderScript.new()
	holder.name = "NavService"
	holder.setup(GROUND_MIN, GROUND_MAX, 1.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.add_child(holder)


func _setup_vision() -> void:
	var holder := VisionServiceHolderScript.new()
	holder.name = "VisionService"
	holder.setup(2.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.add_child(holder)


func _finish_nav_setup() -> void:
	var holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	if holder != null:
		holder.rebuild_from_scene()
	_kick_ais()


func _finish_vision_setup() -> void:
	var holder := get_tree().get_first_node_in_group("vision_service") as VisionServiceHolderScript
	if holder != null:
		holder.rebuild_from_scene()


func _kick_ais() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	for ai_name in ["ChineseAi", "TeutonsAi"]:
		var ai := match_root.get_node_or_null(ai_name)
		if ai != null and ai.has_method("evaluate"):
			ai.call("evaluate")


func _focus_camera() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2.ZERO)
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2.ZERO)


func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as Node2D
	if ground == null:
		return
	for child in ground.get_children():
		child.free()
	var texture: Texture2D = null
	if ResourceLoader.exists(TERRAIN_TEXTURE):
		texture = load(TERRAIN_TEXTURE) as Texture2D
	var lx := GROUND_MIN
	while lx <= GROUND_MAX:
		var lz := GROUND_MIN
		while lz <= GROUND_MAX:
			var tile := Sprite2D.new()
			tile.centered = true
			tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			tile.z_index = -100
			if texture != null:
				tile.texture = texture
				tile.modulate = Color(1.0, 1.0, 1.0, 1.0)
				tile.scale = Vector2(0.35, 0.35)
			else:
				tile.modulate = GROUND_COLOR
			tile.position = IsoMathScript.world_to_screen(Vector2(float(lx), float(lz)))
			ground.add_child(tile)
			lz += GROUND_STEP
		lx += GROUND_STEP


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
		origin + Vector2(9.0, 2.0) * direction,
		Color(0.35, 0.75, 0.20)
	)
	_spawn_resource(
		entities, "%sTree" % prefix, Enums.ResourceType.WOOD,
		origin + Vector2(7.0, -6.0) * direction,
		Color(0.12, 0.42, 0.12)
	)
	_spawn_resource(
		entities, "%sGoldMine" % prefix, Enums.ResourceType.GOLD,
		origin + Vector2(5.0, 9.0) * direction,
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


func _setup_ais() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var entities := match_root.get_node_or_null("Entities") as Node2D
	if entities == null:
		return

	var chinese_ai := AiDirectorScript.new()
	chinese_ai.name = "ChineseAi"
	match_root.add_child(chinese_ai)
	chinese_ai.setup(
		match_state,
		entities,
		CHINESE_CIV,
		Enums.Team.PLAYER,
		Enums.Team.AI,
		"Chinese",
		decision_log,
	)

	var teutons_ai := AiDirectorScript.new()
	teutons_ai.name = "TeutonsAi"
	match_root.add_child(teutons_ai)
	teutons_ai.setup(
		match_state,
		entities,
		TEUTONS_CIV,
		Enums.Team.AI,
		Enums.Team.PLAYER,
		"Teutons",
		decision_log,
	)


func _setup_debug_panel() -> void:
	var panel := get_node_or_null("../UILayer/AiDebugLog") as RichTextLabel
	if panel != null and panel.has_method("setup"):
		panel.call("setup", decision_log)


func _setup_hud() -> void:
	var hud := get_node_or_null("../UILayer/HUD") as Control
	if hud == null:
		return
	if hud.has_method("setup"):
		hud.call("setup", match_state, CHINESE_CIV, null, null)
	var result_panel := hud.get_node_or_null("ResultPanel") as Control
	if result_panel != null:
		result_panel.visible = false
