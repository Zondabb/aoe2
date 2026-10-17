class_name SelectionController2D
extends Control

const PlayerCommands := preload("res://scripts/input/player_commands.gd")
const Formation := preload("res://scripts/input/unit_formation.gd")
const MoveOrderMarker := preload("res://scripts/presentation/move_order_marker.gd")

const FogAccess := preload("res://scripts/systems/fog_access.gd")

signal selection_changed(selected: Array)
signal control_groups_changed
signal formation_changed(kind: StringName)

const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const ResourceNodeScript := preload("res://scripts/entities/resource_node.gd")
const UnitDebugFocusScript := preload("res://scripts/debug/unit_debug_focus.gd")
const DRAG_THRESHOLD := 6.0
const CLICK_RADIUS := 28.0
const GROUP_DOUBLE_PRESS_MS := 350
## Group-move slot spacing (logical xz); keep > 2 * default unit radius.
const FORMATION_SPACING := 3.3

@export var camera_path: NodePath
## 观战模式：可选中查看，但不响应右键移动/采集/攻击。
@export var read_only := false
## 为 true 时可选中任意阵营单位/建筑及资源（ai_vs_ai 观战）。
@export var select_all_teams := false

var _camera: Camera2D
var _selected: Array[Node2D] = []
var _drag_start := Vector2.ZERO
var _drag_current := Vector2.ZERO
var _dragging := false
var _drag_serial := 0
var _move_marker: Node2D
var formation_mode: StringName = &"line"
var _control_groups: Dictionary = {}
var _badged_units: Dictionary = {}
var _last_group := -1
var _last_group_time := -1000

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_camera = get_node_or_null(camera_path) as Camera2D
	set_process(true)

func _process(_delta: float) -> void:
	var changed := false
	# Remove by index: comparing/erasing a freed Object reference is unreliable.
	for index in range(_selected.size() - 1, -1, -1):
		var entity = _selected[index]
		if not _is_live_entity(entity) or not FogAccess.view_can_see(entity):
			if is_instance_valid(entity):
				entity.call("set_selected", false)
			_selected.remove_at(index)
			changed = true
	if changed:
		_emit_selection_changed()
	_prune_control_groups()

func _input(event: InputEvent) -> void:
	# GUI can consume a release after a drag started on the map. Defer until
	# unhandled input has had its turn, then discard any unfinished gesture.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _dragging:
		call_deferred("_cancel_unfinished_drag", _drag_serial)

func _cancel_unfinished_drag(serial: int) -> void:
	if serial == _drag_serial:
		cancel_selection_drag()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel_selection_drag()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		_handle_group_key(event)
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				_drag_serial += 1
				_last_group = -1
				if mouse_event.double_click:
					cancel_selection_drag()
					_select_same_type(mouse_event.position, mouse_event.shift_pressed)
					get_viewport().set_input_as_handled()
					return
				_drag_start = mouse_event.position
				_drag_current = mouse_event.position
				_dragging = true
				queue_redraw()
			elif _dragging:
				_finish_selection(mouse_event.position, mouse_event.shift_pressed)
				get_viewport().set_input_as_handled()
		elif (
			mouse_event.pressed
			and mouse_event.button_index == MOUSE_BUTTON_RIGHT
		):
			cancel_selection_drag()
			if read_only:
				return
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
			_issue_move(_canvas_to_logical(mouse_event.position))
	elif event is InputEventMouseMotion and _dragging:
		_drag_current = (event as InputEventMouseMotion).position
		queue_redraw()

func _draw() -> void:
	if not _dragging or _drag_start.distance_to(_drag_current) < DRAG_THRESHOLD:
		return
	var box := Rect2(_drag_start, _drag_current - _drag_start).abs()
	draw_rect(box, Color(0, 0, 0, 0.65), false, 3.0)
	draw_rect(box, Color.WHITE, false, 1.0)

