class_name UnitAgent
extends Node2D

const ARRIVAL_DISTANCE := 0.15
## Near goal with no forward progress → treat as arrived (stops cluster skate).
const STUCK_ARRIVE_DISTANCE := 1.05
const STUCK_FRAMES_TO_STOP := 10
const CROWD_ARRIVE_DISTANCE := 1.85
const MAX_STUCK_REPATH_ATTEMPTS := 2
const PATH_RETRY_COOLDOWN := 0.3
## Soft-sep / wall-slide only counts as walking with enough forward progress.
const MIN_WALK_PROGRESS := 0.012
const GATHER_RANGE := 1.2
const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
const PLAYER_BILLBOARD_TINT := Color(0.65, 0.82, 1.0, 1.0)
const AI_BILLBOARD_TINT := Color(1.0, 0.62, 0.58, 1.0)
const ANIM_FPS := 18.0
const ATTACK_HIT_FRACTION := 0.45
const RANGED_RELEASE_FRACTION := 0.35
const ATTACK_CHASE_SLACK := 0.25
const MELEE_ATTACK_SLOTS := 12
const ATTACK_STUCK_FRAMES := 6
const FALLBACK_ATTACK_DURATION := 0.45
const FALLBACK_DIE_DURATION := 0.8
const WORLD_HP_BAR_WIDTH := 28.0
const WORLD_HP_BAR_HEIGHT := 6.0
const WORLD_HP_BAR_GAP := 4.0
const PROJECTILE_SCENE := preload("res://scenes/entities/projectile_view.tscn")
const ProjectileAgentScript := preload("res://scripts/entities/projectile_agent.gd")
const GatherSystemScript := preload("res://scripts/systems/gather_system.gd")
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: UnitDef
@export var civ: CivDef

var hp := 0.0
var melee_armor := 0.0
var pierce_armor := 0.0
var order: Enums.OrderType = Enums.OrderType.NONE
var sim_pos := Vector2.ZERO
var carry_type := -1
var carry_amount := 0.0
@export var carry_capacity := 10.0
var match_state: MatchState
var _move_target := Vector2.ZERO
var _gather_target: Node2D
var _last_resource: Node2D
var _drop_off_target: Node2D
var _build_target: Node2D
var _attack_target: Node2D
var _attack_cooldown_remaining := 0.0
var _gather_state := ""
var _population_registered := false
var _use_billboard := false
var _villager_actions := false
var _facing_dir := 0
var _facing_flip := false
var _anim_frame := 0.0
var _sprite_metas: Dictionary = {}
var _no_progress_frames := 0
var _combat_action := &""
var _combat_anim_time := 0.0
var _attack_hit_applied := false
var _projectile_spawned := false
var _max_hp := 0.0
var _path: PackedVector2Array = PackedVector2Array()
var _path_index := 0
var _path_pending := false
var _nav_goal := Vector2.ZERO
var _stuck_repath_attempts := 0
var _path_retry_cooldown := 0.0
var _debug_steer_velocity := Vector2.ZERO
var _debug_actual_delta := Vector2.ZERO

func _ready() -> void:
	add_to_group("units")
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	_sync_visual()
	hp = float(def.max_hp) if def != null else 0.0
	_max_hp = hp
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
	elif _combat_action == &"die":
		_process_die(delta)
	else:
		_update_idle_animation(delta)

func _process_move(delta: float) -> void:
	var from_pos := sim_pos
	if _path_pending:
		_refresh_move_debug(_steer_velocity_toward(delta), from_pos)
		return
	if _path.is_empty():
		if _path_retry_cooldown > 0.0:
			_path_retry_cooldown = maxf(0.0, _path_retry_cooldown - delta)
			_refresh_move_debug(Vector2.ZERO, from_pos)
			return
		_path_retry_cooldown = PATH_RETRY_COOLDOWN
		_request_nav_path(_move_target)
		_refresh_move_debug(_steer_velocity_toward(delta), from_pos)
		return
	var steer_target := _current_steer_target()
	var offset := steer_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if _advance_path_waypoint():
			return
		_finish_move()
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context())
	_sync_visual()
	_refresh_move_debug(velocity, from_pos)
	var progress := forward_progress(from_pos, sim_pos, velocity)
	var walking := is_walk_progress(progress, step)
	if walking:
		_no_progress_frames = 0
	else:
		_no_progress_frames += 1
		if _no_progress_frames == 4:
			_depack_from_allies()
		var goal_dist := sim_pos.distance_to(_move_target)
		if _no_progress_frames >= STUCK_FRAMES_TO_STOP:
			if goal_dist <= CROWD_ARRIVE_DISTANCE:
				if _try_recover_from_stuck():
					return
				_finish_move()
				return
			if _try_recover_from_stuck():
				return
			_no_progress_frames = 0
	_update_billboard_facing_from_vector(offset, delta, walking, walking)

