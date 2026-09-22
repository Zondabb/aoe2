extends Node

const FogHolder := preload("res://scripts/systems/fog_of_war_holder.gd")

const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"
const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const NavServiceHolderScript := preload("res://scripts/systems/nav_service_holder.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const GROUND_MIN := -30
const GROUND_MAX := 30
const GROUND_STEP := 8

var match_state := MatchState.new()
var nav_holder: NavServiceHolderScript
var nav: NavGridServiceScript

func _ready() -> void:
	match_state.fog_enabled = true
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	_setup_ground()
	_setup_nav()
	_spawn_test_entities()
	call_deferred("_finish_setup")

func _finish_setup() -> void:
	if nav_holder != null:
		nav_holder.rebuild_from_scene()
	_focus_camera()
	var overlay := get_node_or_null("../PathDebug")
	if overlay != null and overlay.has_method("set_nav"):
		overlay.call("set_nav", nav)
	FogHolder.install(get_parent(), match_state, GROUND_MIN, GROUND_MAX, -1)

func _setup_nav() -> void:
	nav_holder = NavServiceHolderScript.new()
	nav_holder.name = "NavService"
	nav_holder.setup(GROUND_MIN, GROUND_MAX, 1.0)
	nav = nav_holder.nav
	get_parent().call_deferred("add_child", nav_holder)

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
				tile.scale = Vector2(0.35, 0.35)
			else:
				tile.modulate = GROUND_COLOR
			tile.position = IsoMathScript.world_to_screen(Vector2(float(lx), float(lz)))
			ground.add_child(tile)
			lz += GROUND_STEP
		lx += GROUND_STEP

func _spawn_test_entities() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	for child in entities.get_children():
		child.free()

	_spawn_resource(entities, "GoldMine", Enums.ResourceType.GOLD, Vector2.ZERO)
	_spawn_resource(entities, "Tree", Enums.ResourceType.WOOD, Vector2(-7.0, -3.0))
	_spawn_resource(entities, "BerryBush", Enums.ResourceType.FOOD, Vector2(5.0, 4.0))

	var town_center := BUILDING_VIEW.instantiate() as Node2D
	town_center.name = "TownCenter"
	town_center.set("team", Enums.Team.PLAYER)
	town_center.set("def", TOWN_CENTER_DEF)
	town_center.set("civ", CHINESE_CIV)
	town_center.set("match_state", match_state)
	town_center.set("accepts_all_resources", true)
	town_center.set("sim_pos", Vector2(-14.0, 10.0))
	entities.add_child(town_center)

	var spawn_points := [
		Vector2(-12.0, -8.0),
		Vector2(-10.0, -10.0),
		Vector2(-14.0, -6.0),
	]
	for index in spawn_points.size():
		var villager := UNIT_VIEW.instantiate() as Node2D
		villager.name = "Villager%d" % (index + 1)
		villager.set("team", Enums.Team.PLAYER)
		villager.set("def", VILLAGER_DEF)
		villager.set("civ", CHINESE_CIV)
		villager.set("match_state", match_state)
		villager.set("sim_pos", spawn_points[index])
		entities.add_child(villager)

func _spawn_resource(
	parent: Node2D,
	node_name: String,
	resource_type: Enums.ResourceType,
	spawn_position: Vector2
) -> void:
	var resource := ResourceNodeScript.new()
	resource.name = node_name
	resource.resource_type = resource_type
	resource.amount = 200.0
	resource.gather_rate = 4.0
	resource.sim_pos = spawn_position
	parent.add_child(resource)

func _focus_camera() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2(-2.0, -2.0))
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2(-2.0, -2.0))
