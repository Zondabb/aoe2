# scripts/match/match_bootstrap.gd
extends Node

const GROUND_SIZE := Vector2(120.0, 120.0)
const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER_DEF := preload("res://data/units/villager.tres")

func _ready() -> void:
	_setup_ground()
	_spawn_player_villager()

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

func _spawn_player_villager() -> void:
	var entities := get_node_or_null("../Entities") as Node3D
	if entities == null or entities.get_child_count() > 0:
		return

	var villager := UNIT_VIEW.instantiate()
	villager.name = "PlayerVillager"
	villager.set("team", Enums.Team.PLAYER)
	villager.set("def", VILLAGER_DEF)
	villager.position = Vector3.ZERO
	entities.add_child(villager)
