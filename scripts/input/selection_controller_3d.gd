class_name SelectionController3D
extends Control

signal selection_changed(selected: Array[Node3D])

const GroundPickerScript := preload("res://scripts/input/ground_picker.gd")
const DRAG_THRESHOLD := 6.0
const CLICK_RADIUS := 18.0
const MOVE_MARKER_DURATION := 1.35

@export var camera_path: NodePath

var _camera: Camera3D
var _selected_units: Array[Node3D] = []
var _drag_start := Vector2.ZERO
var _drag_current := Vector2.ZERO
var _dragging := false
var _move_marker: MeshInstance3D
var _move_marker_ttl := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_camera = get_node_or_null(camera_path) as Camera3D
	set_process(true)

func _process(delta: float) -> void:
	if _move_marker_ttl <= 0.0:
		return
	_move_marker_ttl = maxf(0.0, _move_marker_ttl - delta)
	if _move_marker != null and is_instance_valid(_move_marker):
		var fade := clampf(_move_marker_ttl / MOVE_MARKER_DURATION, 0.0, 1.0)
		var material := _move_marker.get_active_material(0) as StandardMaterial3D
		if material != null:
			material.albedo_color.a = 0.85 * fade
		if _move_marker_ttl <= 0.0:
			_move_marker.visible = false

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
			var enemy := _enemy_at_screen(mouse_event.position)
			if enemy != null:
				_issue_attack(enemy)
				return
			var building := _unfinished_building_at_screen(mouse_event.position)
			if building != null:
				_issue_build(building)
				return
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
	for entity in _player_selectables():
		if _camera.is_position_behind(entity.global_position):
			continue
		var distance := _camera.unproject_position(entity.global_position).distance_to(
			screen_position
		)
		if distance <= closest_distance:
			closest = entity
			closest_distance = distance

	if not additive:
		_clear_selection(false)
	if closest != null:
		_add_selection(closest, false)
	_emit_selection_changed()

func _select_box(box: Rect2, additive: bool) -> void:
	if not additive:
		_clear_selection(false)
	for unit in _player_units():
		if _camera.is_position_behind(unit.global_position):
			continue
		if box.has_point(_camera.unproject_position(unit.global_position)):
			_add_selection(unit, false)
	_emit_selection_changed()

func _issue_move(target: Vector3) -> void:
	var ground_target := Vector3(target.x, 0.0, target.z)
	var issued := false
	for unit in _selected_units.duplicate():
		if not is_instance_valid(unit):
			_selected_units.erase(unit)
		elif unit.get("team") == Enums.Team.PLAYER and unit.has_method("command_move"):
			unit.call("command_move", ground_target)
			issued = true
	if issued:
		_show_move_marker(ground_target)

func _show_move_marker(ground_target: Vector3) -> void:
	_ensure_move_marker()
	if _move_marker == null:
		return
	_move_marker.position = Vector3(ground_target.x, 0.04, ground_target.z)
	_move_marker.visible = true
	_move_marker_ttl = MOVE_MARKER_DURATION
	var mesh := _move_marker.mesh
	if mesh != null:
		var material := mesh.surface_get_material(0) as StandardMaterial3D
		if material != null:
			var unique_material := material.duplicate() as StandardMaterial3D
			unique_material.albedo_color = Color(0.95, 0.9, 0.2, 0.85)
			mesh.surface_set_material(0, unique_material)

func _ensure_move_marker() -> void:
	if _move_marker != null and is_instance_valid(_move_marker):
		return
	var match_root := get_parent()
	if match_root == null:
		return
	_move_marker = match_root.get_node_or_null("MoveMarker") as MeshInstance3D

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
			and unit.has_method("command_gather")
		):
			unit.call("command_gather", resource)

func _issue_build(building: Node3D) -> void:
	for unit in _selected_units.duplicate():
		if not is_instance_valid(unit):
			_selected_units.erase(unit)
			continue
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == Enums.Team.PLAYER
			and unit_def != null
			and unit_def.id == &"villager"
			and unit.has_method("command_build")
		):
			unit.call("command_build", building)

func _issue_attack(target: Node3D) -> void:
	for unit in _selected_units.duplicate():
		if not is_instance_valid(unit):
			_selected_units.erase(unit)
			continue
		if (
			unit.get("team") == Enums.Team.PLAYER
			and target.get("team") != Enums.Team.PLAYER
			and unit.has_method("command_attack")
		):
			unit.call("command_attack", target)

func _enemy_at_screen(screen_position: Vector2) -> Node3D:
	var closest: Node3D
	var closest_distance := CLICK_RADIUS
	var candidates: Array[Node] = []
	candidates.assign(get_tree().get_nodes_in_group("units"))
	candidates.append_array(get_tree().get_nodes_in_group("buildings"))
	for node in candidates:
		var enemy := node as Node3D
		if (
			enemy == null
			or enemy.get("team") == Enums.Team.PLAYER
			or enemy.is_queued_for_deletion()
			or _camera.is_position_behind(enemy.global_position)
		):
			continue
		var distance := _camera.unproject_position(enemy.global_position).distance_to(
			screen_position
		)
		if distance <= closest_distance:
			closest = enemy
			closest_distance = distance
	return closest

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

func _unfinished_building_at_screen(screen_position: Vector2) -> Node3D:
	var closest: Node3D
	var closest_distance := CLICK_RADIUS
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if (
			building == null
			or building.get("team") != Enums.Team.PLAYER
			or bool(building.get("is_complete"))
			or _camera.is_position_behind(building.global_position)
		):
			continue
		var distance := _camera.unproject_position(
			building.global_position
		).distance_to(screen_position)
		if distance <= closest_distance:
			closest = building
			closest_distance = distance
	return closest

func _player_units() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Node3D
		if unit != null and unit.get("team") == Enums.Team.PLAYER:
			result.append(unit)
	return result

func _player_selectables() -> Array[Node3D]:
	var result := _player_units()
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node3D
		if building != null and building.get("team") == Enums.Team.PLAYER:
			result.append(building)
	return result

func get_selected_units() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for entity in _selected_units:
		if is_instance_valid(entity) and entity.is_in_group("units"):
			result.append(entity)
	return result

func get_selected_building() -> Node3D:
	for entity in _selected_units:
		if is_instance_valid(entity) and entity.is_in_group("buildings"):
			return entity
	return null

func _add_selection(unit: Node3D, notify := true) -> void:
	if unit in _selected_units:
		return
	_selected_units.append(unit)
	unit.call("set_selected", true)
	if notify:
		_emit_selection_changed()

func _clear_selection(notify := true) -> void:
	for unit in _selected_units:
		if is_instance_valid(unit):
			unit.call("set_selected", false)
	_selected_units.clear()
	if notify:
		_emit_selection_changed()

func _emit_selection_changed() -> void:
	var selection_snapshot: Array[Node3D] = []
	selection_snapshot.assign(_selected_units)
	selection_changed.emit(selection_snapshot)