func _finish_selection(screen_position: Vector2, additive: bool) -> void:
	_drag_current = screen_position
	_dragging = false
	if _drag_start.distance_to(_drag_current) < DRAG_THRESHOLD:
		_select_click(screen_position, additive)
	else:
		_select_box(Rect2(_drag_start, _drag_current - _drag_start).abs(), additive)
	queue_redraw()

func _select_click(screen_position: Vector2, additive: bool) -> void:
	var closest := _entity_at_screen(screen_position)
	if not additive:
		_clear_selection(false)
	if closest != null:
		if additive and closest in _selected:
			_selected.erase(closest)
			closest.call("set_selected", false)
		else:
			_add_selection(closest, false)
	_emit_selection_changed()

func _entity_at_screen(screen_position: Vector2) -> Node2D:
	var canvas_pos := _viewport_to_canvas(screen_position)
	var closest: Node2D
	var closest_distance := INF
	for entity in _selectable_entities():
		if not _is_live_entity(entity):
			continue
		var distance := _pick_distance(entity, canvas_pos)
		if distance < closest_distance:
			closest = entity
			closest_distance = distance
	return closest

func _select_same_type(screen_position: Vector2, additive: bool) -> void:
	var hit := _entity_at_screen(screen_position)
	if hit == null or not hit.is_in_group("units") or _is_enemy_entity(hit):
		_select_click(screen_position, additive)
		return
	var definition := hit.get("def") as UnitDef
	if definition == null:
		return
	if not additive:
		_clear_selection(false)
	var viewport_box: Rect2 = get_meta("world_screen_rect", get_viewport().get_visible_rect())
	for unit in _selectable_units():
		if not _is_live_entity(unit) or unit.get("team") != hit.get("team"):
			continue
		var candidate := unit.get("def") as UnitDef
		if candidate != null and candidate.id == definition.id and _entity_intersects_screen_box(unit, viewport_box):
			_add_selection(unit, false)
	_emit_selection_changed()

func _select_box(box: Rect2, additive: bool) -> void:
	if not additive:
		_clear_selection(false)
	for unit in _selectable_units():
		if _entity_intersects_screen_box(unit, box):
			_add_selection(unit, false)
	_emit_selection_changed()

## UI commands share formation spacing, ownership checks and the world marker.
func issue_minimap_move(target: Vector2) -> void:
	_issue_move(target)

func cancel_selection_drag() -> void:
	_dragging = false
	queue_redraw()

func _issue_move(target: Vector2, show_marker := true) -> void:
	if read_only or FogAccess.local_read_only(self):
		return
	var movers: Array[Node2D] = []
	for unit in _selected.duplicate():
		if not _is_live_entity(unit):
			continue
		if unit.get("team") == PlayerCommands.local_team(self) and unit.has_method("command_move"):
			movers.append(unit)
	if movers.is_empty():
		return
	var destinations := Formation.destinations(movers, target, formation_mode)
	var group_speed := INF
	for unit in movers:
		var definition := unit.get("def") as UnitDef
		if definition != null: group_speed = minf(group_speed, definition.move_speed)
	if not is_finite(group_speed) or movers.size() <= 1: group_speed = 0.0
	for index in movers.size():
		movers[index].set_meta("manual_formation", formation_mode)
		PlayerCommands.unit_order(self, movers[index], "move", destinations[index], group_speed)
	if show_marker:
		_show_move_marker(target)

func set_formation(kind: StringName) -> void:
	if read_only or FogAccess.local_read_only(self):
		return
	formation_mode = Formation.normalize_kind(kind)
	var movers: Array[Node2D] = []
	var destination := Vector2.ZERO
	var all_moving := true
	for unit in get_selected_units():
		if unit.get("team") != PlayerCommands.local_team(self): continue
		unit.set_meta("manual_formation", formation_mode)
		movers.append(unit)
		if unit.get("order") == Enums.OrderType.MOVE:
			destination += unit.get("_move_target")
		else:
			all_moving = false
	if movers.size() > 1:
		_issue_move(destination / movers.size() if all_moving else Formation.center(movers), false)
	formation_changed.emit(formation_mode)


