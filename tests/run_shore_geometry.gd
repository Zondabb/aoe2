extends SceneTree

const SHORE := preload("res://scripts/world/shore_geometry.gd")
const TERRAIN := preload("res://scripts/entities/path_blocker.gd")
const NAV := preload("res://scripts/systems/nav_grid_service.gd")
const COLLISION := preload("res://scripts/systems/collision_resolver.gd")
const BUILD := preload("res://scripts/systems/build_system.gd")
const HOLDER := preload("res://scripts/systems/nav_service_holder.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)

func _region(parent: Node2D, center: Vector2, size: Vector2) -> PathBlocker:
	var actor := TERRAIN.new() as PathBlocker
	actor.kind = &"water"
	actor.auto_block_size = false
	actor.sim_pos = center
	actor.block_size = size
	parent.add_child(actor)
	return actor

func _check_simple(contours: Array, label: String) -> void:
	for contour: PackedVector2Array in contours:
		check(not Geometry2D.triangulate_polygon(contour).is_empty(), "coast triangulates: " + label)
		var simple := true
		for index in contour.size():
			for other in range(index + 2, contour.size()):
				if index == 0 and other == contour.size() - 1: continue
				if Geometry2D.segment_intersects_segment(contour[index], contour[(index + 1) % contour.size()], contour[other], contour[(other + 1) % contour.size()]) != null: simple = false
		check(simple, "coast has no crossing edges: " + label)

func _run() -> void:
	for sample in [Rect2(-14, -4, 12, 8), Rect2(-16, -11, 32, 22), Rect2(-112, 68, 64, 44)]:
		_check_simple(SHORE.build_contours([sample]), str(sample))
	for size in [Vector2(32, 22), Vector2(16, 12)]:
		var whole := SHORE.build_contours([Rect2(-size * 0.5, size)])
		var joined := SHORE.build_contours([Rect2(-size * 0.5, Vector2(size.x * 0.5, size.y)), Rect2(Vector2(0, -size.y * 0.5), Vector2(size.x * 0.5, size.y))])
		check(whole == joined, "single and adjacent authored patches generate exactly the same coast: %s" % size)
		var reordered := SHORE.build_contours([Rect2(Vector2(0, -size.y * 0.5), Vector2(size.x * 0.5, size.y)), Rect2(-size * 0.5, Vector2(size.x * 0.5, size.y))])
		check(whole == reordered, "brush insertion order does not change coastline: %s" % size)
		check(SHORE.contains(Vector2.ZERO, whole), "lake center remains water")
		check(not SHORE.contains(size * 0.5 - Vector2.ONE * 0.5, whole), "authored rectangular corner becomes dry sand")
		var count := 0
		for loop in whole: count += loop.size()
		check(count <= SHORE.MAX_VERTICES, "component fits the renderer contour budget")
		var inset := true
		for loop in whole:
			for point in loop: inset = inset and Rect2(-size * 0.5, size).has_point(point)
		check(inset, "coast stays inside authored bounds")
	var water_ring := SHORE.build_contours([Rect2(-16, -16, 32, 8), Rect2(-16, 8, 32, 8), Rect2(-16, -8, 8, 16), Rect2(8, -8, 8, 16)])
	_check_simple(water_ring, "water ring and dry island")
	check(not SHORE.contains(Vector2.ZERO, water_ring), "a dry island is preserved inside a merged water ring")
	check(SHORE.contains(Vector2(12, 0), water_ring), "merged ring retains its water barrier")
	check(SHORE.segment_hits(Vector2.ZERO, Vector2(24, 0), 0.35, water_ring), "circle sweep cannot leave the island through water")
	var filled_ring := SHORE.build_contours([Rect2(-16, -16, 32, 8), Rect2(-16, 8, 32, 8), Rect2(-16, -8, 8, 16), Rect2(8, -8, 8, 16), Rect2(-8, -8, 16, 16)])
	check(SHORE.contains(Vector2.ZERO, filled_ring), "painting over a dry island fills the hole")
	var narrow_frame := SHORE.build_contours([Rect2(2.9, -6, 0.2, 12), Rect2(-3.1, -6, 0.2, 12), Rect2(-6, 2.9, 12, 0.2), Rect2(-6, -3.1, 12, 0.2)])
	_check_simple(narrow_frame, "thin authored frame")
	check(not SHORE.contains(Vector2.ZERO, narrow_frame), "thin water frame preserves its dry center")
	check(SHORE.segment_hits(Vector2.ZERO, Vector2(5.5, 0), 0.35, narrow_frame), "rounding cannot erase a thin authored water barrier")
	var mirror_a := SHORE.build_contours([Rect2(-112, 68, 64, 44)])
	var mirror_b := SHORE.build_contours([Rect2(48, -112, 64, 44)])
	var mirrored := true
	for x in range(-110, -48, 4):
		for y in range(70, 112, 4):
			mirrored = mirrored and absf(SHORE.signed_distance(Vector2(x, y), mirror_a) - SHORE.signed_distance(Vector2(-x, -y), mirror_b)) < 0.12
	check(mirrored, "opposite default lakes preserve mirrored terrain and movement clearance")
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	world.add_child(entities)
	var holder := HOLDER.new()
	holder.setup_rect(Vector2i(-30, -30), Vector2i(30, 30))
	world.add_child(holder)
	holder.set_process(false)
	var left := _region(entities, Vector2(-8, 0), Vector2(16, 22))
	holder.rebuild_from_scene()
	check(holder.nav.is_world_walkable_with_radius(Vector2(-1, 0), 0.35), "initial patch exposes dry land at its inner edge")
	var old_contours := left.get_water_contours()
	var right := _region(entities, Vector2(8, 0), Vector2(16, 22))
	holder.rebuild_from_scene()
	check(left.get_water_contours() != old_contours and left.get_water_contours() == right.get_water_contours(), "adding a joined patch refreshes existing neighbor contours")
	check(not holder.nav.is_world_walkable_with_radius(Vector2(-1, 0), 0.35), "navigation cache changes with the joined coastline")
	check(holder.nav.is_world_walkable_with_radius(Vector2(15, 10), 0.35), "navigation allows the dry rounded corner inside the authoring rectangle")
	check(COLLISION.static_step_safe(Vector2(13, 10), Vector2(15, 10), 0.35, [left, right]), "collision agrees that the rounded corner is walkable")
	check(not COLLISION.static_step_safe(Vector2(-24, 0), Vector2(24, 0), 0.35, [left, right]), "large movement cannot tunnel across merged water")
	check(BUILD.can_place(Vector2.ONE, Vector2(15, 10), [left, right]), "construction can use dry beach inside the authoring rectangle")
	check(not BUILD.can_place(Vector2.ONE, Vector2.ZERO, [left, right]), "construction rejects the water interior")
	var geometry: Array[Dictionary] = [{"center":left.sim_pos, "half":left.block_half, "radius":0.35, "contours":left.get_water_contours()}]
	check(COLLISION.static_geometry_step_safe(Vector2(13, 10), Vector2(15, 10), geometry), "avoidance geometry also permits the dry corner")
	check(not COLLISION.static_geometry_step_safe(Vector2(-24, 0), Vector2(24, 0), geometry), "avoidance geometry blocks water sweeps")
	right.free()
	check(left.get_water_contours() == old_contours, "deletion immediately restores surviving coast before the deferred rebuild")
	await process_frame
	holder.rebuild_from_scene()
	check(left.get_water_contours() == old_contours and holder.nav.is_world_walkable_with_radius(Vector2(-1, 0), 0.35), "deletion restores surviving coast and navigation")
	left.sim_pos = Vector2(-10, 0)
	left._setup_visual()
	holder.rebuild_from_scene()
	check(left.get_water_contours() != old_contours and not holder.nav.is_world_walkable_with_radius(Vector2(-10, 0), 0.35), "position edits rebuild water contours and navigation")
	world.free()
	COLLISION.clear_map_bounds()
	await process_frame
	print("SHORE GEOMETRY: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