func _finish_move() -> void:
	_no_progress_frames = 0
	_stuck_repath_attempts = 0
	_clear_move_debug()
	_path = PackedVector2Array()
	_path_index = 0
	_path_pending = false
	order = Enums.OrderType.NONE
	_update_idle_animation(0.0)

func command_move(target: Vector2) -> void:
	_move_target = target
	_nav_goal = target
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	_no_progress_frames = 0
	_stuck_repath_attempts = 0
	_depack_from_allies()
	_resolve_start_position()
	_request_nav_path(target)
	order = Enums.OrderType.MOVE

func command_stop() -> void:
	_move_target = Vector2.ZERO
	_nav_goal = Vector2.ZERO
	_path = PackedVector2Array()
	_path_index = 0
	_path_pending = false
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	_no_progress_frames = 0
	_stuck_repath_attempts = 0
	order = Enums.OrderType.NONE
	_clear_move_debug()
	_update_idle_animation(0.0)

func command_gather(resource: Node2D) -> void:
	if resource == null or float(resource.get("amount")) <= 0.0:
		return
	_build_target = null
	_attack_target = null
	var new_type := int(resource.get("resource_type"))
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

func command_build(building: Node2D) -> void:
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
	var target_2d := target as Node2D
	if (
		target_2d == null
		or not is_instance_valid(target_2d)
		or target_2d.get("team") == team
		or target_2d.get("is_placement_ghost") == true
		or not target_2d.has_method("take_damage")
	):
		return
	_attack_target = target_2d
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_gather_state = ""
	order = Enums.OrderType.ATTACK

func _process_attack(delta: float) -> void:
	if _combat_action == &"die":
		_process_die(delta)
		return
	if not _attack_target_available():
		_cancel_combat_action()
		_attack_target = null
		order = Enums.OrderType.NONE
		return
	_attack_cooldown_remaining = maxf(0.0, _attack_cooldown_remaining - delta)
	if _needs_attack_chase(_attack_target):
		if _combat_action == &"attack":
			_cancel_combat_action()
		_move_toward(_attack_approach_point(_attack_target), delta)
		return
	if _combat_action == &"attack":
		_process_attack_animation(delta)
		return
	_face_toward(_attack_target.get("sim_pos"), delta, false)
	if _attack_cooldown_remaining > 0.0:
		_update_idle_animation(delta)
		return
	_begin_attack()
	_process_attack_animation(delta)

func _begin_attack() -> void:
	_combat_action = &"attack"
	_combat_anim_time = 0.0
	_attack_hit_applied = false
	_projectile_spawned = false
	_attack_cooldown_remaining = def.attack_cooldown
	_anim_frame = 0.0

func _cancel_combat_action() -> void:
	_combat_action = &""
	_combat_anim_time = 0.0
	_attack_hit_applied = false
	_projectile_spawned = false

func _process_attack_animation(delta: float) -> void:
	if not _attack_target_available():
		_cancel_combat_action()
		_attack_target = null
		order = Enums.OrderType.NONE
		return
	_face_toward(_attack_target.get("sim_pos"), delta, false)
	var duration := _combat_anim_duration(&"attack")
	_combat_anim_time += delta
	_apply_billboard_frame(true, &"attack", false)
	if def.is_ranged:
		# Ranged damage is resolved only by the projectile impact splash.
		if not _projectile_spawned and _combat_anim_time >= duration * RANGED_RELEASE_FRACTION:
			_spawn_projectile()
			_projectile_spawned = true
	elif not _attack_hit_applied:
		if _combat_anim_time >= duration * ATTACK_HIT_FRACTION:
			if _attack_target_available():
				CombatSystemScript.apply_hit(def, _attack_target, {"attacker": self})
			_attack_hit_applied = true
	if _combat_anim_time >= duration:
		_cancel_combat_action()
		if not _attack_target_available():
			_attack_target = null
			order = Enums.OrderType.NONE

func _spawn_projectile() -> void:
	if not _attack_target_available():
		return
	var parent := get_parent()
	if parent == null:
		return
	var projectile := PROJECTILE_SCENE.instantiate() as Node2D
	if projectile == null:
		return
	parent.add_child(projectile)
	var aim := ProjectileAgentScript.aim_point_for_target(sim_pos, _attack_target)
	projectile.call("setup", sim_pos, aim, def, team, self)

