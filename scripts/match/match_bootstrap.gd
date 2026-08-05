# scripts/match/match_bootstrap.gd
extends Node

const GROUND_SIZE := Vector2(120.0, 120.0)
const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const TOWN_CENTER_DEF := preload("res://data/buildings/town_center.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")

var match_state := MatchState.new()

func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
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

	var villager := UNIT_VIEW.instantiate()
	villager.name = "PlayerVillager"
	villager.set("team", Enums.Team.PLAYER)
	villager.set("def", VILLAGER_DEF)
	villager.set("match_state", match_state)
	villager.position = Vector3.ZERO
	entities.add_child(villager)

	var town_center := BUILDING_VIEW.instantiate() as Node3D
	town_center.name = "TownCenter"
	town_center.set("team", Enums.Team.PLAYER)
	town_center.set("def", TOWN_CENTER_DEF)
	town_center.set("civ", CHINESE_CIV)
	town_center.set("match_state", match_state)
	town_center.set("accepts_all_resources", true)
	town_center.position = Vector3(-4.0, 0.0, 0.0)
	entities.add_child(town_center)

	_spawn_resource(
		entities, "FoodBush", Enums.ResourceType.FOOD,
		Vector3(4.0, 0.0, 1.0), Color(0.35, 0.75, 0.20)
	)
	_spawn_resource(
		entities, "Tree", Enums.ResourceType.WOOD,
		Vector3(5.0, 0.0, -2.0), Color(0.12, 0.42, 0.12)
	)
	_spawn_resource(
		entities, "GoldMine", Enums.ResourceType.GOLD,
		Vector3(6.0, 0.0, 3.0), Color(0.92, 0.72, 0.12)
	)

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
		"setup", camera, entities, selection, match_state, CHINESE_CIV
	)
	hud.call("setup", match_state, CHINESE_CIV, build_system, selection)
