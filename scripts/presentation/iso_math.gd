class_name IsoMath
extends RefCounted

## Logical world (x, z) → screen (x, y) for classic 2:1 isometric diamonds.
const SCALE_X := 22.0
const SCALE_Y := 11.0


static func world_to_screen(world: Vector2) -> Vector2:
	return Vector2(
		(world.x - world.y) * SCALE_X,
		(world.x + world.y) * SCALE_Y
	)


static func screen_to_world(screen: Vector2) -> Vector2:
	var x := (screen.x / SCALE_X + screen.y / SCALE_Y) * 0.5
	var z := (screen.y / SCALE_Y - screen.x / SCALE_X) * 0.5
	return Vector2(x, z)


static func sync_node(node: Node2D, world: Vector2) -> void:
	if node == null:
		return
	node.position = world_to_screen(world)


## Sim-space offset from footprint center → local screen offset (node at footprint center).
static func footprint_offset_screen(delta_sim: Vector2) -> Vector2:
	return Vector2(
		(delta_sim.x - delta_sim.y) * SCALE_X,
		(delta_sim.x + delta_sim.y) * SCALE_Y
	)


## Closed diamond matching a logical axis-aligned footprint (half extents in sim tiles).
static func footprint_polygon_screen(half: Vector2) -> PackedVector2Array:
	if half.x <= 0.0 or half.y <= 0.0:
		return PackedVector2Array()
	return PackedVector2Array([
		footprint_offset_screen(Vector2(-half.x, -half.y)),
		footprint_offset_screen(Vector2(half.x, -half.y)),
		footprint_offset_screen(Vector2(half.x, half.y)),
		footprint_offset_screen(Vector2(-half.x, half.y)),
	])
