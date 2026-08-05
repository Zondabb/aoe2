class_name UnitAgent
extends Node3D

const ARRIVAL_DISTANCE := 0.15
const GATHER_RANGE := 1.2
const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
const GatherSystemScript := preload("res://scripts/systems/gather_system.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: UnitDef

var hp := 0
var order: Enums.OrderType = Enums.OrderType.NONE
var sim_pos := Vector3.ZERO
var carry_type := -1
var carry_amount := 0.0
@export var carry_capacity := 10.0
var match_state: MatchState
var _move_target := Vector3.ZERO
var _gather_target: Node3D
var _last_resource: Node3D
var _drop_off_target: Node3D
var _build_target: Node3D
var _gather_state := ""
var _population_registered := false

func _ready() -> void:
	add_to_group("units")
	sim_pos = Vector3(position.x, 0.0, position.z)
	position = sim_pos
	hp = def.max_hp if def != null else 0
	register_population()
	_apply_team_color()
	set_selected(false)

func register_population() -> void:
	if match_state != null and def != null and not _population_registered:
		match_state.register_pop(team, def.population, 0)
		_population_registered = true

func _physics_process(delta: float) -> void:
	if def == null:
		return
	if order == Enums.OrderType.MOVE:
		_process_move(delta)
	elif order == Enums.OrderType.GATHER:
		_process_gather(delta)
	elif order == Enums.OrderType.BUILD:
		_process_build(delta)

func _process_move(delta: float) -> void:
	var offset := _move_target - sim_pos
	offset.y = 0.0
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		sim_pos = _move_target
		position = sim_pos
		order = Enums.OrderType.NONE
		return

	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	sim_pos += velocity
	sim_pos.y = 0.0
	position = sim_pos
	rotation.y = atan2(velocity.x, velocity.z)

func command_move(target: Vector3) -> void:
	_move_target = Vector3(target.x, 0.0, target.z)
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_gather_state = ""
	order = Enums.OrderType.MOVE

func command_gather(resource: Node3D) -> void:
	if resource == null or float(resource.get("amount")) <= 0.0:
		return
	_gather_target = resource
	_last_resource = resource
	_drop_off_target = null
	_build_target = null
	_gather_state = "to_resource"
	order = Enums.OrderType.GATHER

func command_build(building: Node3D) -> void:
	if (
		building == null
		or bool(building.get("is_complete"))
		or def == null
		or def.id != &"villager"
	):
		return
	_build_target = building
	_gather_target = null
	_drop_off_target = null
	_gather_state = ""
	order = Enums.OrderType.BUILD

func _process_build(delta: float) -> void:
	if not is_instance_valid(_build_target) or bool(_build_target.get("is_complete")):
		_build_target = null
		order = Enums.OrderType.NONE
		return
	var build_range := 1.0
	var building_def := _build_target.get("def") as BuildingDef
	if building_def != null:
		build_range += maxf(
			building_def.footprint.x, building_def.footprint.y
		) * 0.5
	if _distance_to(_build_target) > build_range:
		_move_toward(_build_target.position, delta)
		return
	_build_target.call("add_build_progress", delta)
	if bool(_build_target.get("is_complete")):
		_build_target = null
		order = Enums.OrderType.NONE

func _process_gather(delta: float) -> void:
	match _gather_state:
		"to_resource":
			if not _resource_available(_gather_target):
				_finish_or_drop_off()
			elif _distance_to(_gather_target) <= GATHER_RANGE:
				_gather_state = "gathering"
			else:
				_move_toward(_gather_target.position, delta)
		"gathering":
			_gather(delta)
		"to_drop_off":
			_process_drop_off(delta)
		_:
			order = Enums.OrderType.NONE

func _gather(delta: float) -> void:
	if not _resource_available(_gather_target):
		_finish_or_drop_off()
		return
	if _distance_to(_gather_target) > GATHER_RANGE:
		_gather_state = "to_resource"
		return
	var remaining_capacity := carry_capacity - carry_amount
	if remaining_capacity <= 0.0:
		_begin_drop_off()
		return
	if carry_type == -1:
		carry_type = int(_gather_target.get("resource_type"))
	var gather_rate := float(_gather_target.get("gather_rate"))
	var gather_time := minf(delta, remaining_capacity / gather_rate)
	carry_amount += float(_gather_target.call("extract", gather_time))
	if carry_amount >= carry_capacity or not _resource_available(_gather_target):
		_begin_drop_off()

func _begin_drop_off() -> void:
	if carry_amount <= 0.0:
		order = Enums.OrderType.NONE
		return
	_drop_off_target = GatherSystemScript.nearest_drop_off(self, carry_type)
	if _drop_off_target == null:
		order = Enums.OrderType.NONE
		return
	_gather_state = "to_drop_off"

func _process_drop_off(delta: float) -> void:
	if not is_instance_valid(_drop_off_target):
		_begin_drop_off()
		return
	if _distance_to(_drop_off_target) > GATHER_RANGE:
		_move_toward(_drop_off_target.position, delta)
		return
	if match_state != null:
		match_state.add_resource(team, carry_type, int(round(carry_amount)))
	carry_amount = 0.0
	carry_type = -1
	_drop_off_target = null
	if _resource_available(_last_resource):
		_gather_target = _last_resource
		_gather_state = "to_resource"
	else:
		order = Enums.OrderType.NONE
		_gather_state = ""

func _finish_or_drop_off() -> void:
	if carry_amount > 0.0:
		_begin_drop_off()
	else:
		order = Enums.OrderType.NONE
		_gather_state = ""

func _resource_available(resource: Node3D) -> bool:
	return is_instance_valid(resource) and float(resource.get("amount")) > 0.0

func _distance_to(target: Node3D) -> float:
	return position.distance_to(target.position)

func _move_toward(target: Vector3, delta: float) -> void:
	var offset := Vector3(target.x, 0.0, target.z) - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	sim_pos += velocity
	sim_pos.y = 0.0
	position = sim_pos
	rotation.y = atan2(velocity.x, velocity.z)

func set_selected(selected: bool) -> void:
	var selection_ring := get_node_or_null("SelectionRing") as MeshInstance3D
	if selection_ring != null:
		selection_ring.visible = selected

func _apply_team_color() -> void:
	var body := get_node_or_null("Body") as MeshInstance3D
	if body == null:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = PLAYER_COLOR if team == Enums.Team.PLAYER else AI_COLOR
	material.roughness = 0.8
	body.material_override = material

func _exit_tree() -> void:
	if _population_registered and match_state != null and def != null:
		match_state.register_pop(team, -def.population, 0)
		_population_registered = false
