extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func _run() -> void:
	for type in [Enums.ResourceType.WOOD, Enums.ResourceType.GOLD, Enums.ResourceType.STONE]:
		for direction in [Vector2(-7,0), Vector2(-7,-7), Vector2(7,7)]:
			_test_click_and_collect(type,direction)
	check(checks >= 45,"all resource scenarios completed")
	print("RESOURCE GATHERING: %d checks, %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_click_and_collect(type: Enums.ResourceType, direction: Vector2) -> void:
	var label := "%d from %s" % [type,direction]
	var world := Node2D.new()
	root.add_child(world)
	var state := MatchState.new()
	state.setup_defaults()
	var resource := ResourceNode.new()
	resource.resource_type = type
	resource.amount = 100
	resource.sim_pos = Vector2(4,4)
	world.add_child(resource)
	var worker: UnitAgent = load("res://scenes/entities/unit_view.tscn").instantiate()
	worker.def = GameCatalog.get_unit(&"villager")
	worker.match_state = state
	worker.sim_pos = resource.sim_pos + direction
	world.add_child(worker)
	worker.set_physics_process(false)
	var nav := NavServiceHolder.new()
	nav.setup(-30,30)
	world.add_child(nav)
	nav.set_process(false)
	nav.rebuild_from_scene()
	var selection := Selection.new()
	world.add_child(selection)
	selection._add_selection(worker)
	var sprite := resource.get_node("Billboard") as Sprite2D
	var rect := sprite.get_rect()
	# Use real imported artwork, finding an opaque canopy/ore pixel well away
	# from the resource's ground origin. Center-only click tests missed this bug.
	var click_canvas := resource.global_position
	var furthest := 0.0
	for y in range(0,ceili(rect.size.y),2):
		for x in range(0,ceili(rect.size.x),2):
			var local := rect.position + Vector2(x+0.5,y+0.5)
			if not sprite.is_pixel_opaque(local): continue
			var canvas := sprite.to_global(local)
			var distance := canvas.distance_to(resource.global_position)
			if distance > furthest:
				furthest = distance
				click_canvas = canvas
	check(furthest > Selection.CLICK_RADIUS,"real artwork extends outside old click radius: "+label)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = root.get_canvas_transform() * click_canvas
	selection._unhandled_input(click)
	check(worker.order == Enums.OrderType.GATHER and worker._gather_target == resource,"right-click canopy/ore issues gather: "+label)
	var approach := resource.approach_point(worker.sim_pos,worker.def.resolved_footprint_radius())
	var clearance := resource.block_half + Vector2.ONE*worker.def.resolved_footprint_radius()
	var offset := (approach-resource.sim_pos).abs()
	check(offset.x >= clearance.x or offset.y >= clearance.y,"work point clears the resource collision box: "+label)
	for frame in 200:
		nav._process(0.1)
		worker._physics_process(0.1)
		if worker.carry_amount > 0: break
	check(worker.carry_amount > 0 and resource.amount < 100,"worker reaches resource and actually extracts it: "+label)
	var expected_action := "chop_dir_" if type == Enums.ResourceType.WOOD else "mine_dir_"
	var worker_sprite := worker.get_node("Billboard") as AnimatedSprite2D
	check(String(worker_sprite.animation).begins_with(expected_action), "worker uses the matching work animation: "+label)
	check(ResourceNode.edge_distance(worker.sim_pos,resource.sim_pos,type) >= worker.def.resolved_footprint_radius()-0.06,"worker stands outside resource while collecting: "+label)
	# Empty texture padding above the footprint must remain a ground click.
	var transparent := rect.position + Vector2(0.5,0.5)
	if not sprite.is_pixel_opaque(transparent):
		var screen := root.get_canvas_transform() * sprite.to_global(transparent)
		check(selection._resource_at_screen(screen) == null,"transparent sprite padding does not capture clicks: "+label)
	world.free()
	CollisionResolver.clear_map_bounds()