func _process_die(delta: float) -> void:
	var duration := _combat_anim_duration(&"die")
	_combat_anim_time += delta
	_apply_billboard_frame(true, &"die", false)
	if _combat_anim_time >= duration:
		queue_free()

func _begin_die() -> void:
	order = Enums.OrderType.NONE
	_attack_target = null
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_gather_state = ""
	_cancel_combat_action()
	_combat_action = &"die"
	_combat_anim_time = 0.0
	_anim_frame = 0.0
	if _combat_anim_duration(&"die") <= 0.01:
		queue_free()

func _combat_anim_duration(action: StringName) -> float:
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard == null or billboard.sprite_frames == null or def == null:
		return FALLBACK_ATTACK_DURATION if action == &"attack" else FALLBACK_DIE_DURATION
	var anim := _combat_animation_name(action)
	if not billboard.sprite_frames.has_animation(anim):
		return FALLBACK_ATTACK_DURATION if action == &"attack" else FALLBACK_DIE_DURATION
	var frame_count := billboard.sprite_frames.get_frame_count(anim)
	return maxf(float(frame_count) / ANIM_FPS, 0.1)

func _combat_animation_name(action: StringName) -> StringName:
	if _villager_actions:
		return _pick_villager_animation(action)
	return StringName("%s_dir_%d" % [action, _facing_dir])

func take_damage(amount: float, source: Node = null) -> void:
	if amount <= 0.0 or hp <= 0.0 or _combat_action == &"die":
		return
	hp = maxf(0.0, hp - amount)
	_refresh_world_hp_bar()
	if hp <= 0.0:
		_begin_die()
		return
	_try_retaliate(source)

func _try_retaliate(source: Node) -> void:
	# Idle-only aggro: do not interrupt move / gather / build / active attack.
	if order != Enums.OrderType.NONE:
		return
	if source == null or not is_instance_valid(source):
		return
	if source == self:
		return
	command_attack(source)

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
		_move_toward(_build_approach_point(_build_target), delta)
		return
	_face_toward(_build_target.get("sim_pos"), delta, true)
	_build_target.call("add_build_progress", delta)
	if bool(_build_target.get("is_complete")):
		_build_target = null
		order = Enums.OrderType.NONE

func _process_gather(delta: float) -> void:
	match _gather_state:
		"to_resource":
			if not _resource_available(_gather_target):
				_finish_or_drop_off()
			elif _gather_reach_distance(_gather_target) <= GATHER_RANGE:
				_gather_state = "gathering"
				_face_toward(_gather_target.get("sim_pos"), delta, true)
			else:
				_move_toward(_gather_approach_point(_gather_target), delta)
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
	if _gather_reach_distance(_gather_target) > GATHER_RANGE:
		_gather_state = "to_resource"
		return
	_face_toward(_gather_target.get("sim_pos"), delta, true)
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
		_move_toward(_drop_off_target.get("sim_pos"), delta)
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

func _resource_available(resource: Node2D) -> bool:
	return is_instance_valid(resource) and float(resource.get("amount")) > 0.0


func _gather_approach_point(resource: Node2D) -> Vector2:
	if resource != null and resource.has_method("approach_point"):
		return resource.call("approach_point", sim_pos, _pathfinding_radius())
	if resource != null:
		return resource.get("sim_pos")
	return sim_pos


## Distance used for gather-in-range checks. Large resource footprints (gold/trees)
## place villagers at the edge; comparing to the resource center would never enter range.
func _gather_reach_distance(resource: Node2D) -> float:
	if resource == null:
		return INF
	if resource.has_method("approach_point"):
		return sim_pos.distance_to(_gather_approach_point(resource))
	return sim_pos.distance_to(resource.get("sim_pos"))


func _build_approach_point(building: Node2D) -> Vector2:
	if building == null:
		return sim_pos
	var building_def := building.get("def") as BuildingDef
	var center: Vector2 = building.get("sim_pos")
	if building_def == null:
		return center
	var half := building_def.footprint * 0.5
	var to_unit := sim_pos - center
	if to_unit.length_squared() <= 0.0001:
		to_unit = Vector2(1.0, 0.0)
	else:
		to_unit = to_unit.normalized()
	var stand_radius := maxf(half.x, half.y) + _pathfinding_radius() + 0.2
	return center + to_unit * stand_radius

func _distance_to(target: Node2D) -> float:
	var target_pos: Vector2 = target.get("sim_pos")
	var building_def := target.get("def") as BuildingDef
	if building_def != null:
		var half := building_def.footprint * 0.5
		if half.x > 0.0 and half.y > 0.0:
			return _distance_to_aabb(sim_pos, target_pos, half)
	return sim_pos.distance_to(target_pos)

