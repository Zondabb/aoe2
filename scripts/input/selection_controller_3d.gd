class_name SelectionController3D
extends Control

const GroundPickerScript := preload("res://scripts/input/ground_picker.gd")
const DRAG_THRESHOLD := 6.0
const CLICK_RADIUS := 18.0

@export var camera_path: NodePath

var _camera: Camera3D
var _selected_units: Array[Node3D] = []
var _drag_start := Vector2.ZERO
var _drag_current := Vector2.ZERO
var _dragging := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_camera = get_node_or_null(camera_path) as Camera3D

func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				_drag_start = mouse_event.position
				_drag_current = mouse_event.position
				_dragging = true
				queue_redraw()
			elif _dragging:
				_finish_selection(mouse_event.position, mouse_event.shift_pressed)
		elif (
			mouse_event.pressed
			and mouse_event.button_index == MOUSE_BUTTON_RIGHT
		):
			var resource := _resource_at_screen(mouse_event.position)
			if resource != null:
				_issue_gather(resource)
				return
			var target: Variant = GroundPickerScript.pick_ground(
				_camera, mouse_event.position
			)
			if target != null:
				_issue_move(target as Vector3)
	elif event is InputEventMouseMotion and _dragging:
		_drag_current = (event as InputEventMouseMotion).position
		queue_redraw()

func _draw() -> void:
	if not _dragging or _drag_start.distance_to(_drag_current) < DRAG_THRESHOLD:
		return
	var box := Rect2(_drag_start, _drag_current - _drag_start).abs()
	draw_rect(box, Color(0.2, 0.8, 1.0, 0.14), true)
	draw_rect(box, Color(0.2, 0.8, 1.0, 0.9), false, 2.0)

func _finish_selection(screen_position: Vector2, additive: bool) -> void:
	_drag_current = screen_position
	_dragging = false
	if _drag_start.distance_to(_drag_current) < DRAG_THRESHOLD:
		_select_click(screen_position, additive)
	else:
		_select_box(Rect2(_drag_start, _drag_current - _drag_start).abs(), additive)
	queue_redraw()

func _select_click(screen_position: Vector2, additive: bool) -> void:
	var closest: Node3D
	var closest_distance := CLICK_RADIUS
	for unit in _player_units():
		if _camera.is_position_behind(unit.global_position):
			continue
		var distance := _camera.unproject_position(unit.global_position).distance_to(
			screen_position
		)
		if distance <= closest_distance:
			closest = unit
			closest_distance = distance

	if not additive:
		_clear_selection()
	if closest != null:
		_add_selection(closest)

func _select_box(box: Rect2, additive: bool) -> void:
	if not additive:
		_clear_selection()
	for unit in _player_units():
		if _camera.is_position_behind(unit.global_position):
			continue
		if box.has_point(_camera.unproject_position(unit.global_position)):
			_add_selection(unit)

func _issue_move(target: Vector3) -> void:
	var ground_target := Vector3(target.x, 0.0, target.z)
	for unit in _selected_units.duplicate():
		if not is_instance_valid(unit):
			_selected_units.erase(unit)
		elif unit.get("team") == Enums.Team.PLAYER:
			unit.call("command_move", ground_target)

func _issue_gather(resource: Node3D) -> void:
	for unit in _selected_units.duplicate():
		if not is_instance_valid(unit):
			_selected_units.erase(unit)
			continue
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == Enums.Team.PLAYER
			and unit_def != null
			and unit_def.id == &"villager"
		):
			unit.call("command_gather", resource)

func _resource_at_screen(screen_position: Vector2) -> Node3D:
	var closest: Node3D
	var closest_distance := CLICK_RADIUS
	for node in get_tree().get_nodes_in_group("resource_nodes"):
		var resource := node as Node3D
		if resource == null or not resource.visible:
			continue
		if _camera.is_position_behind(resource.global_position):
			continue
		var distance := _camera.unproject_position(resource.global_position).distance_to(
			screen_position
		)
		if distance <= closest_distance:
			closest = resource
			closest_distance = distance
	return closest

func _player_units() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Node3D
		if unit != null and unit.get("team") == Enums.Team.PLAYER:
			result.append(unit)
	return result

func _add_selection(unit: Node3D) -> void:
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.call("set_selected", true)

func _clear_selection() -> void:
	for unit in _selected_units:
		if is_instance_valid(unit):
			unit.call("set_selected", false)
	_selected_units.clear()
