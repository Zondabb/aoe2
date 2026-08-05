# scripts/match/match_bootstrap.gd
extends Node

const GROUND_SIZE := Vector2(120.0, 120.0)
const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

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
	_spawn_entities()
	_setup_building_controls()

func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as MeshInstance3D
	if ground == null or ground.mesh != null:
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = GROUND_COLOR
	material.roughness = 1.0
	var plane := PlaneMesh.new()
	plane.size = GROUND_SIZE
	plane.material = material
	ground.mesh = plane

func _spawn_entities() -> void:
	var entities := get_node_or_null("../Entities") as Node3D
	if entities == null or entities.get_child_count() > 0:
		return

	_spawn_base(
		entities, Enums.Team.PLAYER, player_civ,
		Vector3(-40.0, 0.0, -40.0), "Player", 1.0
	)
	_spawn_base(
		entities, Enums.Team.AI, ai_civ,
		Vector3(40.0, 0.0, 40.0), "Ai", -1.0
	)

func _spawn_base(
	entities: Node3D,
	team: Enums.Team,
	civ: CivDef,
	origin: Vector3,
	prefix: String,
	direction: float
) -> void:
	var town_center := BUILDING_VIEW.instantiate() as Node3D
	town_center.name = "%sTownCenter" % prefix
	town_center.set("team", team)
	town_center.set("def", TOWN_CENTER_DEF)
	town_center.set("civ", civ)
	town_center.set("match_state", match_state)
	town_center.set("accepts_all_resources", true)
	town_center.position = origin
	entities.add_child(town_center)

	var villager_count := 3 + civ.extra_starting_villagers
	var villager_offsets := [
		Vector3(5.0, 0.0, 0.0),
		Vector3(3.5, 0.0, 3.5),
		Vector3(0.0, 0.0, 5.0),
		Vector3(5.0, 0.0, 5.0),
	]
	for index in villager_count:
		var villager := UNIT_VIEW.instantiate() as Node3D
		villager.name = "%sVillager%d" % [prefix, index + 1]
		villager.set("team", team)
		villager.set("def", VILLAGER_DEF)
		villager.set("civ", civ)
		villager.set("match_state", match_state)
		villager.position = origin + villager_offsets[index] * direction
		entities.add_child(villager)

	_spawn_resource(
		entities, "%sFoodBush" % prefix, Enums.ResourceType.FOOD,
		origin + Vector3(9.0, 0.0, 2.0) * direction,
		Color(0.35, 0.75, 0.20)
	)
	_spawn_resource(
		entities, "%sTree" % prefix, Enums.ResourceType.WOOD,
		origin + Vector3(7.0, 0.0, -6.0) * direction,
		Color(0.12, 0.42, 0.12)
	)
	_spawn_resource(
		entities, "%sGoldMine" % prefix, Enums.ResourceType.GOLD,
		origin + Vector3(5.0, 0.0, 9.0) * direction,
		Color(0.92, 0.72, 0.12)
	)

func _civ_for_id(civ_id: StringName) -> CivDef:
	return TEUTONS_CIV if civ_id == &"teutons" else CHINESE_CIV

func _opposite_civ(civ: CivDef) -> CivDef:
	return CHINESE_CIV if civ.id == &"teutons" else TEUTONS_CIV

func _spawn_resource(
	parent: Node3D,
	node_name: String,
	resource_type: Enums.ResourceType,
	spawn_position: Vector3,
	color: Color
) -> void:
	var resource := ResourceNodeScript.new()
	resource.name = node_name
	resource.resource_type = resource_type
	resource.amount = 200.0
	resource.gather_rate = 4.0
	resource.position = spawn_position
	resource.add_child(_make_marker(Vector3(1.2, 1.2, 1.2), color))
	parent.add_child(resource)

func _make_marker(size: Vector3, color: Color) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var marker := MeshInstance3D.new()
	marker.position.y = size.y * 0.5
	marker.mesh = mesh
	return marker

func _setup_building_controls() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var camera := match_root.get_node_or_null("CameraRig/Camera3D") as Camera3D
	var entities := match_root.get_node_or_null("Entities") as Node3D
	var selection := match_root.get_node_or_null("SelectionController") as Control
	var build_system := match_root.get_node_or_null("BuildSystem") as Node
	var hud := match_root.get_node_or_null("HUD") as Control
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