func _distance_to_aabb(point: Vector2, center: Vector2, half: Vector2) -> float:
	var delta := point - center
	var nearest := center + Vector2(
		clampf(delta.x, -half.x, half.x),
		clampf(delta.y, -half.y, half.y)
	)
	return point.distance_to(nearest)


func _target_collision_radius(target: Node2D) -> float:
	if target == null:
		return CollisionResolverScript.DEFAULT_RADIUS
	if target.get("def") is UnitDef:
		return CollisionResolverScript.unit_radius(target)
	var building_def := target.get("def") as BuildingDef
	if building_def != null:
		return maxf(building_def.footprint.x, building_def.footprint.y) * 0.5
	return CollisionResolverScript.DEFAULT_RADIUS


## Melee: center distance <= weapon reach + both radii. Ranged: center distance <= attack_range.
func _effective_attack_range(target: Node2D) -> float:
	if def.is_ranged:
		return def.attack_range
	var building_def := target.get("def") as BuildingDef
	if building_def != null:
		return def.attack_range + CollisionResolverScript.unit_radius(self)
	return (
		def.attack_range
		+ CollisionResolverScript.unit_radius(self)
		+ _target_collision_radius(target)
	)


func _preferred_attack_range(target: Node2D) -> float:
	if def.is_ranged:
		return def.resolved_preferred_attack_range()
	return _effective_attack_range(target) * 0.92


func _in_attack_range(target: Node2D) -> bool:
	return _distance_to(target) <= _effective_attack_range(target)


func _needs_attack_chase(target: Node2D) -> bool:
	return _distance_to(target) > _effective_attack_range(target) + ATTACK_CHASE_SLACK


func _attack_approach_point(target: Node2D) -> Vector2:
	var target_pos: Vector2 = target.get("sim_pos")
	var offset := sim_pos - target_pos
	var dist := offset.length()
	if dist < 0.001:
		offset = Vector2.RIGHT
		dist = 1.0
	var approach_dir := offset / dist
	if def.is_ranged:
		var standoff := _preferred_attack_range(target)
		if dist > _effective_attack_range(target):
			standoff = minf(standoff, dist)
		else:
			return sim_pos
		return target_pos + approach_dir * standoff
	if target.get("def") is BuildingDef:
		var building_standoff := _effective_attack_range(target) * 0.95
		return target_pos + approach_dir * building_standoff
	# Melee: ring slots so units squeeze around the target instead of one stack point.
	var ring_r := _effective_attack_range(target) * 0.98
	var slot := get_instance_id() % MELEE_ATTACK_SLOTS
	var slot_dir := Vector2.from_angle(TAU * float(slot) / float(MELEE_ATTACK_SLOTS))
	var blended := (approach_dir * 1.6 + slot_dir).normalized()
	return target_pos + blended * ring_r


func _move_resolve_context() -> Dictionary:
	var ctx := {"ignore_units": [], "chase_combat": false}
	if order != Enums.OrderType.ATTACK or not _attack_target_available():
		return ctx
	ctx["ignore_units"] = [_attack_target]
	ctx["chase_combat"] = not def.is_ranged
	return ctx


func _apply_resolved_position(
	from_pos: Vector2, desired_pos: Vector2, move_context: Dictionary = {}
) -> void:
	var units: Array = []
	var buildings: Array = []
	var path_blockers: Array = []
	if is_inside_tree():
		var tree := get_tree()
		units = tree.get_nodes_in_group("units")
		buildings = tree.get_nodes_in_group("buildings")
		path_blockers = tree.get_nodes_in_group("path_blockers")
		for node in tree.get_nodes_in_group("resource_nodes"):
			if node.get("amount") != null and float(node.get("amount")) > 0.0:
				path_blockers.append(node)
	var ignore_units: Array = move_context.get("ignore_units", [])
	var chase_combat: bool = bool(move_context.get("chase_combat", false))
	sim_pos = CollisionResolverScript.resolve_move(
		self,
		from_pos,
		desired_pos,
		units,
		buildings,
		path_blockers,
		ignore_units,
		chase_combat
	)

func _move_toward(target: Vector2, delta: float) -> void:
	_move_target = target
	if _nav_goal.distance_to(target) > 0.75 or (_path.is_empty() and not _path_pending):
		_request_nav_path(target)
		_nav_goal = target
	if _path_pending:
		_refresh_move_debug(_steer_velocity_toward(delta), sim_pos)
		return
	if _path.is_empty():
		_direct_step_toward(target, delta)
		return
	var steer_target := _current_steer_target()
	var offset := steer_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if not _advance_path_waypoint():
			if _villager_actions:
				_update_idle_animation(0.0)
			else:
				_apply_billboard_frame(false)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context())
	_sync_visual()
	_refresh_move_debug(velocity, from_pos)
	_track_move_progress(from_pos, velocity, step, delta, offset)


