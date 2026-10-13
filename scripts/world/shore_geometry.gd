extends RefCounted

## Authored rectangles remain map handles. Their union defines one deterministic
## inset coast, shared by rendering, placement and moving-circle collisions.
const MAX_VERTICES := 192
const COAST_STEP := 3.0

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
	for polygon: PackedVector2Array in contours:
		if Geometry2D.is_point_in_polygon(point, polygon): inside = not inside
	return inside

static func signed_distance(point: Vector2, contours: Array) -> float:
	var nearest := INF
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			nearest = minf(nearest, point.distance_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])))
	return -nearest if contains(point, contours) else nearest

static func circle_hits(point: Vector2, radius: float, contours: Array) -> bool:
	if contains(point, contours): return true
	var limit := maxf(radius - 0.0001, 0.0)
	if limit == 0.0: return false
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			if point.distance_squared_to(Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])) < limit * limit: return true
	return false

static func segment_hits(from: Vector2, to: Vector2, radius: float, contours: Array) -> bool:
	if circle_hits(from, radius, contours):
		# Permit escape from a changed shoreline, but never movement deeper in.
		var nearest := Vector2.INF
		var distance := INF
		for polygon: PackedVector2Array in contours:
			for index in polygon.size():
				var candidate := Geometry2D.get_closest_point_to_segment(from, polygon[index], polygon[(index + 1) % polygon.size()])
				if from.distance_squared_to(candidate) < distance:
					distance = from.distance_squared_to(candidate)
					nearest = candidate
		var outward := nearest - from if contains(from, contours) else from - nearest
		return (to - from).dot(outward) < -0.00001 or signed_distance(to, contours) < signed_distance(from, contours) - 0.0001
	if contains(to, contours): return true
	var limit := maxf(radius - 0.0001, 0.0)
	for polygon: PackedVector2Array in contours:
		for index in polygon.size():
			var a := polygon[index]
			var b := polygon[(index + 1) % polygon.size()]
			if Geometry2D.segment_intersects_segment(from, to, a, b) != null: return true
			var distance := minf(from.distance_to(Geometry2D.get_closest_point_to_segment(from, a, b)), to.distance_to(Geometry2D.get_closest_point_to_segment(to, a, b)))
			distance = minf(distance, a.distance_to(Geometry2D.get_closest_point_to_segment(a, from, to)))
			distance = minf(distance, b.distance_to(Geometry2D.get_closest_point_to_segment(b, from, to)))
			if distance < limit: return true
	return false

static func intersects_rect(rect: Rect2, contours: Array) -> bool:
	var corners := rectangle(rect)
	for point in corners:
		if contains(point, contours): return true
	for polygon: PackedVector2Array in contours:
		for point in polygon:
			if point.x > rect.position.x + 0.0001 and point.x < rect.end.x - 0.0001 and point.y > rect.position.y + 0.0001 and point.y < rect.end.y - 0.0001: return true
		for index in polygon.size():
			for edge in corners.size():
				if Geometry2D.segment_intersects_segment(polygon[index], polygon[(index + 1) % polygon.size()], corners[edge], corners[(edge + 1) % corners.size()]) != null: return true
	return false