## Square packing around the click point so group moves don't share one cell.
static func formation_offset(index: int, count: int, spacing: float = FORMATION_SPACING) -> Vector2:
	if count <= 1:
		return Vector2.ZERO
	var cols := maxi(1, int(ceil(sqrt(float(count)))))
	var rows := maxi(1, int(ceil(float(count) / float(cols))))
	var row := int(index / cols)
	var col := index % cols
	var ox := (float(col) - float(cols - 1) * 0.5) * spacing
	var oy := (float(row) - float(rows - 1) * 0.5) * spacing
	return Vector2(ox, oy)

func _show_move_marker(logical_target: Vector2) -> void:
	_ensure_move_marker()
	if _move_marker == null:
		return
	_move_marker.call("play_at", logical_target)

func _ensure_move_marker() -> void:
	if _move_marker != null and is_instance_valid(_move_marker):
		return
	var match_root := _match_root()
	if match_root == null:
		return
	var legacy := match_root.get_node_or_null("MoveMarker")
	if legacy != null:
		match_root.remove_child(legacy)
		legacy.queue_free()
	_move_marker = MoveOrderMarker.new()
	_move_marker.name = "MoveMarker"
	match_root.add_child(_move_marker)

func _match_root() -> Node:
	var node: Node = self
	while node != null:
		if node.name == "Match" or node.name == "AiVsAi":
			return node
		node = node.get_parent()
	return get_parent()

func _issue_gather(resource: Node2D) -> void:
	if read_only or FogAccess.local_read_only(self):
		return
	for unit in _selected.duplicate():
		if not is_instance_valid(unit):
			_selected.erase(unit)
			continue
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == PlayerCommands.local_team(self)
			and unit_def != null
			and unit_def.id == &"villager"
			and unit.has_method("command_gather")
		):
			PlayerCommands.unit_order(self, unit, "gather", resource)

func _issue_build(building: Node2D) -> void:
	if read_only or FogAccess.local_read_only(self):
		return
	for unit in _selected.duplicate():
		if not is_instance_valid(unit):
			_selected.erase(unit)
			continue
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == PlayerCommands.local_team(self)
			and unit_def != null
			and unit_def.id == &"villager"
			and unit.has_method("command_build")
		):
			PlayerCommands.unit_order(self, unit, "build", building)

func _issue_attack(target: Node2D) -> void:
	if read_only or FogAccess.local_read_only(self):
		return
	for unit in _selected.duplicate():
		if not is_instance_valid(unit):
			_selected.erase(unit)
			continue
		if (
			unit.get("team") == PlayerCommands.local_team(self)
			and target.get("team") != PlayerCommands.local_team(self)
			and unit.has_method("command_attack")
		):
			PlayerCommands.unit_order(self, unit, "attack", target)

func _enemy_at_screen(screen_position: Vector2) -> Node2D:
	var canvas_pos := _viewport_to_canvas(screen_position)
	var closest: Node2D
	var closest_distance := INF
	var candidates: Array[Node] = []
	candidates.assign(get_tree().get_nodes_in_group("units"))
	candidates.append_array(get_tree().get_nodes_in_group("buildings"))
	for node in candidates:
		var enemy := node as Node2D
		if (
			enemy == null
			or enemy.get("team") == PlayerCommands.local_team(self)
			or enemy.get("is_placement_ghost") == true
			or enemy.is_queued_for_deletion()
		):
			continue
		var distance := _pick_distance(enemy, canvas_pos)
		if distance < closest_distance:
			closest = enemy
			closest_distance = distance
	return closest

func _resource_at_screen(screen_position: Vector2) -> Node2D:
	var canvas_pos := _viewport_to_canvas(screen_position)
	var closest: Node2D
	var closest_distance := INF
	for node in get_tree().get_nodes_in_group("resource_nodes"):
		var resource := node as Node2D
		if resource == null or not resource.visible or float(resource.get("amount")) <= 0 or not FogAccess.view_can_see(resource):
			continue
		var distance := _resource_pick_distance(resource, canvas_pos)
		if distance < closest_distance:
			closest = resource
			closest_distance = distance
	return closest

