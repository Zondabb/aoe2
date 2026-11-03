extends RefCounted

## Authored rectangles remain map handles. The host creates the inset coast once
## and shares its quantized vertices; peers do not repeat Geometry2D/libm work.
const MAX_VERTICES := 192
const COAST_STEP := 3.0
const Fixed := preload("res://scripts/core/sim_fixed.gd")

static func rectangle(rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])

static func build_contours(rects: Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var remaining := rects.duplicate()
	while not remaining.is_empty():
		var component: Array[Rect2] = [remaining.pop_back()]
		var index := 0
		while index < component.size():
			for rect: Rect2 in remaining.duplicate():
				if component[index].grow(0.0001).intersects(rect):
					component.append(rect)
					remaining.erase(rect)
			index += 1
		result.append_array(_build_component(component))
	return quantize_contours(result)

static func quantize_contours(contours: Array) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	for source: PackedVector2Array in contours:
		var loop := PackedVector2Array()
		for point in source:
			var quantized := Fixed.quantize_vector(point)
			if loop.is_empty() or loop[-1] != quantized: loop.append(quantized)
		if loop.size() > 1 and loop[0] == loop[-1]: loop.resize(loop.size() - 1)
		if loop.size() >= 3: result.append(loop)
	return result

static func _build_component(rects: Array) -> Array[PackedVector2Array]:
	var unions: Array[PackedVector2Array] = []
	var holes: Array[PackedVector2Array] = []
	for rect: Rect2 in rects:
		var pending := rectangle(rect)
		var index := 0
		while index < unions.size():
			var merged := Geometry2D.merge_polygons(unions[index], pending)
			var outer := -1
			var area := 0.0
			for candidate in merged.size():
				if absf(_area(merged[candidate])) > area:
					area = absf(_area(merged[candidate]))
					outer = candidate
			var outer_count := 0
			for candidate in merged.size():
				if signf(_area(merged[candidate])) == signf(_area(merged[outer])): outer_count += 1
			if outer_count == 1:
				pending = merged[outer]
				for candidate in merged.size():
					if candidate != outer: holes.append(merged[candidate])
				unions.remove_at(index)
				index = 0
			else:
				index += 1
		unions.append(pending)
	# Later brush strokes may partially or fully fill a dry island.
	for rect: Rect2 in rects:
		var remaining: Array[PackedVector2Array] = []
		for hole in holes:
			for part in Geometry2D.clip_polygons(hole, rectangle(rect)): remaining.append(part)
		holes = remaining
	var source_width := _minimum_feature_width(unions, holes)
	var result: Array[PackedVector2Array] = []
	for polygon in unions:
		polygon = _simplify(polygon)
		var bounds := _bounds(polygon)
		var amplitude := minf(4.5, minf(minf(bounds.size.x, bounds.size.y) * 0.10, source_width * 0.20))
		var inset := minf(3.4, minf(minf(bounds.size.x, bounds.size.y), source_width) * 0.24)
		var offset := Geometry2D.offset_polygon(polygon, -inset, Geometry2D.JOIN_ROUND)
		for loop: PackedVector2Array in offset:
			var radius := minf(7.0, minf(minf(bounds.size.x, bounds.size.y), source_width) * 0.14)
			var inner := Geometry2D.offset_polygon(loop, -radius, Geometry2D.JOIN_ROUND)
			var rounded: Array[PackedVector2Array] = []
			for core in inner: rounded.append_array(Geometry2D.offset_polygon(core, radius, Geometry2D.JOIN_ROUND))
			if rounded.is_empty(): rounded.append(loop)
			for boundary in rounded:
				var coast := _irregular_loop(_canonical(_simplify(boundary)), amplitude)
				if coast.size() >= 3: result.append(_canonical(coast))
	for hole in holes:
		var bounds := _bounds(hole)
		var amplitude := minf(4.5, minf(minf(bounds.size.x, bounds.size.y) * 0.10, source_width * 0.20))
		var inset := minf(3.4, minf(minf(bounds.size.x, bounds.size.y), source_width) * 0.24)
		for loop in Geometry2D.offset_polygon(_simplify(hole), inset, Geometry2D.JOIN_ROUND):
			var coast := _irregular_loop(_canonical(_simplify(loop)), amplitude, true)
			if coast.size() >= 3: result.append(_canonical(coast))
	return _limit_budget(result)

static func _minimum_feature_width(outer: Array, holes: Array) -> float:
	# Cast through the water from exposed union edges. Internal brush seams
	# disappear before this measurement; thin arms and dry islands remain.
	var boundaries: Array[PackedVector2Array] = []
	var span := 1.0
	for raw in outer + holes:
		boundaries.append(_simplify(raw))
		span = maxf(span, _bounds(raw).size.length() * 2.0)
	var width := span
	for loop_index in boundaries.size():
		var loop := boundaries[loop_index]
		var orientation := signf(_area(loop)) * (1.0 if loop_index < outer.size() else -1.0)
		for edge in loop.size():
			var a := loop[edge]
			var b := loop[(edge + 1) % loop.size()]
			var tangent := (b - a).normalized()
			var inward := Vector2(-tangent.y, tangent.x) * orientation
			for fraction in [0.25, 0.5, 0.75]:
				var origin := a.lerp(b, fraction)
				for boundary in boundaries:
					for index in boundary.size():
						var hit: Variant = Geometry2D.segment_intersects_segment(origin, origin + inward * span, boundary[index], boundary[(index + 1) % boundary.size()])
						if hit == null: continue
						var distance: float = (hit - origin).dot(inward)
						if distance > 0.00001: width = minf(width, distance)
	return width

static func _limit_budget(contours: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var total := 0
	for loop in contours: total += loop.size()
	if total <= MAX_VERTICES: return contours
	var result: Array[PackedVector2Array] = []
	var remaining := MAX_VERTICES
	for index in contours.size():
		var loop := contours[index]
		var allowance := maxi(3, floori(float(loop.size()) / total * MAX_VERTICES))
		allowance = mini(allowance, remaining - (contours.size() - index - 1) * 3)
		if allowance < 3: break
		var reduced := PackedVector2Array()
		for vertex in allowance: reduced.append(loop[floori(float(vertex) / allowance * loop.size())])
		result.append(reduced)
		remaining -= allowance
	return result

static func _irregular_loop(polygon: PackedVector2Array, amplitude: float, hole := false) -> PackedVector2Array:
	var samples := PackedVector2Array()
	var perimeter := 0.0
	for index in polygon.size(): perimeter += polygon[index].distance_to(polygon[(index + 1) % polygon.size()])
	# Round offsets have very short arc edges next to long straight edges.
	# Uniform arc-length sampling prevents their noisy normals folding back.
	var count := clampi(ceili(perimeter / minf(COAST_STEP, maxf(0.4, amplitude * 0.7))), 8, MAX_VERTICES)
	var edge := 0
	var distance := 0.0
	for index in count:
		var target := float(index) * perimeter / count
		while edge < polygon.size() - 1 and target > distance + polygon[edge].distance_to(polygon[(edge + 1) % polygon.size()]):
			distance += polygon[edge].distance_to(polygon[(edge + 1) % polygon.size()])
			edge += 1
		var length := polygon[edge].distance_to(polygon[(edge + 1) % polygon.size()])
		samples.append(polygon[edge].lerp(polygon[(edge + 1) % polygon.size()], (target - distance) / maxf(length, 0.000001)))
	for attempt in 7:
		var result := _noise_samples(samples, amplitude * pow(0.5, attempt), hole)
		if _simple_loop(result): return result
	return polygon

static func _simple_loop(polygon: PackedVector2Array) -> bool:
	if Geometry2D.triangulate_polygon(polygon).is_empty(): return false
	for index in polygon.size():
		for other in range(index + 2, polygon.size()):
			if index == 0 and other == polygon.size() - 1: continue
			if Geometry2D.segment_intersects_segment(polygon[index], polygon[(index + 1) % polygon.size()], polygon[other], polygon[(other + 1) % polygon.size()]) != null: return false
	return true

static func _noise_samples(samples: PackedVector2Array, amplitude: float, hole: bool) -> PackedVector2Array:
	var result := PackedVector2Array()
	var orientation := 1.0 if _area(samples) > 0.0 else -1.0
	for index in samples.size():
		var point := samples[index]
		var incoming := (point - samples[(index - 1 + samples.size()) % samples.size()]).normalized()
		var outgoing := (samples[(index + 1) % samples.size()] - point).normalized()
		var tangent := (incoming + outgoing).normalized()
		var inward := Vector2(-tangent.y, tangent.x) * orientation
		# Even world coordinates give mirrored default lakes the same coast.
		var anchor := point.abs()
		var noise := (sin(anchor.x * 0.37 + anchor.y * 0.19) + sin(anchor.x * 0.13 - anchor.y * 0.41 + 1.7)) * 0.5
		result.append(point + inward * (noise * 0.5 + 0.5) * amplitude * (-1.0 if hole else 1.0))
	return result

static func _simplify(polygon: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for index in polygon.size():
		var previous := polygon[(index - 1 + polygon.size()) % polygon.size()]
		var point := polygon[index]
		var following := polygon[(index + 1) % polygon.size()]
		if point.distance_squared_to(previous) < 0.000001: continue
		if absf((point - previous).cross(following - point)) < 0.00001 and (point - previous).dot(following - point) >= 0.0: continue
		result.append(point)
	return result

static func _canonical(polygon: PackedVector2Array) -> PackedVector2Array:
	var first := 0
	for index in range(1, polygon.size()):
		if polygon[index].x < polygon[first].x - 0.0001 or is_equal_approx(polygon[index].x, polygon[first].x) and polygon[index].y < polygon[first].y:
			first = index
	var result := PackedVector2Array()
	for index in polygon.size(): result.append(polygon[(first + index) % polygon.size()])
	return result

static func _area(polygon: PackedVector2Array) -> float:
	var value := 0.0
	for index in polygon.size(): value += polygon[index].cross(polygon[(index + 1) % polygon.size()])
	return value * 0.5

static func _bounds(polygon: PackedVector2Array) -> Rect2:
	var result := Rect2(polygon[0], Vector2.ZERO)
	for point in polygon: result = result.expand(point)
	return result

static func contains(point: Vector2, contours: Array) -> bool:
	var inside := false
	var p := Fixed.vector(point)
	for polygon: PackedVector2Array in contours:
		if _contains_q(p, polygon): inside = not inside
	return inside

static func _cross(a: Vector2i, b: Vector2i) -> int:
	return int(a.x) * int(b.y) - int(a.y) * int(b.x)

static func _dot(a: Vector2i, b: Vector2i) -> int:
	return int(a.x) * int(b.x) + int(a.y) * int(b.y)

static func _on_segment(point: Vector2i, a: Vector2i, b: Vector2i) -> bool:
	return _cross(point - a, b - a) == 0 and point.x >= mini(a.x, b.x) and point.x <= maxi(a.x, b.x) and point.y >= mini(a.y, b.y) and point.y <= maxi(a.y, b.y)

static func _contains_q(point: Vector2i, polygon: PackedVector2Array) -> bool:
	var inside := false
	for index in polygon.size():
		var a := Fixed.vector(polygon[index])
		var b := Fixed.vector(polygon[(index + 1) % polygon.size()])
		if _on_segment(point, a, b): return true
		if (a.y > point.y) == (b.y > point.y): continue
		var left: int = int(point.x - a.x) * int(b.y - a.y)
		var right: int = int(b.x - a.x) * int(point.y - a.y)
		var crosses_right := left < right if b.y > a.y else left > right
		if crosses_right: inside = not inside
	return inside

## Map dimensions are limited to 1024 tiles. Promoted products are therefore
## at most ~2.4e18, below int64; Vector2i arithmetic alone would overflow.
static func _closest_q(point: Vector2i, a: Vector2i, b: Vector2i) -> Vector2i:
	var edge := b - a
	var length_squared := Fixed.length_sq(edge)
	if length_squared == 0: return a
	var numerator := clampi(_dot(point - a, edge), 0, length_squared)
	return a + Vector2i(Fixed.mul_div(edge.x, numerator, length_squared), Fixed.mul_div(edge.y, numerator, length_squared))

static func _segments_intersect_q(a: Vector2i, b: Vector2i, c: Vector2i, d: Vector2i) -> bool:
	var ab_c := _cross(b - a, c - a)
	var ab_d := _cross(b - a, d - a)
	var cd_a := _cross(d - c, a - c)
	var cd_b := _cross(d - c, b - c)
	if ab_c == 0 and _on_segment(c, a, b): return true
	if ab_d == 0 and _on_segment(d, a, b): return true
	if cd_a == 0 and _on_segment(a, c, d): return true
	if cd_b == 0 and _on_segment(b, c, d): return true
	return ((ab_c < 0 and ab_d > 0) or (ab_c > 0 and ab_d < 0)) and ((cd_a < 0 and cd_b > 0) or (cd_a > 0 and cd_b < 0))

static func _nearest_q(point: Vector2i, contours: Array) -> Vector2i:
	var nearest := point
	var distance: int = 9223372036854775807
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			var candidate := _closest_q(point, Fixed.vector(polygon[index]), Fixed.vector(polygon[(index + 1) % polygon.size()]))
			var candidate_distance := Fixed.length_sq(point - candidate)
			if candidate_distance < distance:
				distance = candidate_distance
				nearest = candidate
	return nearest

static func _signed_distance_q(point: Vector2i, contours: Array) -> int:
	var distance := Fixed.isqrt(Fixed.length_sq(point - _nearest_q(point, contours)))
	return -distance if contains(Fixed.to_vector(point), contours) else distance

static func signed_distance(point: Vector2, contours: Array) -> float:
	return INF if contours.is_empty() else Fixed.to_float(_signed_distance_q(Fixed.vector(point), contours))

static func circle_hits(point: Vector2, radius: float, contours: Array) -> bool:
	if contains(point, contours): return true
	var limit := maxi(Fixed.coord(radius) - 1, 0)
	if limit == 0: return false
	var p := Fixed.vector(point)
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			var nearest := _closest_q(p, Fixed.vector(polygon[index]), Fixed.vector(polygon[(index + 1) % polygon.size()]))
			if Fixed.length_sq(p - nearest) < limit * limit: return true
	return false

static func segment_hits(from: Vector2, to: Vector2, radius: float, contours: Array) -> bool:
	var origin := Fixed.vector(from)
	var target := Fixed.vector(to)
	if circle_hits(from, radius, contours):
		# Permit escape from a changed shoreline, but never movement deeper in.
		var nearest := _nearest_q(origin, contours)
		var outward := nearest - origin if contains(from, contours) else origin - nearest
		return _dot(target - origin, outward) < 0 or _signed_distance_q(target, contours) < _signed_distance_q(origin, contours)
	if contains(to, contours): return true
	var limit := maxi(Fixed.coord(radius) - 1, 0)
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			var a := Fixed.vector(polygon[index])
			var b := Fixed.vector(polygon[(index + 1) % polygon.size()])
			if _segments_intersect_q(origin, target, a, b): return true
			var distance := mini(Fixed.length_sq(origin - _closest_q(origin, a, b)), Fixed.length_sq(target - _closest_q(target, a, b)))
			distance = mini(distance, Fixed.length_sq(a - _closest_q(a, origin, target)))
			distance = mini(distance, Fixed.length_sq(b - _closest_q(b, origin, target)))
			if distance < limit * limit: return true
	return false

## Bounding box of every contour point (empty contours: an empty Rect2).
static func contours_bounds(contours: Array) -> Rect2:
	var bounds := Rect2()
	var first := true
	for polygon: PackedVector2Array in contours:
		for point in polygon:
			if first:
				bounds = Rect2(point, Vector2.ZERO)
				first = false
			else:
				bounds = bounds.expand(point)
	return bounds

## Reject disjoint bounds on the same integer lattice as the exact tests.
## Touching boxes still need the polygon test, including along negative edges.
static func intersects_rect_within(rect: Rect2, contours: Array, bounds: Rect2) -> bool:
	var low := Fixed.vector(rect.position)
	var high := Fixed.vector(rect.end)
	var min_coast := Fixed.vector(bounds.position)
	var max_coast := Fixed.vector(bounds.end)
	if low.x > max_coast.x or low.y > max_coast.y or high.x < min_coast.x or high.y < min_coast.y:
		return false
	return intersects_rect(rect, contours)

static func intersects_rect(rect: Rect2, contours: Array) -> bool:
	var corners := rectangle(rect)
	var low := Fixed.vector(rect.position)
	var high := Fixed.vector(rect.end)
	for point in corners:
		if contains(point, contours): return true
	for polygon: PackedVector2Array in contours:
		for point in polygon:
			var p := Fixed.vector(point)
			if p.x > low.x and p.x < high.x and p.y > low.y and p.y < high.y: return true
		for index in polygon.size():
			for edge in corners.size():
				if _segments_intersect_q(Fixed.vector(polygon[index]), Fixed.vector(polygon[(index + 1) % polygon.size()]), Fixed.vector(corners[edge]), Fixed.vector(corners[(edge + 1) % corners.size()])): return true
	return false
