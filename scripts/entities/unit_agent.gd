class_name UnitAgent
extends Node3D

const ARRIVAL_DISTANCE := 0.15
const GATHER_RANGE := 1.2
const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
## Soft tint so billboard sprites remain readable while teams stay distinct.
const PLAYER_BILLBOARD_TINT := Color(0.65, 0.82, 1.0, 1.0)
const AI_BILLBOARD_TINT := Color(1.0, 0.62, 0.58, 1.0)
const ANIM_FPS := 12.0
const GatherSystemScript := preload("res://scripts/systems/gather_system.gd")
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: UnitDef
@export var civ: CivDef

var hp := 0.0
var melee_armor := 0.0
var pierce_armor := 0.0
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
var _attack_target: Node3D
var _attack_cooldown_remaining := 0.0
var _gather_state := ""
var _population_registered := false
var _use_billboard := false
var _facing_dir := 0
var _facing_flip := false
var _anim_frame := 0.0

func _ready() -> void:
	add_to_group("units")
	sim_pos = Vector3(position.x, 0.0, position.z)
	position = sim_pos
	hp = float(def.max_hp) if def != null else 0.0
	melee_armor = float(def.melee_armor) if def != null else 0.0
	pierce_armor = float(def.pierce_armor) if def != null else 0.0
	if def != null and civ != null and not def.is_ranged:
		melee_armor += civ.melee_armor_bonus
	register_population()
	_setup_presentation()
	set_selected(false)

func register_population() -> void:
	if match_state != null and def != null and not _population_registered:
		match_state.register_pop(team, def.population, 0)
		_population_registered = true

func _physics_process(delta: float) -> void:
	if def == null:
		return
	if match_state != null and match_state.frozen:
		return
	if order == Enums.OrderType.MOVE:
		_process_move(delta)
	elif order == Enums.OrderType.GATHER:
		_process_gather(delta)
	elif order == Enums.OrderType.BUILD:
		_process_build(delta)
	elif order == Enums.OrderType.ATTACK:
		_process_attack(delta)

func _process_move(delta: float) -> void:
	var offset := _move_target - sim_pos
	offset.y = 0.0
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		sim_pos = _move_target
		position = sim_pos
		order = Enums.OrderType.NONE
		_apply_billboard_frame(false)
		return

	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	sim_pos += velocity
	sim_pos.y = 0.0
	position = sim_pos
	_update_billboard_facing(velocity, delta, true)

func command_move(target: Vector3) -> void:
	_move_target = Vector3(target.x, 0.0, target.z)
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	order = Enums.OrderType.MOVE

func command_gather(resource: Node3D) -> void:
	if resource == null or float(resource.get("amount")) <= 0.0:
		return
	_build_target = null
	_attack_target = null
	var new_type := int(resource.get("resource_type"))
	# Demo: switching resource type while carrying → drop off current, then gather new.
	if carry_amount > 0.0 and carry_type != -1 and carry_type != new_type:
		_last_resource = resource
		_gather_target = resource
		order = Enums.OrderType.GATHER
		_begin_drop_off()
		return
	_gather_target = resource
	_last_resource = resource
	_drop_off_target = null
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
	_attack_target = null
	_gather_target = null
	_drop_off_target = null
	_gather_state = ""
	order = Enums.OrderType.BUILD

func command_attack(target: Node) -> void:
	var target_3d := target as Node3D
	if (
		target_3d == null
		or not is_instance_valid(target_3d)
		or target_3d.get("team") == team
		or target_3d.get("is_placement_ghost") == true
		or not target_3d.has_method("take_damage")
	):
		return
	_attack_target = target_3d
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_gather_state = ""
	order = Enums.OrderType.ATTACK

func _process_attack(delta: float) -> void:
	if not _attack_target_available():
		_attack_target = null
		order = Enums.OrderType.NONE
		return
	_attack_cooldown_remaining = maxf(0.0, _attack_cooldown_remaining - delta)
	if _distance_to(_attack_target) > def.range:
		_move_toward(_attack_target.position, delta)
		return
	if _attack_cooldown_remaining > 0.0:
		return
	CombatSystemScript.apply_hit(def, _attack_target)
	_attack_cooldown_remaining = def.attack_cooldown
	if not _attack_target_available():
		_attack_target = null
		order = Enums.OrderType.NONE