func _unfinished_building_at_screen(screen_position: Vector2) -> Node2D:
	var canvas_pos := _viewport_to_canvas(screen_position)
	var closest: Node2D
	var closest_distance := INF
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node2D
		if (
			building == null
			or building.get("team") != PlayerCommands.local_team(self)
			or bool(building.get("is_complete"))
		):
			continue
		var distance := _pick_distance(building, canvas_pos)
		if distance < closest_distance:
			closest = building
			closest_distance = distance
	return closest

func _player_units() -> Array[Node2D]:
	var result: Array[Node2D] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Node2D
		if unit != null and unit.get("team") == PlayerCommands.local_team(self):
			result.append(unit)
	return result


func _all_units() -> Array[Node2D]:
	var result: Array[Node2D] = []
	for node in get_tree().get_nodes_in_group("units"):
		var unit := node as Node2D
		if unit != null:
			result.append(unit)
	return result


func _selectable_units() -> Array[Node2D]:
	if select_all_teams:
		return _all_units()
	return _player_units()


func _player_selectables() -> Array[Node2D]:
	var result := _player_units()
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node2D
		if building != null and building.get("team") == PlayerCommands.local_team(self):
			result.append(building)
	for node in get_tree().get_nodes_in_group("resource_nodes"):
		var resource := node as Node2D
		if resource != null and resource.visible and resource.has_method("set_selected"):
			result.append(resource)
	return result


func _all_selectables() -> Array[Node2D]:
	var result := _all_units()
	for node in get_tree().get_nodes_in_group("buildings"):
		var building := node as Node2D
		if building != null:
			result.append(building)
	for node in get_tree().get_nodes_in_group("resource_nodes"):
		var resource := node as Node2D
		if resource != null and resource.visible and resource.has_method("set_selected"):
			result.append(resource)
	return result


func _selectable_entities() -> Array[Node2D]:
	# Left clicks may inspect visible opponents; box selection stays own-team.
	return _all_selectables()

func get_selected_units() -> Array[Node2D]:
	var result: Array[Node2D] = []
	for entity in _selected:
		if is_instance_valid(entity) and entity.is_in_group("units"):
			result.append(entity)
	return result

func get_selected_building() -> Node2D:
	for entity in _selected:
		if is_instance_valid(entity) and entity.is_in_group("buildings"):
			return entity
	return null


func get_primary_selection() -> Node2D:
	for entity in _selected:
		if is_instance_valid(entity):
			return entity
	return null

func _is_live_entity(entity: Variant) -> bool:
	if not is_instance_valid(entity) or entity.is_queued_for_deletion():
		return false
	if entity.get("is_placement_ghost") == true or not entity.visible:
		return false
	if entity.is_inside_tree() and not entity.is_visible_in_tree():
		return false
	var health: Variant = entity.get("hp")
	# SceneTree._initialize fixtures may select before _ready sets initial HP.
	return not entity.is_inside_tree() or health == null or float(health) > 0.0

func _can_group(entity: Variant) -> bool:
	return _is_live_entity(entity) and entity.is_inside_tree() and entity.get("team") == PlayerCommands.local_team(self) and (entity.is_in_group("units") or entity.is_in_group("buildings"))

func get_control_group(index: int) -> Array[Node2D]:
	var members: Array[Node2D] = []
	for reference: WeakRef in _control_groups.get(index, []):
		var entity := reference.get_ref() as Node2D
		if _can_group(entity):
			members.append(entity)
	return members

func selected_control_groups() -> Array[int]:
	var result: Array[int] = []
	for index in 10:
		var members := get_control_group(index)
		if not members.is_empty() and members.size() == _selected.size():
			var matches := true
			for entity in members:
				if entity not in _selected: matches = false
			if matches: result.append(index)
	return result

