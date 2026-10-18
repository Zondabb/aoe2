class_name BuildSystem
extends Node

const Catalog := preload("res://scripts/data/game_catalog.gd")

const PlayerCommands := preload("res://scripts/input/player_commands.gd")

const FogAccess := preload("res://scripts/systems/fog_access.gd")

signal placement_changed(active: bool)

const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const ShoreGeometry := preload("res://scripts/world/shore_geometry.gd")
const Walls := preload("res://scripts/systems/wall_system.gd")
const ExecutionContext := preload("res://scripts/ai_gateway/command_execution_context.gd")

var match_state: MatchState
var civ: CivDef
var _camera: Camera2D
var _entities: Node2D
var _selection: Control
var _ghost: Node2D
var _placement_valid := false
var placement_reason := ""
var _wall_ghosts: Array[Node2D] = []
var _wall_plan: Array = []
var _wall_anchor := Vector2.ZERO
var _wall_has_anchor := false
var _wall_dragging := false
var _wall_continuing := false
var _wall_include_gate := false
var _drag_serial := 0
var _gate_orientation := 0
var _selection_input_was_enabled := true
var _selection_input_suspended := false
var _placement_def: BuildingDef

static func can_place(
	footprint: Vector2, center: Vector2, existing_buildings: Array
) -> bool:
	var candidate_half := footprint * 0.5
	for value in existing_buildings:
		var building := value as Node2D
		if building == null or building.is_queued_for_deletion() or building.get("is_placement_ghost") == true:
			continue
		if building.has_method("get_water_contours") and not building.get_water_contours().is_empty():
			if ShoreGeometry.intersects_rect(Rect2(center - candidate_half, footprint), building.get_water_contours()): return false
			continue
		var building_def := building.get("def") as BuildingDef
		var existing_footprint: Vector2 = (
			building_def.footprint if building_def != null else (building.get("block_size") if building.get("block_size") is Vector2 else Vector2.ONE)
		)
		if building.has_method("get_placement_footprint"):
			existing_footprint = building.call("get_placement_footprint")
		var existing_half := existing_footprint * 0.5
		var building_pos: Vector2 = building.get("sim_pos")
		var offset := Vector2(
			absf(center.x - building_pos.x),
			absf(center.y - building_pos.y)
		)
		if (
			offset.x < candidate_half.x + existing_half.x
			and offset.y < candidate_half.y + existing_half.y
		):
			return false
	return true

func setup(
	camera: Camera2D,
	entities: Node2D,
	selection: Control,
	state: MatchState,
	player_civ: CivDef
) -> void:
	_camera = camera
	_entities = entities
	_selection = selection
	match_state = state
	civ = player_civ

func _process(_delta: float) -> void:
	if _ghost != null and not is_instance_valid(_ghost):
		cancel_placement()
		return
	if _ghost == null:
		return
	_update_ghost_position(get_viewport().get_mouse_position())

func _update_ghost_position(screen_position: Vector2) -> void:
	var logical := _viewport_to_logical(screen_position)
	if _is_wall_placement():
		_update_wall_preview(logical)
		return
	if _is_gate(_ghost.get("def")):
		logical = logical.round()
	_ghost.set("sim_pos", logical)
	IsoMathScript.sync_node(_ghost, logical)
	_update_placement_validity()

func _input(event: InputEvent) -> void:
	if not is_placing(): return
	# Release over HUD is consumed before _unhandled_input. Clear only that
	# unfinished gesture, without placing a wall behind the clicked UI.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _wall_dragging:
		call_deferred("_cancel_unfinished_wall_drag", _drag_serial)
	if event is InputEventKey and event.pressed and not event.echo and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit: return
		var key: Key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_ESCAPE:
			cancel_placement()
		elif key == KEY_R and _is_gate(_placement_def):
			rotate_gate()
		elif key == KEY_G and _is_wall_placement():
			_wall_include_gate = not _wall_include_gate
			_update_ghost_position(get_viewport().get_mouse_position())
		else:
			return
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_unfinished_wall_drag(_drag_serial)

