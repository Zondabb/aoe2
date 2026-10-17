extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Formation := preload("res://scripts/input/unit_formation.gd")
const Unit := preload("res://scenes/entities/unit_view.tscn")
const Terrain := preload("res://scripts/presentation/terrain_visual.gd")
var viewport: SubViewport
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func capture() -> Image:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func different(a: Image, b: Image, rect: Rect2i) -> int:
	var changed := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var delta := a.get_pixel(x, y) - b.get_pixel(x, y)
			if absf(delta.r) + absf(delta.g) + absf(delta.b) > 0.1:
				changed += 1
	return changed

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Rendering test needs a GPU backend")
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node2D.new()
	world.name = "Match"
	viewport.add_child(world)
	var ground := Node2D.new()
	world.add_child(ground)
	Terrain.setup_grass(ground, Rect2(-40, -40, 80, 80))
	var entities := Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	world.add_child(entities)
	var camera := Camera2D.new()
	world.add_child(camera)
	camera.position = Vector2(0, 70)
	var layer := CanvasLayer.new()
	world.add_child(layer)
	var selection := Selection.new()
	layer.add_child(selection)
	selection._camera = camera
	var state := MatchState.new()
	state.setup_defaults()
	var units: Array[Node2D] = []
	for i in 12:
		var unit := Unit.instantiate() as UnitAgent
		unit.def = GameCatalog.get_unit(&"militia" if i < 6 else &"archer")
		unit.match_state = state
		unit.sim_pos = Vector2(i % 4, int(i / 4)) * 2.0 - Vector2(4, 3)
		entities.add_child(unit)
		unit.set_physics_process(false)
		(unit.get_node("Billboard") as AnimatedSprite2D).stop()
		units.append(unit)
	var destinations := Formation.destinations(units, Vector2.ZERO, &"line")
	for i in units.size():
		units[i].sim_pos = destinations[i]
		units[i]._sync_visual()
	var bare := await capture()
	for unit in units: selection._add_selection(unit, false)
	selection._emit_selection_changed()
	selection.assign_control_group(1)
	var hud: Node = load("res://scenes/ui/hud.tscn").instantiate()
	layer.add_child(hud)
	hud.setup(state, load("res://data/civs/chinese.tres"), null, selection)
	var selected := await capture()
	check(different(bare, selected, Rect2i(420, 180, 440, 210)) > 800, "larger rings are visible around the selected group")
	check((hud.get_node("ControlGroups/Group1") as Button).visible, "group strip is visible")
	selected.save_png("res://.godot/controls-line.png")
	selection._show_move_marker(Vector2(7, 1))
	var marker := selection._move_marker
	marker.set_process(false)
	var early := await capture()
	marker.call("_process", 0.3)
	var middle := await capture()
	var click_pixel: Vector2 = viewport.get_canvas_transform() * marker.global_position
	var area := Rect2i(Vector2i(click_pixel) - Vector2i(40, 30), Vector2i(80, 60))
	check(different(early, middle, area) > 60, "right-click chevrons visibly contract across animation frames")
	middle.save_png("res://.godot/controls-move.png")
	marker.call("_process", 0.5)
	var expired := await capture()
	check(not marker.visible and different(middle, expired, area) > 15, "move animation vanishes after completion")
	for kind in [&"box", &"staggered", &"flank"]:
		selection.set_formation(kind)
		destinations = Formation.destinations(units, Vector2.ZERO, kind)
		for i in units.size():
			units[i].sim_pos = destinations[i]
			units[i]._sync_visual()
		var frame := await capture()
		frame.save_png("res://.godot/controls-%s.png" % kind)
		check(different(selected, frame, Rect2i(360, 150, 560, 300)) > 1000, "%s presents a distinct troop arrangement" % kind)
	# Zoomed-out rings must survive terrain and the unit's foot shadow.
	camera.zoom = Vector2(0.45, 0.45)
	var zoomed := await capture()
	for unit in units: unit.set_selected(false)
	var unselected := await capture()
	check(different(zoomed, unselected, Rect2i(450, 200, 380, 180)) > 150, "rings remain readable at minimum zoom")
	viewport.queue_free()
	await process_frame
	print("PLAYER CONTROLS RENDER: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