func assign_control_group(index: int, append := false) -> void:
	if index < 0 or index > 9 or read_only or FogAccess.local_read_only(self):
		return
	var members: Array[Node2D] = []
	if append: members = get_control_group(index)
	var valid_selection: Array[Node2D] = []
	for entity in _selected:
		if _can_group(entity): valid_selection.append(entity)
	if valid_selection.is_empty():
		return
	# A saved building group and a unit group have different command panels.
	if append and not members.is_empty() and members[0].is_in_group("units") != valid_selection[0].is_in_group("units"):
		members.clear()
	for entity in valid_selection:
		if entity not in members: members.append(entity)
	var references: Array[WeakRef] = []
	for entity in members: references.append(weakref(entity))
	_control_groups[index] = references
	_sync_group_badges()
	control_groups_changed.emit()

func recall_control_group(index: int, additive := false, focus := false) -> void:
	var members := get_control_group(index)
	if members.is_empty(): return
	cancel_selection_drag()
	if not additive: _clear_selection(false)
	for entity in members: _add_selection(entity, false)
	_emit_selection_changed()
	if focus: _focus_group(members)

func _focus_group(members: Array[Node2D]) -> void:
	if members.is_empty() or not is_instance_valid(_camera): return
	var logical := Formation.center(members)
	if _camera.has_method("focus_on"):
		_camera.call("focus_on", logical)
	else:
		_camera.global_position = IsoMathScript.world_to_screen(logical)
	_camera.reset_smoothing()
	_camera.force_update_scroll()

func _handle_group_key(event: InputEventKey) -> void:
	if not event.pressed or event.echo or event.meta_pressed: return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit: return
	var key := event.physical_keycode if event.physical_keycode != 0 else event.keycode
	var index := -1
	if key >= KEY_0 and key <= KEY_9: index = key - KEY_0
	elif key >= KEY_KP_0 and key <= KEY_KP_9: index = key - KEY_KP_0
	if index < 0:
		_last_group = -1
		return
	if event.ctrl_pressed:
		assign_control_group(index, event.shift_pressed)
		_last_group = -1
	elif event.shift_pressed:
		assign_control_group(index, true)
		_last_group = -1
	elif event.alt_pressed:
		_focus_group(get_control_group(index))
		_last_group = -1
	else:
		var now := Time.get_ticks_msec()
		var double_press := index == _last_group and now - _last_group_time <= GROUP_DOUBLE_PRESS_MS
		recall_control_group(index, false, double_press)
		_last_group = -1 if double_press else index
		_last_group_time = now
	get_viewport().set_input_as_handled()

func _prune_control_groups() -> void:
	var changed := false
	for index in _control_groups.keys():
		var members := get_control_group(index)
		if members.size() == _control_groups[index].size(): continue
		changed = true
		if members.is_empty():
			_control_groups.erase(index)
		else:
			var references: Array[WeakRef] = []
			for entity in members: references.append(weakref(entity))
			_control_groups[index] = references
	if changed:
		_sync_group_badges()
		control_groups_changed.emit()

func _sync_group_badges() -> void:
	for reference: WeakRef in _badged_units.values():
		var entity: Variant = reference.get_ref()
		if is_instance_valid(entity) and entity.has_method("set_control_group_ids"):
			var empty: Array[int] = []
			entity.call("set_control_group_ids", empty)
	_badged_units.clear()
	var memberships: Dictionary = {}
	for index in 10:
		for entity in get_control_group(index):
			var id := entity.get_instance_id()
			if not memberships.has(id):
				var numbers: Array[int] = []
				memberships[id] = numbers
				_badged_units[id] = weakref(entity)
			memberships[id].append(index)
	for id in memberships:
		var entity: Node = _badged_units[id].get_ref()
		if entity.has_method("set_control_group_ids"):
			entity.call("set_control_group_ids", memberships[id])

func _exit_tree() -> void:
	_control_groups.clear()
	_sync_group_badges()