func _cancel_unfinished_wall_drag(serial: int) -> void:
	if serial != _drag_serial or not _wall_dragging: return
	_wall_dragging = false
	_wall_has_anchor = _wall_continuing

func _unhandled_input(event: InputEvent) -> void:
	if _ghost == null:
		return
	if event is InputEventMouseMotion and _is_wall_placement():
		_update_ghost_position(event.position)
		get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouseButton: return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
		cancel_placement()
		get_viewport().set_input_as_handled()
	elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
		if not _in_play_area(mouse_event.position):
			_cancel_unfinished_wall_drag(_drag_serial)
			return
		if _is_wall_placement():
			if mouse_event.pressed:
				_drag_serial += 1
				if not _wall_has_anchor:
					_wall_anchor = _snap_wall_point(_viewport_to_logical(mouse_event.position))
					_wall_has_anchor = true
				_wall_dragging = true
				_update_ghost_position(mouse_event.position)
			elif _wall_dragging:
				_update_ghost_position(mouse_event.position)
				_wall_dragging = false
				if not _confirm_wall_placement(mouse_event.shift_pressed):
					_wall_has_anchor = _wall_continuing
		elif mouse_event.pressed:
			_update_ghost_position(mouse_event.position)
			confirm_placement()
		get_viewport().set_input_as_handled()

func begin_placement(building_def: BuildingDef) -> bool:
	if FogAccess.local_read_only(self):
		return false
	if (
		building_def == null
		or _entities == null
		or match_state == null
		or _selected_builders().is_empty()
		or not match_state.can_afford(
			PlayerCommands.local_team(self),
			building_def.cost_food,
			building_def.cost_wood,
			building_def.cost_gold, building_def.cost_stone
		)
	):
		return false
	if not Catalog.building_reason(match_state, PlayerCommands.local_team(self), civ, building_def, _entities).is_empty(): return false
	cancel_placement()
	_placement_def = building_def
	_ghost = _new_ghost(building_def, 0)
	if _is_wall_placement(): _wall_ghosts.append(_ghost)
	if is_instance_valid(_selection):
		_selection_input_was_enabled = _selection.is_processing_unhandled_input()
		_selection_input_suspended = true
		_selection.set_process_unhandled_input(false)
		if _selection.has_method("cancel_selection_drag"): _selection.call("cancel_selection_drag")
	if is_inside_tree(): _update_ghost_position(get_viewport().get_mouse_position())
	placement_changed.emit(true)
	return true

func confirm_placement() -> bool:
	if FogAccess.local_read_only(self):
		return false
	if _ghost == null:
		return false
	if _is_wall_placement(): return _confirm_wall_placement(false)
	_update_placement_validity()
	if not _placement_valid:
		return false
	var builders := _selected_builders()
	if builders.is_empty():
		return false
	var building_def := _ghost.get("def") as BuildingDef
	if PlayerCommands.is_online(self):
		var pos: Vector2 = _ghost.get("sim_pos")
		var accepted := PlayerCommands.submit(self, {
			"op": "place_building",
			"building_def_id": String(building_def.id),
			"builder_id": PlayerCommands.entity_id(self, builders[0]),
			"pos": [pos.x, pos.y],
			"orientation": _gate_orientation,
		})
		if accepted:
			cancel_placement()
		return accepted
	if not match_state.spend(
		PlayerCommands.local_team(self),
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold, building_def.cost_stone
	):
		_update_placement_validity()
		return false
	var placed := _ghost
	_ghost = null
	placed.call("clear_ghost_visual")
	PlayerCommands.Registry.report_manual_command({"op": "place_building", "builder_id": PlayerCommands.Registry.id_of(builders[0]), "building_def_id": String(building_def.id), "pos": [placed.sim_pos.x, placed.sim_pos.y], "orientation": _gate_orientation}, PlayerCommands.local_team(self), {"created_entity_id": PlayerCommands.Registry.id_of(placed)})
	for unit in builders:
		PlayerCommands.unit_order(self, unit, "build", placed)
	cancel_placement()
	return true

