extends RefCounted
## Tree art is derived from synchronized coordinates, never process-local IDs,
## global RNG, load order, or the number of locally installed textures.
## Keep these tables stable: saves and late viewers reconstruct the same shape.
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const BASES := ["tree_deciduous", "tree_pine", "tree_palm", "tree_bamboo"]
# Omit bare/dead trees from growing forests. Each entry is an original SLP frame.
const FRAMES := [
	[0, 1, 2, 4, 6, 7, 9, 10, 11, 12, 13],
	[1, 2, 3, 4, 5, 7, 8],
	[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
	[0, 1, 2, 3],
]
const GROVE_SIZE_Q := 32 * Fixed.SCALE

static func at_position(pos: Vector2) -> Dictionary:
	# Symmetric starting forests also have symmetric art. Conversion happens
	# once at the presentation boundary; all selection arithmetic is integer.
	var x := absi(Fixed.coord(pos.x))
	var y := absi(Fixed.coord(pos.y))
	var grove := _mix(Fixed.floor_div(x, GROVE_SIZE_Q), Fixed.floor_div(y, GROVE_SIZE_Q)) % 10
	var family := 0 if grove < 5 else (1 if grove < 8 else (2 if grove == 8 else 3))
	var frame: int = FRAMES[family][_mix(x, y) % FRAMES[family].size()]
	return {"base": "res://assets/sprites/resources/" + BASES[family], "frame": frame}

static func _mix(x: int, y: int) -> int:
	var value := ((x * 73856093) ^ (y * 19349663) ^ 83492791) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 1274126177) & 0x7fffffff
	return value ^ (value >> 16)
