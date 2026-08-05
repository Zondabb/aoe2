extends Node2D
class_name SelectionController

## RTS box-select (LMB) and move command (RMB), AoE2-style.

@export var unit_parent_path: NodePath = ^"Units"

var _units: Array[Elephant] = []
var _selected: Array[Elephant] = []

var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_current: Vector2 = Vector2.ZERO
var _click_threshold: float = 6.0
var _box: Node2D
var _move_marker: Node2D
var _marker_time: float = 0.0

func _ready() -> void:
	_box = Node2D.new()
	_box.set_script(load("res://scripts/selection_box.gd"))
	_box.z_index = 1000
	add_child(_box)
	_move_marker = Node2D.new()
	_move_marker.z_index = 999
	_move_marker.visible = false
	_move_marker.draw.connect(_draw_move_marker)
	add_child(_move_marker)
	call_deferred("_collect_units")

func _process(delta: float) -> void:
	if _marker_time > 0.0:
		_marker_time -= delta
		_move_marker.queue_redraw()
		if _marker_time <= 0.0:
			_move_marker.visible = false

func _collect_units() -> void:
	_units.clear()
	var parent := get_node_or_null(unit_parent_path)
	if parent == null:
		parent = get_parent()
	for child in parent.get_children():
		if child is Elephant:
			_units.append(child)

func register_unit(unit: Elephant) -> void:
	if unit not in _units:
		_units.append(unit)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var world := get_global_mouse_position()
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_start = world
				_drag_current = world
				_sync_box()
			else:
				if _dragging:
					_finish_selection()
				_dragging = false
				_sync_box()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_issue_move_command(world)
			get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _dragging:
		_drag_current = get_global_mouse_position()
		_sync_box()

func _sync_box() -> void:
	_box.dragging = _dragging
	_box.start = _drag_start
	_box.current = _drag_current
	_box.click_threshold = _click_threshold
	_box.queue_redraw()

func _finish_selection() -> void:
	var add_mode := Input.is_key_pressed(KEY_SHIFT)
	var drag_len := _drag_start.distance_to(_drag_current)

	if drag_len < _click_threshold:
		var clicked: Elephant = null
		var best := INF
		for unit in _units:
			if unit.contains_world_point(_drag_current):
				var d := unit.global_position.distance_to(_drag_current)
				if d < best:
					best = d
					clicked = unit
		if not add_mode:
			_clear_selection()
		if clicked:
			_select_unit(clicked, true)
	else:
		var rect := Rect2(_drag_start, _drag_current - _drag_start).abs()
		if not add_mode:
			_clear_selection()
		for unit in _units:
			if rect.has_point(unit.get_selection_point()):
				_select_unit(unit, true)

func _issue_move_command(world_pos: Vector2) -> void:
	if _selected.is_empty():
		return
	var i := 0
	for unit in _selected:
		var offset := Vector2.ZERO
		if _selected.size() > 1:
			var angle := TAU * float(i) / float(_selected.size())
			offset = Vector2(cos(angle), sin(angle)) * 36.0
		unit.command_move_to(world_pos + offset)
		i += 1
	_move_marker.global_position = world_pos
	_move_marker.visible = true
	_marker_time = 0.85
	_move_marker.queue_redraw()

func _draw_move_marker() -> void:
	if _marker_time <= 0.0:
		return
	var alpha := clampf(_marker_time / 0.85, 0.0, 1.0)
	var radius := 10.0 + (1.0 - alpha) * 8.0
	_move_marker.draw_arc(Vector2.ZERO, radius, 0.0, TAU, 32, Color(0.2, 1.0, 0.35, alpha), 2.0, true)
	_move_marker.draw_circle(Vector2.ZERO, 3.0, Color(0.2, 1.0, 0.35, alpha))

func _clear_selection() -> void:
	for unit in _selected:
		unit.selected = false
	_selected.clear()

func _select_unit(unit: Elephant, value: bool) -> void:
	unit.selected = value
	if value:
		if unit not in _selected:
			_selected.append(unit)
	else:
		_selected.erase(unit)