func cancel_placement() -> void:
	for ghost in _wall_ghosts:
		if is_instance_valid(ghost) and not ghost.is_queued_for_deletion(): ghost.queue_free()
	_wall_ghosts.clear()
	_wall_plan.clear()
	_wall_has_anchor = false
	_wall_dragging = false
	_wall_continuing = false
	_wall_include_gate = false
	_gate_orientation = 0
	_placement_def = null
	_drag_serial += 1
	if _ghost != null:
		if is_instance_valid(_ghost) and not _ghost.is_queued_for_deletion():
			_ghost.queue_free()
		_ghost = null
	if _selection_input_suspended and is_instance_valid(_selection):
		_selection.set_process_unhandled_input(_selection_input_was_enabled and match_state != null and match_state.winner == -1)
	_selection_input_suspended = false
	placement_reason = ""
	placement_changed.emit(false)

func is_placing() -> bool:
	return _ghost != null

func _selected_builders() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if _selection == null:
		return result
	for unit in _selection.call("get_selected_units"):
		if not is_instance_valid(unit) or unit.is_queued_for_deletion(): continue
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == PlayerCommands.local_team(self)
			and unit_def != null
			and unit_def.id == &"villager"
		):
			result.append(unit)
	return result

func _update_placement_validity() -> void:
	if _ghost == null:
		return
	if _is_wall_placement():
		_update_wall_validity()
		return
	var footprint: Vector2 = Walls.footprint_for(_ghost.get("def"), _gate_orientation)
	if _is_gate(_ghost.get("def")):
		placement_reason = Walls.validate_plan([{"building_def_id": String(_ghost.get("def").id), "pos": _ghost.get("sim_pos"), "orientation": _gate_orientation}], _placement_context())
		if not placement_reason.is_empty():
			_placement_valid = false
			_ghost.call("set_ghost_visual", false)
			return
	placement_reason = Catalog.building_reason(match_state, PlayerCommands.local_team(self), civ, _ghost.get("def"), _entities)
	if not placement_reason.is_empty():
		_placement_valid = false
		_ghost.call("set_ghost_visual", false)
		return
	if match_state.fog_enabled and (match_state.fog == null or not match_state.fog.footprint_visible(PlayerCommands.local_team(self), _ghost.get("sim_pos"), footprint, true)):
		_placement_valid = false
		placement_reason = "need_vision"
		_ghost.call("set_ghost_visual", false)
		return
	var existing: Array = []
	for node in _entities.get_children():
		if node != _ghost and (node.get("def") is BuildingDef or node.is_in_group("terrain_regions")):
			existing.append(node)
	_placement_valid = (
		can_place(
			footprint,
			_ghost.get("sim_pos"),
			existing
		)
		and match_state.can_afford(
			PlayerCommands.local_team(self),
			(_ghost.get("def") as BuildingDef).cost_food,
			(_ghost.get("def") as BuildingDef).cost_wood,
			(_ghost.get("def") as BuildingDef).cost_gold, (_ghost.get("def") as BuildingDef).cost_stone
		)
	)
	if not _placement_valid: placement_reason = "建筑占地被阻挡或资源不足"
	_ghost.call("set_ghost_visual", _placement_valid)

func _new_ghost(definition: BuildingDef, orientation: int) -> Node2D:
	var ghost := BUILDING_VIEW.instantiate() as Node2D
	if definition.id == &"farm": ghost.set_script(load("res://scripts/entities/farm_agent.gd"))
	ghost.name = "%sPreview" % String(definition.id).to_pascal_case()
	ghost.set("team", PlayerCommands.local_team(self))
	ghost.set("def", definition)
	ghost.set("civ", civ)
	ghost.set("match_state", match_state)
	ghost.set("is_placement_ghost", true)
	Walls.configure_building(ghost, orientation)
	ghost.call("start_construction")
	_entities.add_child(ghost)
	return ghost

