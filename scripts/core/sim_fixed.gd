extends RefCounted
## Authoritative scalar/time arithmetic. Float conversion is restricted to data,
## input and presentation boundaries. Coordinates use 1/1024 of a map tile.
const SCALE: int = 1024
const TIME_SCALE: int = 30720
const TICKS_PER_SECOND: int = 30
const STEP_TIME: int = 1024

static func from_float(value: float) -> int:
	return roundi(value * SCALE)

static func to_float(value: int) -> float:
	return float(value) / SCALE

static func time_from_seconds(value: float) -> int:
	return roundi(value * TIME_SCALE)

static func time_to_seconds(value: int) -> float:
	return float(value) / TIME_SCALE

static func delta_time(delta: float, lockstep: bool = false) -> int:
	return STEP_TIME if lockstep else maxi(0, time_from_seconds(delta))

## Round to nearest; exact halves are rounded away from zero on every platform.
## Callers keep products within signed 64-bit range (game/map limits).
@warning_ignore("integer_division")
static func mul_div(a: int, b: int, denominator: int) -> int:
	assert(denominator != 0)
	var product: int = a * b
	var negative: bool = (product < 0) != (denominator < 0)
	var result: int = (absi(product) + absi(denominator) / 2) / absi(denominator)
	return -result if negative else result

static func mul(a: int, b: int) -> int:
	return mul_div(a, b, SCALE)

static func div(a: int, b: int) -> int:
	return mul_div(a, SCALE, b)

## Cell indexing must floor negative coordinates, rather than truncate to zero.
@warning_ignore("integer_division")
static func floor_div(value: int, denominator: int) -> int:
	assert(denominator > 0)
	var quotient: int = value / denominator
	return quotient - 1 if value < 0 and value % denominator != 0 else quotient

static func ceil_div(value: int, denominator: int) -> int:
	return -floor_div(-value, denominator)

static func coord(value: float) -> int:
	return from_float(value)

static func vector(value: Vector2) -> Vector2i:
	return Vector2i(coord(value.x), coord(value.y))

static func to_vector(value: Vector2i) -> Vector2:
	return Vector2(to_float(value.x), to_float(value.y))

static func quantize_vector(value: Vector2) -> Vector2:
	return to_vector(vector(value))

static func length_sq(value: Vector2i) -> int:
	# Vector2i's dot/length_squared use 32-bit components in the engine; promote
	# before multiplication to avoid overflowing for ordinary map coordinates.
	return int(value.x) * int(value.x) + int(value.y) * int(value.y)

static func distance_squared(a: Vector2, b: Vector2) -> int:
	return length_sq(vector(a) - vector(b))

## Floor square root, without libm or floating point conversion.
@warning_ignore("integer_division")
static func isqrt(value: int) -> int:
	assert(value >= 0)
	var remainder: int = value
	var result: int = 0
	var bit: int = 1 << 62
	while bit > remainder: bit >>= 2
	while bit != 0:
		if remainder >= result + bit:
			remainder -= result + bit
			result = (result >> 1) + bit
		else:
			result >>= 1
		bit >>= 2
	return result

static func normalize_step(from: Vector2, to: Vector2, distance_fixed: int) -> Vector2:
	var origin := vector(from)
	var target := vector(to)
	var offset := target - origin
	var length: int = isqrt(length_sq(offset))
	if length <= distance_fixed: return to_vector(target)
	if length == 0 or distance_fixed <= 0: return to_vector(origin)
	return to_vector(origin + Vector2i(mul_div(offset.x, distance_fixed, length), mul_div(offset.y, distance_fixed, length)))

static func interpolate(origin: Vector2, target: Vector2, numerator: int, denominator: int) -> Vector2:
	if denominator <= 0: return quantize_vector(target)
	var start := vector(origin)
	var offset := vector(target) - start
	return to_vector(start + Vector2i(mul_div(offset.x, numerator, denominator), mul_div(offset.y, numerator, denominator)))