func _direct_step_toward(target: Vector2, delta: float) -> void:
	var offset := target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if _villager_actions:
			_update_idle_animation(0.0)
		else:
			_apply_billboard_frame(false)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context())
	_sync_visual()
	_refresh_move_debug(velocity, from_pos)
	_track_move_progress(from_pos, velocity, step, delta, offset)


func _track_move_progress(
	from_pos: Vector2, velocity: Vector2, step: float, delta: float, face_vector: Vector2
) -> void:
	var progress := forward_progress(from_pos, sim_pos, velocity)
	var walking := is_walk_progress(progress, step)
	if walking:
		_no_progress_frames = 0
	else:
		_no_progress_frames += 1
		if _no_progress_frames == 3:
			_depack_from_allies()
		if _no_progress_frames >= ATTACK_STUCK_FRAMES:
			if _try_recover_from_stuck():
				return
			_no_progress_frames = 0
	_update_billboard_facing_from_vector(face_vector, delta, walking, walking)


func _get_nav_service() -> Object:
	if not is_inside_tree():
		return null
	var holders := get_tree().get_nodes_in_group("nav_service")
	if holders.is_empty():
		return null
	var holder := holders[0]
	if holder.has_meta("nav"):
		return holder.get_meta("nav")
	return null

func _request_nav_path(target: Vector2) -> void:
	_path = PackedVector2Array()
	_path_index = 0
	_path_pending = false
	var nav := _get_nav_service()
	if nav == null:
		_path = PackedVector2Array([target])
		return
	var radius := _pathfinding_radius()
	# Budgeted queue for many simultaneous movers; apply_nav_path fills result.
	if nav.has_method("enqueue_path"):
		nav.call("enqueue_path", get_instance_id(), sim_pos, target, radius)
		_path_pending = true
		_path = PackedVector2Array()
	elif nav.has_method("find_path"):
		_path = nav.call("find_path", sim_pos, target, radius) as PackedVector2Array


func _pathfinding_radius() -> float:
	return CollisionResolverScript.unit_radius(self)

func apply_nav_path(path: PackedVector2Array) -> void:
	_path_pending = false
	_path_retry_cooldown = 0.0
	if path.is_empty():
		# A* 失败时仍向目标直线移动（靠 CollisionResolver 修正）
		if _move_target != Vector2.ZERO:
			_path = PackedVector2Array([_move_target])
		else:
			_path = PackedVector2Array()
		_path_index = 0
		return
	_path = path
	_path_index = 0


func refresh_nav_path_if_moving() -> void:
	match order:
		Enums.OrderType.MOVE:
			if _move_target != Vector2.ZERO:
				_stuck_repath_attempts = 0
				_request_nav_path(_move_target)
		Enums.OrderType.GATHER, Enums.OrderType.BUILD:
			_path = PackedVector2Array()
			_path_index = 0
			_stuck_repath_attempts = 0
		Enums.OrderType.ATTACK:
			if _move_target != Vector2.ZERO:
				_stuck_repath_attempts = 0
				_request_nav_path(_move_target)


func _try_recover_from_stuck() -> bool:
	if _move_target == Vector2.ZERO:
		return false
	_no_progress_frames = 0
	_depack_from_allies()
	if _path_index + 1 < _path.size():
		_path_index += 1
		return true
	if _stuck_repath_attempts >= MAX_STUCK_REPATH_ATTEMPTS:
		return false
	_stuck_repath_attempts += 1
	_resolve_start_position()
	_request_nav_path(_move_target)
	return true


func _resolve_start_position() -> void:
	var nav := _get_nav_service()
	if nav == null or not nav.has_method("nearest_walkable_world"):
		return
	var radius := _pathfinding_radius()
	if nav.has_method("is_world_walkable_with_radius"):
		if nav.call("is_world_walkable_with_radius", sim_pos, radius):
			return
	var safe: Vector2 = nav.call("nearest_walkable_world", sim_pos, radius)
	if safe.distance_to(sim_pos) > 0.01:
		sim_pos = safe
		_sync_visual()


