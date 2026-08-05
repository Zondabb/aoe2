# scripts/input/ground_picker.gd
class_name GroundPicker
extends RefCounted

static func pick_ground(camera: Camera3D, screen_pos: Vector2) -> Variant:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_direction := camera.project_ray_normal(screen_pos)
	return intersect_ground(ray_origin, ray_direction)

static func intersect_ground(ray_origin: Vector3, ray_direction: Vector3) -> Variant:
	if absf(ray_direction.y) < 0.0001:
		return null

	var distance := -ray_origin.y / ray_direction.y
	if distance < 0.0:
		return null
	return ray_origin + ray_direction * distance