func _add_selection(unit: Node2D, notify := true) -> void:
	if not _is_live_entity(unit) or not FogAccess.view_can_see(unit):
		return
	if unit in _selected:
		return
	if not select_all_teams:
		# An opponent is an inspection target, never part of a command group.
		# Shift-clicking either side replaces an inspection with that side.
		if _is_enemy_entity(unit):
			_clear_selection(false)
		else:
			for selected in _selected:
				if is_instance_valid(selected) and _is_enemy_entity(selected):
					_clear_selection(false)
					break
		# Resources are inspected alone; units and buildings have separate orders.
		for selected in _selected:
			if not is_instance_valid(selected): continue
			if unit.is_in_group("units") != selected.is_in_group("units") or unit.is_in_group("buildings") != selected.is_in_group("buildings") or unit.is_in_group("resource_nodes") and not unit.is_in_group("buildings"):
				_clear_selection(false)
				break
	_selected.append(unit)
	unit.call("set_selected", true)
	if notify:
		_emit_selection_changed()

func _is_enemy_entity(entity: Node2D) -> bool:
	return (
		(entity.is_in_group("units") or entity.is_in_group("buildings"))
		and entity.get("team") != PlayerCommands.local_team(self)
	)

func _clear_selection(notify := true) -> void:
	for unit in _selected:
		if is_instance_valid(unit):
			unit.call("set_selected", false)
	_selected.clear()
	if notify:
		_emit_selection_changed()

func _emit_selection_changed() -> void:
	# Other input paths may emit between a unit's deletion and the next frame.
	for index in range(_selected.size() - 1, -1, -1):
		if not _is_live_entity(_selected[index]):
			_selected.remove_at(index)
	var snapshot: Array = []
	snapshot.assign(_selected)
	UnitDebugFocusScript.set_focus_from_selection(snapshot)
	_sync_nav_debug_focus(snapshot)
	for entity in _selected:
		if entity.is_in_group("units") and entity.get("team") == PlayerCommands.local_team(self):
			formation_mode = Formation.normalize_kind(entity.get_meta("manual_formation", &"line"))
			break
	selection_changed.emit(snapshot)


func _sync_nav_debug_focus(selected: Array) -> void:
	if not is_inside_tree():
		return
	var focus_units: Array[Node2D] = []
	for entity in selected:
		if is_instance_valid(entity) and entity is Node2D and not entity.is_queued_for_deletion() and entity.is_in_group("units"):
			focus_units.append(entity)
	for node in get_tree().get_nodes_in_group("nav_debug_overlay"):
		if node.has_method("set_focus_units"):
			node.call("set_focus_units", focus_units)

func _viewport_to_canvas(screen_position: Vector2) -> Vector2:
	return get_viewport().get_canvas_transform().affine_inverse() * screen_position

func _canvas_to_logical(screen_position: Vector2) -> Vector2:
	return IsoMathScript.screen_to_world(_viewport_to_canvas(screen_position))

## Distance for ranking hits. INF = miss.
## Units/buildings use the full sprite body rect (origin is feet via hotspot).
func _pick_distance(entity: Node2D, canvas_pos: Vector2) -> float:
	if not FogAccess.view_can_see(entity):
		return INF
	if entity.is_in_group("resource_nodes"):
		return _resource_pick_distance(entity, canvas_pos)
	if _uses_visual_pick(entity):
		var rect := _visual_rect_canvas(entity)
		if rect.size.x > 0.0 and rect.size.y > 0.0:
			if rect.has_point(canvas_pos):
				return canvas_pos.distance_to(rect.get_center())
			return INF
	var distance := entity.global_position.distance_to(canvas_pos)
	if distance <= CLICK_RADIUS:
		return distance
	return INF

func _resource_pick_distance(resource: Node2D, canvas_pos: Vector2) -> float:
	# A tree's origin is its trunk base; ore artwork also extends beyond the
	# ground footprint. Use visible sprite pixels for both left and right click.
	var sprite := _entity_visual_sprite(resource)
	if sprite is Sprite2D and sprite.is_pixel_opaque(sprite.to_local(canvas_pos)):
		return canvas_pos.distance_to(_visual_rect_canvas(resource).get_center())
	# Ground-footprint selection remains available for marker-only resources.
	return _footprint_pick_distance(resource, canvas_pos)