func _depack_from_allies() -> void:
	if not is_inside_tree():
		return
	var units: Array = get_tree().get_nodes_in_group("units")
	var ignore: Array = []
	if _attack_target_available():
		ignore = [_attack_target]
	var packed: Vector2 = CollisionResolverScript.depack_unit(
		self, units, 4, ignore, true, _move_resolve_context().get("chase_combat", false)
	)
	if packed.distance_to(sim_pos) > 0.01:
		sim_pos = packed
		_sync_visual()


## Remaining waypoints in logical xz for debug draw (empty when idle / no path).
func get_nav_path_debug() -> PackedVector2Array:
	if order != Enums.OrderType.MOVE and order != Enums.OrderType.GATHER and order != Enums.OrderType.BUILD and order != Enums.OrderType.ATTACK:
		return PackedVector2Array()
	if _path.is_empty():
		return PackedVector2Array()
	var points := PackedVector2Array()
	points.append(sim_pos)
	for i in range(_path_index, _path.size()):
		points.append(_path[i])
	if points.size() == 1 and _move_target != Vector2.ZERO:
		points.append(_move_target)
	return points

func _current_steer_target() -> Vector2:
	if _path_index >= 0 and _path_index < _path.size():
		return _path[_path_index]
	return _move_target


func _steer_velocity_toward(delta: float) -> Vector2:
	if def == null:
		return Vector2.ZERO
	var offset := _current_steer_target() - sim_pos
	var distance := offset.length()
	if distance <= 0.0001:
		return Vector2.ZERO
	var step := minf(def.move_speed * delta, distance)
	return offset / distance * step


func _refresh_move_debug(intended_velocity: Vector2, from_pos: Vector2) -> void:
	_debug_steer_velocity = intended_velocity
	_debug_actual_delta = sim_pos - from_pos


func _clear_move_debug() -> void:
	_debug_steer_velocity = Vector2.ZERO
	_debug_actual_delta = Vector2.ZERO


## Debug: steer (cyan) vs actual (red) movement vectors for overlay arrows.
func get_move_debug() -> Dictionary:
	var moving := (
		order == Enums.OrderType.MOVE
		or order == Enums.OrderType.GATHER
		or order == Enums.OrderType.BUILD
		or order == Enums.OrderType.ATTACK
	)
	return {
		"sim_pos": sim_pos,
		"steer": _debug_steer_velocity,
		"actual": _debug_actual_delta,
		"stuck": moving and _no_progress_frames > 0,
		"pending": _path_pending,
	}

func _advance_path_waypoint() -> bool:
	if _path_index + 1 < _path.size():
		_path_index += 1
		return true
	return false

func set_selected(selected: bool) -> void:
	var selection_ring := get_node_or_null("SelectionRing") as CanvasItem
	if selection_ring != null:
		selection_ring.visible = selected

func _sync_visual() -> void:
	IsoMathScript.sync_node(self, sim_pos)

func _setup_presentation() -> void:
	var body := get_node_or_null("Body") as CanvasItem
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	_use_billboard = false
	if billboard != null and def != null:
		var sprite_frames: SpriteFrames = null
		_sprite_metas = {}
		_villager_actions = false
		if def.id == &"villager":
			sprite_frames = SpriteCatalogScript.build_villager_sprite_frames()
			_sprite_metas = SpriteCatalogScript.load_villager_metas_by_action()
			_villager_actions = (
				sprite_frames != null
				and sprite_frames.has_animation(&"walk_dir_0")
			)
		if not _villager_actions:
			var base := SpriteCatalogScript.unit_sheet_base(def.id)
			if SpriteCatalogScript.sheet_paths_exist(base):
				var meta := SpriteCatalogScript.load_meta(base)
				var texture := SpriteCatalogScript.load_texture(base)
				if not meta.is_empty() and texture != null:
					sprite_frames = SpriteCatalogScript.build_unit_sprite_frames(meta, texture)
					_sprite_metas = {&"": meta}
					var combat_metas := SpriteCatalogScript.append_unit_combat_frames(
						sprite_frames, def.id
					)
					for action: StringName in combat_metas:
						_sprite_metas[action] = combat_metas[action]
		if sprite_frames != null and not _sprite_metas.is_empty():
			billboard.sprite_frames = sprite_frames
			SpriteCatalogScript.configure_sprite_2d(
				billboard, SpriteCatalogScript.UNIT_PIXEL_SCALE_2D, Vector2.ZERO
			)
			billboard.visible = true
			_use_billboard = true
			_apply_team_color()
			_update_idle_animation(0.0)
			SpriteCatalogScript.ensure_ground_shadow_2d(self, 14.0)
	if body != null:
		body.visible = not _use_billboard
		if not _use_billboard:
			_apply_team_color()
	if billboard != null and not _use_billboard:
		billboard.visible = false
	if not _use_billboard:
		SpriteCatalogScript.ensure_ground_shadow_2d(self, 14.0)
	_configure_selection_ring()
	_refresh_world_hp_bar()

