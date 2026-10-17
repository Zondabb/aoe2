extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Formation := preload("res://scripts/input/unit_formation.gd")
const Unit := preload("res://scenes/entities/unit_view.tscn")
var checks := 0
var failures := 0
var world: Node2D
var selection: SelectionController2D
var camera: Camera2D
var state: MatchState

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

func unit_at(pos: Vector2, id: StringName = &"villager", team: int = 0) -> UnitAgent:
	var unit := Unit.instantiate() as UnitAgent
	unit.def = GameCatalog.get_unit(id)
	unit.sim_pos = pos
	unit.team = team as Enums.Team
	unit.match_state = state
	world.add_child(unit)
	unit.set_physics_process(false)
	return unit

func screen_point(unit: Node2D) -> Vector2:
	return root.get_canvas_transform() * selection._visual_rect_canvas(unit).get_center()

func click(pos: Vector2, shift := false, double := false) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = pos
		event.pressed = pressed
		event.shift_pressed = shift
		event.double_click = double and pressed
		selection._unhandled_input(event)

func key(code: Key, ctrl := false, shift := false, alt := false, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.echo = echo
	selection._unhandled_input(event)

func _run() -> void:
	root.size = Vector2i(1280, 720)
	world = Node2D.new()
	world.name = "Match"
	root.add_child(world)
	state = MatchState.new()
	state.setup_defaults()
	camera = Camera2D.new()
	world.add_child(camera)
	camera.make_current()
	var layer := CanvasLayer.new()
	world.add_child(layer)
	selection = Selection.new()
	layer.add_child(selection)
	selection._camera = camera
	var a := unit_at(Vector2(-6, 0))
	var b := unit_at(Vector2(-2, 0))
	var c := unit_at(Vector2(3, 0), &"archer")
	var offscreen := unit_at(Vector2(100, 100))
	var enemy := unit_at(Vector2(0, 5), &"villager", 1)
	var hidden := unit_at(Vector2(0, -4))
	hidden.hide()
	await process_frame
	camera.force_update_scroll()
	click(screen_point(a))
	check(selection.get_selected_units() == [a], "left click selects the clicked unit")
	click(screen_point(b), true)
	check(selection.get_selected_units().size() == 2, "Shift-click adds another unit")
	click(screen_point(a), true)
	check(selection.get_selected_units() == [b], "Shift-click toggles a selected unit off")
	click(screen_point(a), false, true)
	check(selection.get_selected_units().size() == 2 and a in selection._selected and b in selection._selected, "double-click selects visible friendly units of the same type")
	check(c not in selection._selected and enemy not in selection._selected and offscreen not in selection._selected and hidden not in selection._selected, "double-click excludes other types, opponents, hidden and offscreen units")
	check(not selection._dragging, "double-click release does not replace the whole type selection")
	click(screen_point(c), true, true)
	check(selection.get_selected_units().size() == 3, "Shift-double-click adds a type to selection")
	var start := Vector2(950, 480)
	var end := Vector2(250, 160)
	selection._drag_start = start
	selection._dragging = true
	selection._finish_selection(end, false)
	check(selection.get_selected_units().size() == 3 and enemy not in selection._selected, "reverse-direction box selection selects friendly units only")
	click(screen_point(enemy))
	key(KEY_4, true)
	check(selection.get_control_group(4).is_empty(), "an inspected opponent cannot be added to a group")
	selection._clear_selection(false)
	selection._add_selection(a, false)
	selection._add_selection(b)
	key(KEY_1, true)
	check(selection.get_control_group(1) == [a, b], "Ctrl+1 creates group 1")
	check((a.get_node("ControlGroupBadge") as Label).text == "1", "selected units display their group number")
	click(screen_point(c))
	key(KEY_1, false, true)
	check(selection.get_control_group(1).size() == 3, "Shift+1 appends selection to the existing group")
	selection._clear_selection()
	key(KEY_1)
	check(selection._selected.size() == 3, "1 recalls the full group")
	camera.position = Vector2(200, 200)
	key(KEY_1)
	check(camera.global_position.is_equal_approx(IsoMath.world_to_screen(Formation.center([a, b, c]))), "double-tapping group number centers the camera")
	click(screen_point(a))
	key(KEY_0, true)
	check(selection.get_control_group(0) == [a], "zero is a usable control group")
	key(KEY_2, true, false, false, true)
	check(selection.get_control_group(2).is_empty(), "keyboard repeat cannot overwrite a group")
	var editor := LineEdit.new()
	layer.add_child(editor)
	editor.grab_focus()
	key(KEY_3, true)
	check(selection.get_control_group(3).is_empty(), "text entry does not activate gameplay group hotkeys")
	editor.release_focus()
	editor.queue_free()
	selection.read_only = true
	key(KEY_3, true)
	check(selection.get_control_group(3).is_empty(), "read-only spectators cannot create command groups")
	selection.read_only = false
	key(KEY_1)
	b.queue_free()
	selection._process(0)
	check(selection.get_control_group(1).size() == 2, "queued deaths are pruned from groups")
	await process_frame
	selection.recall_control_group(1)
	check(selection._selected.size() == 2, "recall tolerates freed members")
	var before_empty := selection._selected.duplicate()
	selection.recall_control_group(9)
	check(selection._selected == before_empty, "recalling an empty group preserves current selection")
	selection._issue_move(Vector2(12, 8))
	check(a.order == Enums.OrderType.MOVE and c.order == Enums.OrderType.MOVE, "group right-click gives movement orders")
	check(a._requested_move_target.distance_to(c._requested_move_target) >= 1.65 - 0.001, "group destinations are separated")
	check(selection._move_marker.visible and selection._move_marker.has_method("play_at"), "movement starts the animated ground marker")
	selection._move_marker.set_process(false)
	selection._move_marker.call("_process", 0.8)
	check(not selection._move_marker.visible, "move marker ends automatically")
	selection._issue_move(Vector2(14, 9))
	check(selection._move_marker.visible and selection._move_marker.get("elapsed") == 0.0, "repeated move restarts the marker at the latest click")
	selection.set_formation(&"flank")
	check(selection.formation_mode == &"flank" and a.get_meta("manual_formation") == &"flank", "formation change applies to selected members")
	var network := NetworkStub.new()
	network.name = "NetworkMatch"
	world.add_child(network)
	world.set_meta("online_match", true)
	selection._issue_move(Vector2(10, 10))
	check(network.commands.size() == 2 and network.commands[0].pos != network.commands[1].pos, "online formation sends distinct per-unit positions to host")
	check(network.commands[0].formation_speed == minf(a.def.move_speed, c.def.move_speed), "online group order carries the shared marching speed")
	world.remove_meta("online_match")
	_test_group_speed(a, c)
	await _test_network_speed(a, c, network)
	var ring := a.get_node("SelectionRing") as Line2D
	check(ring.width == 2 and ring.points[0].x >= 21, "unit selection ellipse is larger and thicker")
	check(ring.has_node("Outline") and ring.z_index < a.get_node("Billboard").z_index, "selection has a dark contour and stays under the body")
	_test_formations([a, c])
	_test_formation_roles()
	# Load after project autoloads exist; HUD references NetworkSession.
	var hud: Node = load("res://scenes/ui/hud.tscn").instantiate()
	layer.add_child(hud)
	hud.setup(state, load("res://data/civs/chinese.tres"), null, selection)
	var grid := hud.get_node("%CommandGrid")
	check(grid.get_child(5) is Button and grid.get_child(8).get_meta("formation_kind") == &"flank", "HUD exposes all four original formation buttons")
	(grid.get_child(6) as Button).pressed.emit()
	check(selection.formation_mode == &"box" and (grid.get_child(6) as Button).button_pressed, "formation button applies and highlights the active formation")
	check((hud.get_node("ControlGroups/Group1") as Button).visible, "HUD displays existing group and live member count")
	var input := InputEventKey.new()
	input.keycode = KEY_P
	input.pressed = true
	hud._unhandled_key_input(input)
	check(selection.formation_mode == &"staggered", "formation hotkey follows active command page")
	hud._set_command_page("economy")
	await process_frame
	input.keycode = KEY_I
	hud._unhandled_key_input(input)
	check(selection.formation_mode == &"staggered", "villager build-menu hotkeys do not change formations")
	await _test_input_dispatch(a, c, hud)
	selection.assign_control_group(8)
	a.hp = 0
	selection._process(0)
	check(a not in selection.get_control_group(8) and a not in selection._selected and not (a.get_node("SelectionRing") as CanvasItem).visible, "dying units leave groups and selection before their death animation finishes")
	c.team = Enums.Team.AI
	selection._process(0)
	check(selection.get_control_group(8).is_empty(), "ownership changes remove members from local control groups")
	world.queue_free()
	await process_frame
	print("PLAYER CONTROLS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_group_speed(a: UnitAgent, c: UnitAgent) -> void:
	a.def = a.def.duplicate()
	c.def = c.def.duplicate()
	a.def.move_speed = 6
	c.def.move_speed = 3
	selection._issue_move(Vector2(20, 20), false)
	check(a._movement_speed() == 3 and c._movement_speed() == 3, "mixed units march at the slowest selected unit's speed")
	var before := a.sim_pos
	a._direct_step_toward(a.sim_pos + Vector2(10, 0), 0.1)
	check(a.sim_pos.distance_to(before) <= 0.301, "movement integration uses the shared pace")
	a.command_move(Vector2(25, 25))
	check(a._movement_speed() == 6, "individual command restores independent movement speed")
	a.set_formation_move_speed(999)
	check(a._movement_speed() == 6, "formation pace cannot accelerate beyond a unit's own speed")
	a.command_stop()
	check(a._movement_speed() == 6, "stopping leaves no speed restriction on later work")

func _test_network_speed(a: UnitAgent, c: UnitAgent, stub: Node) -> void:
	world.remove_child(stub)
	stub.queue_free()
	var runtime: Node = load("res://scripts/network/network_match.gd").new()
	runtime.name = "NetworkMatch"
	runtime.entities = world
	runtime.match_state = state
	runtime.is_host = true
	runtime._playing = true
	world.add_child(runtime)
	var id: int = runtime.entity_id(a)
	var command := {"op": "move", "unit_id": id, "pos": [20, 20], "formation_speed": 3.0}
	check(runtime.execute_team_command(command, 0) and a._movement_speed() == 3, "host accepts owned formation movement with shared pace")
	command.formation_speed = 1000.0
	check(not runtime.execute_team_command(command, 0), "host rejects accelerated formation pace")
	command.formation_speed = "3"
	check(not runtime.execute_team_command(command, 0), "host rejects malformed formation pace")
	command.formation_speed = NAN
	check(not runtime.execute_team_command(command, 0), "host rejects nonfinite formation pace")
	command.formation_speed = 3.0
	check(not runtime.execute_team_command(command, 1), "formation commands cannot move another player's units")
	command.erase("formation_speed")
	check(runtime.execute_team_command(command, 0) and a._movement_speed() == 6, "ordinary network move restores normal speed")
	runtime.queue_free()
	await process_frame
	c.command_stop()

func _test_formations(units: Array) -> void:
	for kind in Formation.KINDS:
		for count in [1, 2, 3, 5, 9, 17, 40]:
			var slots := Formation.offsets(count, kind, 1.65)
			var sum := Vector2.ZERO
			var separated := true
			for i in slots.size():
				sum += slots[i]
				for j in range(i):
					if slots[i].distance_to(slots[j]) < 1.64: separated = false
			check(slots.size() == count and sum.length() < 0.001, "%s/%d centered at click including partial rows" % [kind, count])
			check(separated, "%s/%d has no colliding slots" % [kind, count])
		var targets := Formation.destinations(units, Vector2(20, 20), kind)
		var reversed := Formation.destinations([units[1], units[0]], Vector2(20, 20), kind)
		check(targets[0].is_equal_approx(reversed[1]), "%s assignments do not depend on selection order" % kind)

func _test_formation_roles() -> void:
	var members: Array[Node2D] = []
	for i in 9:
		members.append(unit_at(Vector2(i % 3, int(i / 3)) * 2.0, &"militia" if i < 8 else &"archer"))
	var goal := Vector2(15, 15)
	var box := Formation.destinations(members, goal, &"box")
	check(box[8].is_equal_approx(goal), "box shelters the ranged unit in its center")
	var line := Formation.destinations(members, goal, &"line")
	var forward := (goal - Formation.center(members)).normalized()
	var front := -INF
	for i in 8: front = maxf(front, (line[i] - goal).dot(forward))
	check((line[8] - goal).dot(forward) < front, "line puts ranged troops behind the melee front")
	for member in members: member.free()

func push_mouse(pos: Vector2, button: MouseButton, pressed: bool, double := false) -> void:
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	event.double_click = double
	root.push_input(event, true)

func _test_input_dispatch(a: UnitAgent, c: UnitAgent, hud: Node) -> void:
	hud._set_command_page("root")
	await process_frame
	push_mouse(screen_point(a), MOUSE_BUTTON_LEFT, true)
	push_mouse(screen_point(a), MOUSE_BUTTON_LEFT, false)
	await process_frame
	check(selection.get_selected_units() == [a], "real viewport input dispatch selects world units")
	var event := InputEventKey.new()
	event.keycode = KEY_7
	event.ctrl_pressed = true
	event.pressed = true
	root.push_input(event, true)
	check(selection.get_control_group(7) == [a], "real keyboard dispatch creates a control group")
	var target := Vector2(1000, 180)
	push_mouse(target, MOUSE_BUTTON_RIGHT, true)
	push_mouse(target, MOUSE_BUTTON_RIGHT, false)
	check(a.order == Enums.OrderType.MOVE and a._requested_move_target.is_equal_approx(selection._canvas_to_logical(target)), "real right-click sends a move to the ground point")
	var destination := a._requested_move_target
	push_mouse(Vector2(30, 55), MOUSE_BUTTON_RIGHT, true)
	push_mouse(Vector2(30, 55), MOUSE_BUTTON_RIGHT, false)
	check(a._requested_move_target == destination, "right-click on group UI cannot leak a world move")
	push_mouse(screen_point(a), MOUSE_BUTTON_LEFT, true)
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(30, 55)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	push_mouse(Vector2(30, 55), MOUSE_BUTTON_LEFT, false)
	await process_frame
	check(not selection._dragging, "release consumed by GUI clears an in-progress selection drag")
	# Double click must exclude units underneath the opaque bottom HUD.
	var hidden_by_hud := unit_at(IsoMath.screen_to_world(root.get_canvas_transform().affine_inverse() * Vector2(800, 690)))
	push_mouse(screen_point(a), MOUSE_BUTTON_LEFT, true, true)
	push_mouse(screen_point(a), MOUSE_BUTTON_LEFT, false)
	check(hidden_by_hud not in selection._selected and a in selection._selected, "double-click only includes units in the playable screen area")
	hidden_by_hud.queue_free()
	selection._clear_selection(false)
	selection._add_selection(a, false)
	selection._add_selection(c)
