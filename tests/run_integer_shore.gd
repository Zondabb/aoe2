extends SceneTree

const Shore := preload("res://scripts/world/shore_geometry.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const Blocker := preload("res://scripts/entities/path_blocker.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _region(parent: Node2D, at: Vector2, pending := false) -> PathBlocker:
	var actor: PathBlocker = Blocker.new()
	actor.kind = &"water"
	actor.auto_block_size = false
	actor.block_size = Vector2(20, 20)
	actor.sim_pos = at
	if pending: actor.set_meta("lockstep_water_pending", true)
	parent.add_child(actor)
	return actor

func _run() -> void:
	var square := [Shore.rectangle(Rect2(-10, -10, 20, 20))]
	check(Shore.contains(Vector2(-9, -9), square), "negative interior is water")
	check(Shore.contains(Vector2(-10, -10), square), "polygon vertices have an explicit inclusive boundary")
	check(not Shore.contains(Vector2(-10 - 1.0 / 1024, -10), square), "one quantum outside negative vertex is land")
	check(not Shore.circle_hits(Vector2(11, 0), 1.0, square), "tangent circle does not penetrate")
	check(Shore.circle_hits(Vector2(11 - 2.0 / 1024, 0), 1.0, square), "two quanta of penetration collide")
	check(not Shore.segment_hits(Vector2(-20, 11), Vector2(20, 11), 1.0, square), "tangent sweep remains walkable")
	check(Shore.segment_hits(Vector2(-20, 0), Vector2(20, 0), 0.35, square), "whole lake cannot be tunneled")
	check(Shore.segment_hits(Vector2(20, 0), Vector2(-20, 0), 0.35, square), "reverse whole-lake sweep agrees")
	check(not Shore.segment_hits(Vector2(9, 0), Vector2(12, 0), 0.35, square), "embedded unit can leave toward the nearest coast")
	check(Shore.segment_hits(Vector2(9, 0), Vector2(8, 0), 0.35, square), "embedded unit cannot move deeper into water")
	check(Shore.intersects_rect(Rect2(-2, -2, 4, 4), square), "placement rejects water interior")
	check(not Shore.intersects_rect(Rect2(-15, -15, 1, 1), square), "separated negative placement is dry")
	var bounds := Shore.contours_bounds(square)
	for end_x in [-10.125, -10.0009765625, -10.0004, -10.0, -9.9996, -9.99]:
		var placement := Rect2(float(end_x) - 2.0, -1.0, 2.0, 2.0)
		check(Shore.intersects_rect_within(placement, square, bounds) == Shore.intersects_rect(placement, square), "bounds filter agrees with polygon near negative edge at %f" % end_x)
	var island := square + [Shore.rectangle(Rect2(-2, -2, 4, 4))]
	check(not Shore.contains(Vector2.ZERO, island) and Shore.contains(Vector2(-5, 0), island), "integer parity preserves islands")
	check(Shore.segment_hits(Vector2.ZERO, Vector2(-20, 0), 0.35, island), "island exit still crosses water")
	check(Shore._closest_q(Vector2i(10, 10), Vector2i.ZERO, Vector2i(8, 0)) == Vector2i(8, 0), "projection clips to endpoint")
	check(Shore._closest_q(Vector2i(-5, -1), Vector2i(-10, 0), Vector2i(0, 0)) == Vector2i(-5, 0), "negative projection stays exact")
	check(Shore._closest_q(Vector2i(524288, -524288), Vector2i(-524288, -524288), Vector2i(524288, 524288)) == Vector2i.ZERO, "maximum map diagonal projection does not overflow")
	check(Shore._segments_intersect_q(Vector2i(-524288, -524288), Vector2i(524288, 524288), Vector2i(-524288, 524288), Vector2i(524288, -524288)), "maximum map diagonal intersection does not square a cross product")
	check(Shore._segments_intersect_q(Vector2i(0, 0), Vector2i(10, 0), Vector2i(5, 0), Vector2i(20, 0)), "collinear overlapping segments intersect")
	check(not Shore._segments_intersect_q(Vector2i(0, 0), Vector2i(10, 0), Vector2i(11, 0), Vector2i(20, 0)), "collinear separated segments do not intersect")
	var generated := Shore.build_contours([Rect2(-32, -20, 64, 40)])
	var on_grid := true
	for loop in generated:
		for point in loop: on_grid = on_grid and point == Fixed.quantize_vector(point)
	check(on_grid and not generated.is_empty(), "generated contour vertices are fixed grid coordinates")
	check(Shore.quantize_contours(generated) == generated, "contour quantization is idempotent")
	var world := Node2D.new()
	root.add_child(world)
	var host := _region(world, Vector2(-10, 0))
	host.freeze_water_contours()
	var original := host.water_contours.duplicate(true)
	var replica := _region(world, Vector2(30, 0), true)
	check(replica.is_in_group("terrain_regions") and replica.water_contours.is_empty(), "pending keyframe terrain registers without generating a local shore")
	var neighbor := _region(world, Vector2(10, 0))
	check(replica.water_contours.is_empty(), "ordinary neighbor refresh skips pending replica")
	host._refresh_water_regions()
	neighbor._refresh_water_regions()
	check(host.water_contours == original and host.water_contours_authoritative, "later neighbors cannot regenerate frozen host contours")
	var supplied := [PackedVector2Array([Vector2(-4.1234, -3), Vector2(4, -3), Vector2(4, 3), Vector2(-4, 3)])]
	host.apply_authoritative_water_contours(supplied)
	var expected := Shore.quantize_contours(supplied)
	replica.apply_authoritative_water_contours(supplied)
	check(not replica.has_meta("lockstep_water_pending") and replica.water_contours == expected, "host contour completes the pending replica")
	host.call_deferred("_refresh_water_regions")
	host._setup_visual()
	await process_frame
	check(host.water_contours == expected, "keyframe contours survive deferred refresh and visual rebuild")
	neighbor.free()
	await process_frame
	check(host.water_contours == expected, "neighbor deletion cannot replace restored authoritative contours")
	world.free()
	await process_frame
	print("INTEGER SHORE: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