func _configure_selection_ring() -> void:
	var radius := 0.42
	if def != null:
		radius = def.resolved_footprint_radius()
	SpriteCatalogScript.configure_unit_selection_ring(self, radius)

func _refresh_world_hp_bar() -> void:
	var root := get_node_or_null("WorldHpBar") as Node2D
	if root == null:
		return
	var show_bar := hp > 0.0 and hp < _max_hp
	root.visible = show_bar
	_position_world_hp_bar()
	if not show_bar:
		return
	var fill := root.get_node_or_null("Fill") as ColorRect
	if fill == null:
		return
	var ratio := clampf(hp / maxf(_max_hp, 1.0), 0.0, 1.0)
	fill.size.x = WORLD_HP_BAR_WIDTH * ratio


func _position_world_hp_bar() -> void:
	var root := get_node_or_null("WorldHpBar") as Node2D
	if root == null:
		return
	var top_y := _sprite_top_local_y()
	root.position = Vector2(
		-WORLD_HP_BAR_WIDTH * 0.5,
		top_y - WORLD_HP_BAR_GAP - WORLD_HP_BAR_HEIGHT
	)


func _sprite_top_local_y() -> float:
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if (
		_use_billboard
		and billboard != null
		and billboard.visible
		and billboard.sprite_frames != null
	):
		var anim := billboard.animation
		if billboard.sprite_frames.has_animation(anim):
			var frame_idx := billboard.frame
			var parsed: Dictionary = SpriteCatalogScript.parse_directional_animation(anim)
			var action: StringName = parsed["action"]
			var direction: int = int(parsed["direction"])
			var meta: Dictionary = _sprite_metas.get(action, _sprite_metas.get(&"", {}))
			if not meta.is_empty():
				var frame_h := float(meta.get("frame_h", 1))
				var scale_y := billboard.scale.y
				# Centered billboard: texture top sits above the feet origin.
				return billboard.position.y + (billboard.offset.y - frame_h * 0.5) * scale_y
	var body := get_node_or_null("Body") as Sprite2D
	if body != null and body.visible and body.texture != null:
		return body.position.y - body.texture.get_height() * body.scale.y * 0.5
	return -40.0

func _update_billboard_facing(velocity: Vector2, delta: float, animate: bool) -> void:
	_update_billboard_facing_from_vector(velocity, delta, animate, animate)


func _update_billboard_facing_from_vector(
	dir: Vector2, delta: float, animate: bool, actually_moving: bool = true
) -> void:
	if not _use_billboard:
		return
	var facing: Dictionary = SpriteCatalogScript.quantize_xz_facing(dir)
	_facing_dir = int(facing["dir"])
	_facing_flip = bool(facing["flip"])
	if animate:
		_anim_frame = fmod(_anim_frame + ANIM_FPS * delta, 1024.0)
	_apply_billboard_frame(animate, &"", actually_moving)


## How far `to_pos` advanced along `intended` from `from_pos` (world units).
static func forward_progress(from_pos: Vector2, to_pos: Vector2, intended: Vector2) -> float:
	var actual := to_pos - from_pos
	var intended_len_sq := intended.length_squared()
	if intended_len_sq < 0.000001:
		return 0.0
	return actual.dot(intended / sqrt(intended_len_sq))


static func is_walk_progress(progress: float, intended_step_len: float) -> bool:
	return progress >= maxf(MIN_WALK_PROGRESS, intended_step_len * 0.35)


func _face_toward(target: Vector2, delta: float, animate: bool) -> void:
	_update_billboard_facing_from_vector(target - sim_pos, delta, animate)


func _update_idle_animation(delta: float) -> void:
	if not _use_billboard:
		return
	if _villager_actions:
		if delta > 0.0:
			_anim_frame = fmod(_anim_frame + ANIM_FPS * delta, 1024.0)
		_apply_billboard_frame(true, &"", false)
	else:
		_apply_billboard_frame(false)


func _resolve_visual_action() -> StringName:
	match order:
		Enums.OrderType.NONE:
			return &"idle"
		Enums.OrderType.MOVE:
			return &"walk"
		Enums.OrderType.GATHER:
			if _gather_state == "gathering":
				var resource_type := carry_type
				if resource_type == -1 and is_instance_valid(_gather_target):
					resource_type = int(_gather_target.get("resource_type"))
				match resource_type:
					Enums.ResourceType.FOOD:
						return &"gather_food"
					Enums.ResourceType.WOOD:
						return &"chop"
					Enums.ResourceType.GOLD:
						return &"mine"
					_:
						return &"gather_food"
			return &"walk"
		Enums.OrderType.BUILD:
			if _is_in_build_range():
				return &"build"
			return &"walk"
		Enums.OrderType.ATTACK:
			return &"attack"
		_:
			return &"idle"


