extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Build := preload("res://scripts/systems/build_system.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Unit := preload("res://scenes/entities/unit_view.tscn")
var checks := 0
var failures := 0
var world: Node2D
var entities: Node2D
var camera: Camera2D
var selection: SelectionController2D
var build: BuildSystem
var state: MatchState
var villager: UnitAgent
var hud: Node

class NetworkStub extends Node:
	var commands: Array[Dictionary] = []
	func entity_id(entity: Node2D) -> int: return entity.get_instance_id()
	func submit_command(command: Dictionary) -> bool:
		commands.append(command)
		return true

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func screen(pos: Vector2) -> Vector2:
	return root.get_canvas_transform() * Iso.world_to_screen(pos)

func mouse(pos: Vector2, pressed: bool, shift := false, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	event.shift_pressed = shift
	root.push_input(event, true)

func motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event, true)

func key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event, true)

func buildings() -> Array[Node2D]:
	var result: Array[Node2D] = []
	for node in entities.get_children():
		if node.get("def") is BuildingDef and not node.get("is_placement_ghost") and not node.is_queued_for_deletion(): result.append(node)
	return result

func reset_sites() -> void:
	build.cancel_placement()
	villager.command_stop()
	for node in entities.get_children():
		if node.get("def") is BuildingDef: node.free()
	state.resources[0][Enums.ResourceType.WOOD] = 2000
	state.resources[0][Enums.ResourceType.STONE] = 2000
	selection._clear_selection(false)
	selection._add_selection(villager)

func _run() -> void:
	root.size = Vector2i(1280, 720)
	world = Node2D.new()
	world.name = "Match"
	root.add_child(world)
	entities = Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	state = MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	state.set_age(0, 3)
	camera = Camera2D.new()
	world.add_child(camera)
	camera.make_current()
	var layer := CanvasLayer.new()
	world.add_child(layer)
	selection = Selection.new()
	layer.add_child(selection)
	selection._camera = camera
	villager = Unit.instantiate() as UnitAgent
	villager.def = Catalog.get_unit(&"villager")
	villager.sim_pos = Vector2(-8, -8)
	villager.match_state = state
	entities.add_child(villager)
	villager.set_physics_process(false)
	build = Build.new()
	world.add_child(build)
	build.setup(camera, entities, selection, state, load("res://data/civs/chinese.tres"))
	build.set_process(false)
	hud = load("res://scenes/ui/hud.tscn").instantiate()
	layer.add_child(hud)
	hud.setup(state, load("res://data/civs/chinese.tres"), build, selection)
	await process_frame
	camera.force_update_scroll()
	reset_sites()
	_test_drag_and_continue()
	await _test_cancel_and_gui(layer)
	_test_invalid_and_cost()
	_test_gate_input()
	_test_online_payload()
	reset_sites()
	await process_frame
	world.free()
	print("WALL CONTROLS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_drag_and_continue() -> void:
	check(build.begin_placement(Catalog.get_building(&"palisade_wall")), "a selected villager can enter wall placement")
	check(not selection.is_processing_unhandled_input(), "wall placement suspends conflicting selection gestures")
	var start := Vector2(-6, -4)
	var end := Vector2(0, -4)
	var wood_before := state.get_resource(0, Enums.ResourceType.WOOD)
	mouse(screen(start), true)
	check(buildings().is_empty(), "mouse press anchors the row without spending or building")
	motion(screen(end))
	check(build._wall_plan.size() == 7 and build._wall_ghosts.size() == 7, "drag previews every contiguous wall segment")
	check(build.get_placement_hint().contains("7 段"), "placement hint includes the whole row count")
	mouse(screen(end), false, true)
	check(buildings().size() == 7 and build.is_placing(), "Shift-release places the full row and retains placement mode")
	check(state.get_resource(0, Enums.ResourceType.WOOD) == wood_before - 7 * Catalog.get_building(&"palisade_wall").cost_wood, "a row pays for every new segment once")
	check(build._wall_anchor == end and build._wall_continuing, "continuation anchors at the accepted endpoint")
	var first_target: Variant = villager.get("_build_target")
	mouse(screen(end), true)
	var corner := Vector2(0, 0)
	motion(screen(corner))
	mouse(screen(corner), false)
	check(buildings().size() == 11, "turning a connected second row reuses the corner instead of duplicating it")
	check(not build.is_placing() and selection.is_processing_unhandled_input(), "ordinary release finishes placement and restores selection")
	check(villager.get("_build_target") == first_target, "Shift continuation retains the current construction target")
	check(selection.get_selected_units() == [villager], "drag-release never replaces the selected builders")
	reset_sites()
	for direction in [Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1), Vector2.LEFT, Vector2(-1, -1), Vector2.UP, Vector2(1, -1)]:
		build.begin_placement(Catalog.get_building(&"palisade_wall"))
		mouse(screen(Vector2(-2, -4)), true)
		motion(screen(Vector2(-2, -4) + direction * 3))
		check(build._wall_plan.size() == 4 and build._wall_plan[-1].pos == Vector2(-2, -4) + direction * 3, "wall drag snaps correctly in direction %s" % direction)
		build.cancel_placement()

