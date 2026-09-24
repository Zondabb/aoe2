class_name BuildSystem
extends Node

const FogAccess := preload("res://scripts/systems/fog_access.gd")

signal placement_changed(active: bool)

const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

var match_state: MatchState
var civ: CivDef
var _camera: Camera2D
var _entities: Node2D
var _selection: Control
var _ghost: Node2D
var _placement_valid := false
var placement_reason := ""

static func can_place(
	footprint: Vector2, center: Vector2, existing_buildings: Array
) -> bool:
	var candidate_half := footprint * 0.5
	for value in existing_buildings:
		var building := value as Node2D
		if building == null:
			continue
		var building_def := building.get("def") as BuildingDef
		var existing_footprint := (
			building_def.footprint if building_def != null else Vector2.ONE
		)
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
	_ghost.set("sim_pos", logical)
	IsoMathScript.sync_node(_ghost, logical)
	_update_placement_validity()

func _unhandled_input(event: InputEvent) -> void:
	if _ghost == null or not event is InputEventMouseButton:
		return
	var mouse_event := event as InputEventMouseButton
	if not mouse_event.pressed:
		return
	if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
		cancel_placement()
		get_viewport().set_input_as_handled()
	elif mouse_event.button_index == MOUSE_BUTTON_LEFT:
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
			Enums.Team.PLAYER,
			building_def.cost_food,
			building_def.cost_wood,
			building_def.cost_gold
		)
	):
		return false
	cancel_placement()
	_ghost = BUILDING_VIEW.instantiate() as Node2D
	_ghost.name = "%sFoundation" % String(building_def.id).to_pascal_case()
	_ghost.set("team", Enums.Team.PLAYER)
	_ghost.set("def", building_def)
	_ghost.set("civ", civ)
	_ghost.set("match_state", match_state)
	_ghost.set("is_placement_ghost", true)
	_ghost.call("start_construction")
	_entities.add_child(_ghost)
	_update_placement_validity()
	placement_changed.emit(true)
	return true

func confirm_placement() -> bool:
	if FogAccess.local_read_only(self):
		return false
	if _ghost == null:
		return false
	_update_placement_validity()
	if not _placement_valid:
		return false
	var builders := _selected_builders()
	if builders.is_empty():
		return false
	var building_def := _ghost.get("def") as BuildingDef
	if not match_state.spend(
		Enums.Team.PLAYER,
		building_def.cost_food,
		building_def.cost_wood,
		building_def.cost_gold
	):
		_update_placement_validity()
		return false
	var placed := _ghost
	_ghost = null
	placed.call("clear_ghost_visual")
	for unit in builders:
		unit.call("command_build", placed)
	placement_changed.emit(false)
	return true

func cancel_placement() -> void:
	if _ghost != null:
		if is_instance_valid(_ghost) and not _ghost.is_queued_for_deletion():
			_ghost.queue_free()
		_ghost = null
	placement_changed.emit(false)

func is_placing() -> bool:
	return _ghost != null

func _selected_builders() -> Array[Node2D]:
	var result: Array[Node2D] = []
	if _selection == null:
		return result
	for unit in _selection.call("get_selected_units"):
		var unit_def := unit.get("def") as UnitDef
		if (
			unit.get("team") == Enums.Team.PLAYER
			and unit_def != null
			and unit_def.id == &"villager"
		):
			result.append(unit)
	return result

func _update_placement_validity() -> void:
	if _ghost == null:
		return
	placement_reason = ""
	if match_state.fog_enabled and (match_state.fog == null or not match_state.fog.footprint_visible(Enums.Team.PLAYER, _ghost.get("sim_pos"), _ghost.get("def").footprint, true)):
		_placement_valid = false
		placement_reason = "need_vision"
		_ghost.call("set_ghost_visual", false)
		return
	var existing: Array = []
	for node in _entities.get_children():
		if node != _ghost and node.get("def") is BuildingDef:
			existing.append(node)
	_placement_valid = (
		can_place(
			(_ghost.get("def") as BuildingDef).footprint,
			_ghost.get("sim_pos"),
			existing
		)
		and match_state.can_afford(
			Enums.Team.PLAYER,
			(_ghost.get("def") as BuildingDef).cost_food,
			(_ghost.get("def") as BuildingDef).cost_wood,
			(_ghost.get("def") as BuildingDef).cost_gold
		)
	)
	_ghost.call("set_ghost_visual", _placement_valid)

func _viewport_to_logical(screen_position: Vector2) -> Vector2:
	var canvas := get_viewport().get_canvas_transform().affine_inverse() * screen_position
	return IsoMathScript.screen_to_world(canvas)