func _is_wall_placement() -> bool:
	if not is_instance_valid(_ghost): return false
	return _placement_def != null and _placement_def.id in [&"palisade_wall", &"stone_wall", &"fortified_wall"]

func _is_gate(definition: BuildingDef) -> bool:
	return definition != null and definition.id in [&"gate", &"palisade_gate"]

func rotate_gate() -> void:
	if not is_instance_valid(_ghost) or not _is_gate(_ghost.get("def")): return
	_gate_orientation = (_gate_orientation + 1) % 4
	Walls.configure_building(_ghost, _gate_orientation)
	_update_placement_validity()

func _placement_context() -> CommandExecutionContext:
	var context := ExecutionContext.new()
	context.match_state = match_state
	context.entities = _entities
	context.team = PlayerCommands.local_team(self)
	context.civ = civ
	return context

func _snap_wall_point(pos: Vector2) -> Vector2:
	var nearest := pos.round()
	var distance := 0.8
	for node in _entities.get_children():
		var definition := node.get("def") as BuildingDef
		if definition == null or definition.id not in [&"palisade_wall", &"stone_wall", &"fortified_wall"]: continue
		if node.get("team") != PlayerCommands.local_team(self) or node.get("is_placement_ghost") == true or node.is_queued_for_deletion(): continue
		var at: Vector2 = node.get("sim_pos")
		if pos.distance_to(at) < distance:
			distance = pos.distance_to(at)
			nearest = at
	return nearest

func _update_wall_preview(pos: Vector2) -> void:
	var definition := _placement_def
	var endpoint := _snap_wall_point(pos)
	var start := _wall_anchor if _wall_has_anchor else endpoint
	_wall_plan = Walls.plan(String(definition.id), start, endpoint, _wall_include_gate)
	while _wall_ghosts.size() > maxi(1, _wall_plan.size()):
		_wall_ghosts.pop_back().queue_free()
	if _wall_plan.is_empty():
		_ghost = _wall_ghosts[0]
		_ghost.set("sim_pos", endpoint)
		IsoMathScript.sync_node(_ghost, endpoint)
		_update_wall_validity()
		return
	for index in _wall_plan.size():
		var entry: Dictionary = _wall_plan[index]
		var entry_def := Catalog.get_building(StringName(entry.building_def_id))
		if index >= _wall_ghosts.size():
			_wall_ghosts.append(_new_ghost(entry_def, int(entry.orientation)))
		elif (_wall_ghosts[index].get("def") as BuildingDef).id != entry_def.id:
			_wall_ghosts[index].queue_free()
			_wall_ghosts[index] = _new_ghost(entry_def, int(entry.orientation))
		var ghost := _wall_ghosts[index]
		if int(ghost.get("wall_orientation")) != int(entry.orientation):
			Walls.configure_building(ghost, int(entry.orientation))
		ghost.set("sim_pos", entry.pos)
		IsoMathScript.sync_node(ghost, entry.pos)
	if not _wall_ghosts.is_empty(): _ghost = _wall_ghosts[0]
	_update_wall_validity()

func _update_wall_validity() -> void:
	var context := _placement_context()
	placement_reason = Walls.validate_plan(_wall_plan, context)
	_placement_valid = placement_reason.is_empty()
	if _wall_plan.is_empty():
		for ghost in _wall_ghosts: ghost.call("set_ghost_visual", false)
		return
	var costs := _wall_costs()
	var affordable := match_state.can_afford(context.team, costs.food, costs.wood, costs.gold, costs.stone)
	for index in _wall_ghosts.size():
		var valid := affordable and Walls.validate_plan([_wall_plan[index]], context).is_empty()
		_wall_ghosts[index].call("set_ghost_visual", valid)

