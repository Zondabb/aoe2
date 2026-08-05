# scripts/match/match_bootstrap.gd
extends Node

const GROUND_SIZE := Vector2(120.0, 120.0)
const GROUND_COLOR := Color(0.20, 0.48, 0.16)

func _ready() -> void:
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