func _test_cancel_and_gui(layer: CanvasLayer) -> void:
	reset_sites()
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	mouse(screen(Vector2(-3, -4)), true)
	motion(screen(Vector2(2, -4)))
	key(KEY_ESCAPE)
	check(not build.is_placing() and buildings().is_empty(), "Escape cancels all row previews without spending")
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	mouse(screen(Vector2(-3, -4)), true)
	mouse(screen(Vector2(2, -4)), true, false, MOUSE_BUTTON_RIGHT)
	check(not build.is_placing() and buildings().is_empty(), "right click cancels an active wall drag")
	var blocker := Panel.new()
	blocker.position = Vector2(20, 80)
	blocker.size = Vector2(150, 90)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(blocker)
	await process_frame
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	mouse(screen(Vector2(-3, -4)), true)
	motion(Vector2(40, 100))
	mouse(Vector2(40, 100), false)
	await process_frame
	check(build.is_placing() and not build._wall_dragging and not build._wall_has_anchor, "GUI-consumed release discards the unfinished wall gesture")
	check(buildings().is_empty(), "releasing on GUI cannot place a wall behind the HUD")
	mouse(screen(Vector2(-3, -4)), false)
	check(buildings().is_empty(), "a later release cannot accidentally submit a stale drag")
	blocker.free()
	build.cancel_placement()

func _test_invalid_and_cost() -> void:
	reset_sites()
	state.resources[0][Enums.ResourceType.WOOD] = Catalog.get_building(&"palisade_wall").cost_wood
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	mouse(screen(Vector2(-5, -4)), true)
	motion(screen(Vector2(0, -4)))
	check(not build._placement_valid and build.get_placement_hint().contains("资源不足"), "whole-row cost rejects an unaffordable drag")
	mouse(screen(Vector2(0, -4)), false)
	check(buildings().is_empty() and state.get_resource(0, Enums.ResourceType.WOOD) == Catalog.get_building(&"palisade_wall").cost_wood, "unaffordable rows place no partial wall and spend nothing")
	reset_sites()
	build.begin_placement(Catalog.get_building(&"stone_wall"))
	mouse(screen(Vector2(-6, -4)), true)
	build._wall_include_gate = true
	build._update_ghost_position(screen(Vector2(-5, -4)))
	check(build.is_placing() and not build._placement_valid and build._wall_plan.is_empty(), "too-short gated rows remain editable and show invalid preview")
	build._update_ghost_position(screen(Vector2(2, -4)))
	var gates := 0
	for entry in build._wall_plan:
		if entry.building_def_id == "gate": gates += 1
	check(gates == 1 and build._placement_valid, "extending the same drag inserts one correctly aligned gate")
	mouse(screen(Vector2(2, -4)), false)
	check(buildings().size() == 6, "gated row replaces four wall cells with one gate")
	reset_sites()
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	build._wall_has_anchor = true
	build._wall_anchor = Vector2.ZERO
	build._update_wall_preview(Vector2(100, 0))
	check(build.is_placing() and not build._placement_valid, "exceeding 64 cells preserves editable placement mode")
	build._update_wall_preview(Vector2(5, 0))
	check(build._placement_valid and build._wall_plan.size() == 6, "drag can recover from an excessive row length")
	reset_sites()

func _test_gate_input() -> void:
	build.begin_placement(Catalog.get_building(&"gate"))
	var original: Vector2 = build._ghost.get_placement_footprint()
	key(KEY_R)
	check(build._gate_orientation == 1 and build._ghost.wall_orientation == 1, "R rotates the gate preview before HUD building hotkeys")
	key(KEY_R)
	check(build._ghost.get_placement_footprint() == Vector2(original.y, original.x), "gate rotation updates the real construction footprint")
	mouse(screen(Vector2(-2, -4)), true)
	mouse(screen(Vector2(-2, -4)), false)
	var gate := buildings()[0]
	check(gate.wall_orientation == 2, "placed gate preserves preview orientation")
	gate.add_build_progress(gate.def.build_time)
	selection._clear_selection(false)
	selection._add_selection(gate)
	var grid: GridContainer = hud.get_node("%CommandGrid")
	check(grid.get_child(0).get_meta("gate_state") == "auto" and grid.get_child(2).get_meta("gate_state") == "locked", "selected completed gate exposes three mode buttons")
	(grid.get_child(2) as Button).pressed.emit()
	check(gate.gate_state == "locked" and (grid.get_child(2) as Button).button_pressed, "lock button updates gate state and current-mode highlight")
	(grid.get_child(1) as Button).pressed.emit()
	check(gate.gate_state == "open", "open button keeps the gate open")
	reset_sites()

func _test_online_payload() -> void:
	var network := NetworkStub.new()
	network.name = "NetworkMatch"
	world.add_child(network)
	world.set_meta("online_match", true)
	build.begin_placement(Catalog.get_building(&"palisade_wall"))
	mouse(screen(Vector2(-6, -4)), true)
	mouse(screen(Vector2(0, -4)), false, true)
	check(network.commands.size() == 1 and network.commands[0].op == "place_wall", "online drag sends one atomic wall-row command")
	check(network.commands[0].start == [-6.0, -4.0] and network.commands[0].end == [0.0, -4.0], "online row carries snapped endpoints")
	check(buildings().is_empty(), "online wall placement leaves authoritative creation to the host")
	mouse(screen(Vector2(0, -4)), true)
	mouse(screen(Vector2(0, 0)), false)
	check(network.commands.size() == 2 and network.commands[1].append_queue, "online Shift continuation explicitly appends construction work")
	build.begin_placement(Catalog.get_building(&"gate"))
	key(KEY_R)
	mouse(screen(Vector2(-2, -4)), true)
	check(network.commands[-1].op == "place_building" and network.commands[-1].orientation == 1, "online standalone gate command carries its rotation")
	world.remove_meta("online_match")
	network.free()
