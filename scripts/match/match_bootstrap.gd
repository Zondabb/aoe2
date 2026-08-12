# scripts/match/match_bootstrap.gd
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
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const GROUND_MIN := -60
const GROUND_MAX := 60
const GROUND_STEP := 8

var match_state := MatchState.new()
var player_civ: CivDef
var ai_civ: CivDef

func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	player_civ = _civ_for_id(GameSession.player_civ_id)
	ai_civ = _opposite_civ(player_civ)
	GameSession.ai_civ_id = ai_civ.id
	_setup_ground()
	_setup_nav()
	_spawn_entities()
	call_deferred("_finish_nav_setup")
	_focus_camera_on_player_base()
	_setup_building_controls()
	_setup_ai_controller()

func _setup_nav() -> void:
	var holder := NavServiceHolderScript.new()
	holder.name = "NavService"
	holder.setup(GROUND_MIN, GROUND_MAX, 1.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.add_child(holder)

func _finish_nav_setup() -> void:
	var holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	if holder != null:
		holder.rebuild_from_scene()

func _focus_camera_on_player_base() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2(-40.0, -40.0))
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2(-40.0, -40.0))

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
		entities, Enums.Team.PLAYER, player_civ,
		Vector2(-40.0, -40.0), "Player", 1.0
	)
	_spawn_base(
		entities, Enums.Team.AI, ai_civ,
		Vector2(40.0, 40.0), "Ai", -1.0
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

func _civ_for_id(civ_id: StringName) -> CivDef:
	return TEUTONS_CIV if civ_id == &"teutons" else CHINESE_CIV

func _opposite_civ(civ: CivDef) -> CivDef:
	return CHINESE_CIV if civ.id == &"teutons" else TEUTONS_CIV

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

func _setup_building_controls() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var camera := match_root.get_node_or_null("Camera2D") as Camera2D
	var entities := match_root.get_node_or_null("Entities") as Node2D
	var selection := match_root.get_node_or_null("UILayer/SelectionController") as Control
	var build_system := match_root.get_node_or_null("BuildSystem") as Node
	var hud := match_root.get_node_or_null("UILayer/HUD") as Control
	if (
		camera == null
		or entities == null
		or selection == null
		or build_system == null
		or hud == null
	):
		return
	build_system.call(
		"setup", camera, entities, selection, match_state, player_civ
	)
	hud.call("setup", match_state, player_civ, build_system, selection)

func _setup_ai_controller() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var entities := match_root.get_node_or_null("Entities") as Node2D
	if entities == null:
		return
	var ai := match_root.get_node_or_null("AiController") as Node
	if ai == null:
		ai = Node.new()
		ai.name = "AiController"
		ai.set_script(load("res://scripts/systems/ai_controller.gd"))
		match_root.add_child(ai)
	ai.call("setup", match_state, entities, ai_civ, Enums.Team.AI, Enums.Team.PLAYER)