func take_damage(amount: float) -> void:
	if amount <= 0.0 or hp <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		queue_free()

func _attack_target_available() -> bool:
	return (
		is_instance_valid(_attack_target)
		and not _attack_target.is_queued_for_deletion()
		and float(_attack_target.get("hp")) > 0.0
		and _attack_target.get("team") != team
	)

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
		_apply_billboard_frame(false)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	sim_pos += velocity
	sim_pos.y = 0.0
	position = sim_pos
	_update_billboard_facing(velocity, delta, true)

func set_selected(selected: bool) -> void:
	var selection_ring := get_node_or_null("SelectionRing") as MeshInstance3D
	if selection_ring != null:
		selection_ring.visible = selected

func _setup_presentation() -> void:
	var body := get_node_or_null("Body") as MeshInstance3D
	var billboard := get_node_or_null("Billboard") as AnimatedSprite3D
	_use_billboard = false
	if billboard != null and def != null:
		var base := SpriteCatalogScript.unit_sheet_base(def.id)
		if SpriteCatalogScript.sheet_paths_exist(base):
			var meta := SpriteCatalogScript.load_meta(base)
			var texture := SpriteCatalogScript.load_texture(base)
			if not meta.is_empty() and texture != null:
				billboard.sprite_frames = SpriteCatalogScript.build_unit_sprite_frames(
					meta, texture
				)
				var hotspot := SpriteCatalogScript.average_hotspot(meta)
				var offset := SpriteCatalogScript.offset_for_hotspot(meta, hotspot)
				SpriteCatalogScript.configure_billboard_sprite(
					billboard, SpriteCatalogScript.UNIT_PIXEL_SIZE, offset
				)
				billboard.visible = true
				_use_billboard = true
				_apply_team_color()
				_apply_billboard_frame(false)
				SpriteCatalogScript.ensure_ground_shadow(self, 0.55)
	if body != null:
		body.visible = not _use_billboard
		if not _use_billboard:
			_apply_team_color()
	if billboard != null and not _use_billboard:
		billboard.visible = false
	if not _use_billboard:
		SpriteCatalogScript.ensure_ground_shadow(self, 0.55)

func _update_billboard_facing(velocity: Vector3, delta: float, moving: bool) -> void:
	if not _use_billboard:
		return
	var facing: Dictionary = SpriteCatalogScript.quantize_xz_facing(velocity)
	_facing_dir = int(facing["dir"])
	_facing_flip = bool(facing["flip"])
	if moving:
		_anim_frame = fmod(_anim_frame + ANIM_FPS * delta, 1024.0)
	_apply_billboard_frame(moving)

func _apply_billboard_frame(moving: bool) -> void:
	var billboard := get_node_or_null("Billboard") as AnimatedSprite3D
	if billboard == null or billboard.sprite_frames == null:
		return
	var anim := StringName("dir_%d" % _facing_dir)
	if not billboard.sprite_frames.has_animation(anim):
		return
	billboard.flip_h = _facing_flip
	if billboard.animation != anim:
		billboard.animation = anim
	var frame_count := billboard.sprite_frames.get_frame_count(anim)
	if frame_count <= 0:
		return
	billboard.frame = (int(_anim_frame) % frame_count) if moving else 0

func _apply_team_color() -> void:
	var body := get_node_or_null("Body") as MeshInstance3D
	if body != null and body.visible:
		var material := StandardMaterial3D.new()
		material.albedo_color = PLAYER_COLOR if team == Enums.Team.PLAYER else AI_COLOR
		material.roughness = 0.8
		body.material_override = material
	var billboard := get_node_or_null("Billboard") as AnimatedSprite3D
	if billboard != null and _use_billboard:
		billboard.modulate = (
			PLAYER_BILLBOARD_TINT if team == Enums.Team.PLAYER else AI_BILLBOARD_TINT
		)

func _exit_tree() -> void:
	if _population_registered and match_state != null and def != null:
		match_state.register_pop(team, -def.population, 0)
		_population_registered = false
