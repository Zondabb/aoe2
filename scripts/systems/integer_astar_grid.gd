extends AStarGrid2D
## Godot's virtual API returns float, but all costs are exact small integers.
## Cardinal/diagonal weights 10/14 avoid the platform sqrt(2) octile heuristic.
## All cells use the default weight of 1, including when jump pruning is active.
static func cost(from_id: Vector2i, to_id: Vector2i) -> int:
	var dx: int = absi(to_id.x - from_id.x)
	var dy: int = absi(to_id.y - from_id.y)
	return 10 * maxi(dx, dy) + 4 * mini(dx, dy)

func _compute_cost(from_id: Vector2i, to_id: Vector2i) -> float:
	return cost(from_id, to_id)

func _estimate_cost(from_id: Vector2i, end_id: Vector2i) -> float:
	return cost(from_id, end_id)
