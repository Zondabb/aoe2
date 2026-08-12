extends Control

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SelectionControllerScript := preload("res://scripts/input/selection_controller_2d.gd")
const CLICK_RADIUS := 28.0

@export var camera_path: NodePath
@export var debug_overlay_path: NodePath

var _camera: Camera2D
var _debug_overlay: Node2D
var _selected: Array[Node2D] = []
var _move_marker: Node2D
var _move_marker_ttl := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_camera = get_node_or_null(camera_path) as Camera2D
	_debug_overlay = get_node_or_null(debug_overlay_path) as Node2D
	_move_marker = get_node_or_null("../../MoveMarker") as Node2D
	set_process(true)

func _process(delta: float) -> void:
	if _move_marker_ttl <= 0.0:
		return
	_move_marker_ttl = maxf(0.0, _move_marker_ttl - delta)
	if _move_marker != null:
		var fade := clampf(_move_marker_ttl / 1.35, 0.0, 1.0)
		_move_marker.modulate.a = 0.85 * fade
		if _move_marker_ttl <= 0.0:
			_move_marker.visible = false
	if _debug_overlay != null and _debug_overlay.has_method("set_selected_units"):
		_debug_overlay.call("set_selected_units", _selected)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event := event as InputEventKey
		if key_event.keycode == KEY_G and _debug_overlay != null:
			if _debug_overlay.has_method("toggle_footprints"):
				_debug_overlay.call("toggle_footprints")
			return
		if key_event.keycode == KEY_R:
			_reset_villagers()
			return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_select_at_screen(mouse_event.position, mouse_event.shift_pressed)
		elif (
			mouse_event.pressed
			and mouse_event.button_index == MOUSE_BUTTON_RIGHT
			and not _selected.is_empty()
		):
			var resource := _resource_at_screen(mouse_event.position)
			if resource != null:
				_issue_gather(resource)
				return
			_issue_move(_canvas_to_logical(mouse_event.position))

func _select_at_screen(screen_position: Vector2, additive: bool) -> void:
	var hit := _unit_at_screen(screen_position)
	if not additive:
		for unit in _selected:
			if is_instance_valid(unit) and unit.has_method("set_selected"):
				unit.call("set_selected", false)
		_selected.clear()
	if hit != null:
		if not _selected.has(hit):
			_selected.append(hit)
		if hit.has_method("set_selected"):
			hit.call("set_selected", true)

func _issue_move(target: Vector2) -> void:
	var movers: Array[Node2D] = []
	for unit in _selected:
		if is_instance_valid(unit) and unit.has_method("command_move"):
			movers.append(unit)
	for index in movers.size():
		var slot := SelectionControllerScript.formation_offset(
			index, movers.size(), SelectionControllerScript.FORMATION_SPACING
		)
		movers[index].call("command_move", target + slot)
	_show_move_marker(target)

func _issue_gather(resource: Node2D) -> void:
	for unit in _selected:
		if is_instance_valid(unit) and unit.has_method("command_gather"):
			unit.call("command_gather", resource)

func _show_move_marker(target: Vector2) -> void:
	if _move_marker == null:
		return
	_move_marker.position = IsoMathScript.world_to_screen(target)
	_move_marker.visible = true
	_move_marker.modulate.a = 0.85
	_move_marker_ttl = 1.35

func _reset_villagers() -> void:
	var spawn_points := [
		Vector2(-12.0, -8.0),
		Vector2(-10.0, -10.0),
		Vector2(-14.0, -6.0),
	]
	var index := 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get("team") != Enums.Team.PLAYER:
			continue
		if not unit.has_method("command_stop"):
			continue
		unit.call("command_stop")
		if index < spawn_points.size():
			unit.set("sim_pos", spawn_points[index])
			if unit.has_method("_sync_visual"):
				unit.call("_sync_visual")
			index += 1

func _unit_at_screen(screen_position: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist := CLICK_RADIUS
	for unit in get_tree().get_nodes_in_group("units"):
		var node := unit as Node2D
		if node == null or node.get("team") != Enums.Team.PLAYER:
			continue
		var screen := IsoMathScript.world_to_screen(node.get("sim_pos"))
		var dist := screen.distance_to(screen_position)
		if dist < best_dist:
			best_dist = dist
			best = node
	return best

func _resource_at_screen(screen_position: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist := CLICK_RADIUS * 1.5
	for resource in get_tree().get_nodes_in_group("resource_nodes"):
		var node := resource as Node2D
		if node == null or float(node.get("amount")) <= 0.0:
			continue
		var screen := IsoMathScript.world_to_screen(node.get("sim_pos"))
		var dist := screen.distance_to(screen_position)
		if dist < best_dist:
			best_dist = dist
			best = node
	return best

func _canvas_to_logical(screen_position: Vector2) -> Vector2:
	var world := screen_position
	if _camera != null:
		world = _camera.get_canvas_transform().affine_inverse() * screen_position
	return IsoMathScript.screen_to_world(world)