func _is_in_build_range() -> bool:
	if not is_instance_valid(_build_target):
		return false
	var build_range := 1.0
	var building_def := _build_target.get("def") as BuildingDef
	if building_def != null:
		build_range += maxf(
			building_def.footprint.x, building_def.footprint.y
		) * 0.5
	return _distance_to(_build_target) <= build_range


func _pick_villager_animation(action: StringName) -> StringName:
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard == null or billboard.sprite_frames == null:
		return &"walk_dir_0"
	var resolved := action
	if action == &"attack" and not billboard.sprite_frames.has_animation(&"attack_dir_0"):
		resolved = &"chop"
	var anim := StringName("%s_dir_%d" % [resolved, _facing_dir])
	if billboard.sprite_frames.has_animation(anim):
		return anim
	var action_dir0 := StringName("%s_dir_0" % resolved)
	if not String(resolved).is_empty() and billboard.sprite_frames.has_animation(action_dir0):
		return action_dir0
	if action == &"idle":
		for direction in 5:
			var idle_anim := StringName("idle_dir_%d" % direction)
			if billboard.sprite_frames.has_animation(idle_anim):
				return idle_anim
	if billboard.sprite_frames.has_animation(&"walk_dir_0"):
		return &"walk_dir_0"
	return &"dir_0"


func _apply_billboard_frame(
	animate: bool, forced_action: StringName = &"", actually_moving: bool = true
) -> void:
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard == null or billboard.sprite_frames == null:
		return
	var anim: StringName
	var action := forced_action
	if action.is_empty() and not _combat_action.is_empty():
		action = _combat_action
	if _villager_actions:
		if action.is_empty():
			action = _resolve_visual_action()
		if not actually_moving and action == &"walk":
			action = &"idle"
		anim = _pick_villager_animation(action)
	else:
		if action.is_empty():
			anim = StringName("dir_%d" % _facing_dir)
		else:
			anim = StringName("%s_dir_%d" % [action, _facing_dir])
			if not billboard.sprite_frames.has_animation(anim):
				if action == &"attack":
					anim = StringName("walk_dir_%d" % _facing_dir)
				if not billboard.sprite_frames.has_animation(anim):
					anim = StringName("dir_%d" % _facing_dir)
		if not billboard.sprite_frames.has_animation(anim):
			return
	billboard.flip_h = _facing_flip
	if billboard.animation != anim:
		billboard.animation = anim
	var frame_count := billboard.sprite_frames.get_frame_count(anim)
	if frame_count <= 0:
		return
	var one_shot := action in [&"attack", &"die"]
	var frame_idx := 0
	if one_shot:
		frame_idx = mini(int(_combat_anim_time * ANIM_FPS), frame_count - 1)
	elif animate:
		frame_idx = int(_anim_frame) % frame_count
	billboard.frame = frame_idx
	_apply_billboard_hotspot(billboard, anim, frame_idx)
	if hp > 0.0 and hp < _max_hp:
		_position_world_hp_bar()


func _apply_billboard_hotspot(
	billboard: AnimatedSprite2D, anim: StringName, frame_idx: int
) -> void:
	var parsed: Dictionary = SpriteCatalogScript.parse_directional_animation(anim)
	var action: StringName = parsed["action"]
	var direction: int = int(parsed["direction"])
	var meta: Dictionary = _sprite_metas.get(action, _sprite_metas.get(&"", {}))
	if meta.is_empty():
		return
	var offset := SpriteCatalogScript.offset_for_frame_2d(
		meta, direction, frame_idx, _facing_flip
	)
	if not billboard.offset.is_equal_approx(offset):
		billboard.offset = offset


func _apply_team_color() -> void:
	var body := get_node_or_null("Body") as CanvasItem
	if body != null and body.visible:
		body.modulate = PLAYER_COLOR if team == Enums.Team.PLAYER else AI_COLOR
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard != null and _use_billboard:
		billboard.modulate = (
			PLAYER_BILLBOARD_TINT if team == Enums.Team.PLAYER else AI_BILLBOARD_TINT
		)

func _exit_tree() -> void:
	if _population_registered and match_state != null and def != null:
		match_state.register_pop(team, -def.population, 0)
		_population_registered = false