func _entity_intersects_screen_box(entity: Node2D, screen_box: Rect2) -> bool:
	if not FogAccess.view_can_see(entity):
		return false
	if _uses_visual_pick(entity):
		var canvas_rect := _visual_rect_canvas(entity)
		if canvas_rect.size.x > 0.0 and canvas_rect.size.y > 0.0:
			var screen_rect := _transform_rect(
				get_viewport().get_canvas_transform(), canvas_rect
			)
			return screen_box.intersects(screen_rect)
	var screen_pos := get_viewport().get_canvas_transform() * entity.global_position
	return screen_box.has_point(screen_pos)

func _footprint_pick_distance(entity: Node2D, canvas_pos: Vector2) -> float:
	var half := _entity_footprint_half(entity)
	if half.length_squared() <= 0.0:
		var distance := entity.global_position.distance_to(canvas_pos)
		return distance if distance <= CLICK_RADIUS else INF
	var local := entity.global_transform.affine_inverse() * canvas_pos
	var poly := IsoMathScript.footprint_polygon_screen(half)
	if Geometry2D.is_point_in_polygon(local, poly):
		return local.length()
	return INF


func _entity_footprint_half(entity: Node2D) -> Vector2:
	if entity.is_in_group("buildings"):
		var building_def := entity.get("def") as BuildingDef
		if building_def != null:
			return building_def.footprint * 0.5
	if entity.is_in_group("resource_nodes"):
		return ResourceNodeScript.selection_footprint(
			entity.get("resource_type") as Enums.ResourceType
		) * 0.5
	return Vector2.ZERO


func _uses_visual_pick(entity: Node2D) -> bool:
	return (
		entity != null
		and (entity.is_in_group("units") or entity.is_in_group("buildings"))
	)

func _visual_rect_canvas(entity: Node2D) -> Rect2:
	var sprite := _entity_visual_sprite(entity)
	if sprite == null:
		return Rect2()
	var local_rect := _sprite_local_rect(sprite)
	if local_rect.size.x <= 0.0 or local_rect.size.y <= 0.0:
		return Rect2()
	return _transform_rect(sprite.global_transform, local_rect)

func _sprite_local_rect(sprite: Node2D) -> Rect2:
	if sprite is Sprite2D:
		return (sprite as Sprite2D).get_rect()
	if sprite is AnimatedSprite2D:
		var animated := sprite as AnimatedSprite2D
		var frames := animated.sprite_frames
		if frames == null:
			return Rect2()
		var anim := animated.animation
		if anim == &"" or not frames.has_animation(anim):
			var names := frames.get_animation_names()
			if names.is_empty():
				return Rect2()
			anim = names[0]
		var frame_count := frames.get_frame_count(anim)
		if frame_count <= 0:
			return Rect2()
		var frame_idx := clampi(animated.frame, 0, frame_count - 1)
		var texture := frames.get_frame_texture(anim, frame_idx)
		if texture == null:
			return Rect2()
		var size := texture.get_size()
		# Matches configure_sprite_2d: centered=true + offset.
		return Rect2(animated.offset - size * 0.5, size)
	return Rect2()

func _entity_visual_sprite(entity: Node2D) -> Node2D:
	var billboard := entity.get_node_or_null("Billboard") as Node2D
	if billboard != null and billboard.visible:
		return billboard
	var body := entity.get_node_or_null("Body") as Node2D
	if body != null and body.visible:
		return body
	return billboard if billboard != null else body

func _transform_rect(xf: Transform2D, rect: Rect2) -> Rect2:
	var p0 := xf * rect.position
	var p1 := xf * (rect.position + Vector2(rect.size.x, 0.0))
	var p2 := xf * (rect.position + Vector2(0.0, rect.size.y))
	var p3 := xf * (rect.position + rect.size)
	var min_v := p0.min(p1).min(p2).min(p3)
	var max_v := p0.max(p1).max(p2).max(p3)
	return Rect2(min_v, max_v - min_v)
