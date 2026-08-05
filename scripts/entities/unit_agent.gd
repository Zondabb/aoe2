class_name UnitAgent
extends Node3D

const ARRIVAL_DISTANCE := 0.15
const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: UnitDef

var hp := 0
var order: Enums.OrderType = Enums.OrderType.NONE
var sim_pos := Vector3.ZERO
var _move_target := Vector3.ZERO

func _ready() -> void:
	add_to_group("units")
	sim_pos = Vector3(position.x, 0.0, position.z)
	position = sim_pos
	hp = def.max_hp if def != null else 0
	_apply_team_color()
	set_selected(false)

func _physics_process(delta: float) -> void:
	if order != Enums.OrderType.MOVE or def == null:
		return

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
	order = Enums.OrderType.MOVE

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