func _confirm_wall_placement(continue_wall: bool) -> bool:
	if FogAccess.local_read_only(self) or _wall_plan.is_empty(): return false
	_update_wall_validity()
	var builders := _selected_builders()
	if not _placement_valid or builders.is_empty(): return false
	var first: Dictionary = _wall_plan[0]
	var last: Dictionary = _wall_plan[-1]
	var start: Vector2 = first.pos
	var endpoint: Vector2 = last.pos
	var definition := _placement_def
	var command := {"op": "place_wall", "building_def_id": String(definition.id), "start": [start.x, start.y], "end": [endpoint.x, endpoint.y], "include_gate": _wall_include_gate, "append_queue": _wall_continuing}
	if PlayerCommands.is_online(self):
		command.builder_id = PlayerCommands.entity_id(self, builders[0])
		if not PlayerCommands.submit(self, command): return false
	else:
		var placed: Array = Walls.place_plan(_wall_plan, _placement_context(), builders[0], _wall_continuing)
		if placed.is_empty(): return false
		var ids: Array[int] = []
		for building in placed: ids.append(PlayerCommands.Registry.id_of(building))
		for index in builders.size():
			if index > 0: builders[index].call("command_build_queue", placed, _wall_continuing)
			var manual := command.duplicate()
			manual.builder_id = PlayerCommands.Registry.id_of(builders[index])
			PlayerCommands.Registry.report_manual_command(manual, PlayerCommands.local_team(self), {"created_entity_ids": ids})
	if continue_wall:
		_wall_anchor = endpoint
		_wall_has_anchor = true
		_wall_continuing = true
		_update_wall_preview(endpoint)
	else:
		cancel_placement()
	return true

func _wall_costs() -> Dictionary:
	var context := _placement_context()
	var result := Walls.cost(_wall_plan, context)
	result.segments = 0
	for entry: Dictionary in _wall_plan:
		if Walls.existing_segment(entry, context) == null: result.segments += 1
	return result

func get_placement_hint() -> String:
	if not is_placing(): return ""
	var reason := String({"need_vision": "需要视野：先探索整段占地", "invalid_wall_length": "每段最多 64 格，插入城门至少 6 格", "invalid_placement": "建筑占地被阻挡", "outside_map": "超出地图边界", "cannot_afford_wall": "整段城墙资源不足", "overlapping_segments": "墙段占地重叠"}.get(placement_reason, placement_reason))
	if _is_wall_placement():
		var costs := _wall_costs()
		var summary := "%d 段 · 木材 %d / 石料 %d" % [costs.segments, costs.wood, costs.stone]
		return summary + (" · " + reason if not reason.is_empty() else "") + "\n左键拖建八方向；Shift 续建转弯；G " + ("移除城门" if _wall_include_gate else "加入城门") + "；右键/Esc 取消"
	return (reason + "。" if not reason.is_empty() else "") + ("左键放置城门；R 旋转方向；右键/Esc 取消。" if _is_gate(_ghost.get("def")) else "左键放置建筑；右键或 Esc 取消。")

func _in_play_area(pos: Vector2) -> bool:
	var area: Rect2 = _selection.get_meta("world_screen_rect", get_viewport().get_visible_rect()) if is_instance_valid(_selection) else get_viewport().get_visible_rect()
	if not area.has_point(pos): return false
	var hovered := get_viewport().gui_get_hovered_control()
	return hovered == null or hovered.mouse_filter == Control.MOUSE_FILTER_IGNORE or not hovered.get_global_rect().has_point(pos)

func _viewport_to_logical(screen_position: Vector2) -> Vector2:
	var canvas := get_viewport().get_canvas_transform().affine_inverse() * screen_position
	return IsoMathScript.screen_to_world(canvas)
