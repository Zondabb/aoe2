class_name UnitAgent
extends Node2D

## Presentation hooks: listeners never participate in the simulation.
signal audio_cue(event: StringName)
signal damaged(entity: Node)

const FogAccess := preload("res://scripts/systems/fog_access.gd")
const UnitOcclusion := preload("res://scripts/presentation/unit_occlusion.gd")

const ARRIVAL_DISTANCE := 0.15
const STUCK_REPATH_SECONDS := 0.65
const REPATH_INTERVAL := 0.8
## Crowd repath: query radius and forward cone for temporary unit obstacles.
const STUCK_CROWD_QUERY_RADIUS := 6.0
const STUCK_CROWD_BLOCK_ANGLE_DEG := 60.0
const PATH_RETRY_COOLDOWN := 0.3
## Soft-sep / wall-slide only counts as walking with enough forward progress.
const MIN_WALK_PROGRESS := 0.012
const GATHER_RANGE := 1.2
## Extra slack past 2× footprint so a second villager can gather a center-targeted
## resource (berries) without standing on the same point as the first.
const GATHER_CENTER_RANGE_SLACK := 0.4
## Set true to print drop-off diagnostics (search console for "[drop-off]").
const DEBUG_DROP_OFF := true
const DEBUG_DROP_OFF_INTERVAL := 0.5
const ANIM_FPS := 18.0
const ATTACK_HIT_FRACTION := 0.45
const RANGED_RELEASE_FRACTION := 0.35
const ATTACK_CHASE_SLACK := 0.25
const MELEE_ATTACK_SLOTS := 12
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
const TeamColorCatalogScript := preload("res://scripts/presentation/team_color_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const Avoidance := preload("res://scripts/systems/local_avoidance.gd")
const UnitDebugFocusScript := preload("res://scripts/debug/unit_debug_focus.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: UnitDef
@export var civ: CivDef
## >= 0 overrides UnitDef.vision_radius for this instance.
@export var vision_radius_override: float = -1.0

var hp := 0.0
var melee_armor := 0.0
var pierce_armor := 0.0
var order: Enums.OrderType = Enums.OrderType.NONE
var sim_pos := Vector2.ZERO
## CanvasItem exposes the physics transform, not the server's interpolated
## draw transform. The outline mask needs the same translation as the actor.
var previous_physics_position := Vector2.ZERO
var carry_type := -1
var carry_amount := 0.0
@export var carry_capacity := 10.0
var match_state: MatchState
var _move_target := Vector2.ZERO
var _formation_move_speed := 0.0
var _gather_target: Node2D
var _last_resource: Node2D
var _drop_off_target: Node2D
var _build_target: Node2D
var _last_seen_resource_pos := Vector2.ZERO
var _last_seen_attack_pos := Vector2.ZERO
var _attack_target: Node2D
var _attack_cooldown_remaining := 0.0
var _gather_state := ""
var _gather_resource_type := -1
var _gather_source_depleted := false
var _gather_candidates: Array[WeakRef] = []
var _gather_work_points := PackedVector2Array()
var _automatic_gather_target := false
var _automatic_gather_goal := Vector2.ZERO
var _automatic_gather_resource_pos := Vector2.ZERO
var _population_registered := false
var _use_billboard := false
var _villager_actions := false
var _facing_dir := 0
var _facing_flip := false
var _anim_frame := 0.0
var _sprite_metas: Dictionary = {}
var _player_color_sheet := ""
var _player_color_id := -1
var _player_color_animation := &""
var _player_color_unit_id := &""
var _hotspot_animation := &""
var _hotspot_frame := -1
var _hotspot_flip := false
var _hotspot_offset := Vector2.ZERO
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
var _locomotion_velocity := Vector2.ZERO
var _avoidance_cache := {}
var _stuck_seconds := 0.0
var _repath_cooldown := 0.0
var _requested_move_target := Vector2.ZERO
var _progress_elapsed := 0.0
var _progress_distance := INF
var _pending_crowd_route := false
var _path_is_crowd_route := false
var _has_move_command := false
var _goal_refresh_remaining := 0.0
var _drop_off_debug_timer := 0.0
var _debug_steer_velocity := Vector2.ZERO
var _debug_actual_delta := Vector2.ZERO
var _build_queue: Array[WeakRef] = []

func command_build_queue(buildings: Array, append := false) -> void:
	if not append: _build_queue.clear()
	for building in buildings:
		if is_instance_valid(building) and building.get("team") == team and not bool(building.get("is_complete")):
			_build_queue.append(weakref(building))
	if append and order == Enums.OrderType.BUILD and is_instance_valid(_build_target): return
	_advance_build_queue()

func get_build_queue_ids() -> Array:
	var ids: Array = []
	for reference in _build_queue:
		var building: Variant = reference.get_ref()
		if is_instance_valid(building) and not building.is_queued_for_deletion() and not building.is_complete:
			ids.append(EntityRegistryScript.id_of(building))
	return ids

func _advance_build_queue() -> bool:
	while not _build_queue.is_empty():
		var building: Variant = _build_queue.pop_front().get_ref()
		if is_instance_valid(building) and not building.is_queued_for_deletion() and building.get("team") == team and not bool(building.get("is_complete")):
			command_build(building, true)
			return true
	return false

func _ready() -> void:
	if match_state != null and not match_state.team_color_changed.is_connected(_on_team_color_changed):
		match_state.team_color_changed.connect(_on_team_color_changed)
	add_to_group("units")
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	_sync_visual()
	previous_physics_position = position
	hp = float(def.max_hp) if def != null else 0.0
	_max_hp = hp
	melee_armor = float(def.melee_armor) if def != null else 0.0
	pierce_armor = float(def.pierce_armor) if def != null else 0.0
	if def != null and civ != null and not def.is_ranged:
		melee_armor += civ.melee_armor_bonus
	register_population()
	_setup_presentation()
	UnitOcclusion.ensure_for(self)
	set_selected(false)
	_vision_register()
	# Spawn snapshots must contain initialized position, health and armor.
	EntityRegistryScript.register(self)
	# Units enter the tree at their simulation position, never interpolate from
	# the scene's authored origin. Remote snapshots have their own update clock.
	if has_meta("network_replica"):
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	reset_physics_interpolation()


func register_population() -> void:
	if has_meta("network_replica"):
		return
	if match_state != null and def != null and not _population_registered:
		match_state.register_pop(team, def.population, 0)
		_population_registered = true


func resolved_vision_radius() -> float:
	if vision_radius_override >= 0.0:
		return vision_radius_override
	if def != null:
		var age := match_state.age_of(team) if match_state != null and match_state.progression_enabled else Enums.Age.DARK
		return def.resolved_vision_radius(age)
	return 8.0


func set_vision_radius(radius: float) -> void:
	if match_state != null and match_state.fog != null:
		match_state.fog.dirty = true
	vision_radius_override = maxf(0.0, radius)

func _physics_process(delta: float) -> void:
	# Even a frozen or idle tick advances interpolation history to its current
	# position, so the mask cannot keep replaying the last moving step.
	previous_physics_position = position
	if has_meta("network_replica"):
		return
	if def == null:
		return
	if match_state != null and match_state.frozen:
		return
	var frame_start := sim_pos
	_attack_cooldown_remaining = maxf(0.0, _attack_cooldown_remaining - delta)
	_repath_cooldown = maxf(0, _repath_cooldown - delta)
	_goal_refresh_remaining = maxf(0, _goal_refresh_remaining - delta)
	_path_retry_cooldown = maxf(0, _path_retry_cooldown - delta)
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
	_locomotion_velocity = (sim_pos - frame_start) / maxf(delta, 0.00001)
	if order == Enums.OrderType.MOVE:
		_progress_elapsed += delta
		if _progress_elapsed >= 2.0:
			var distance := sim_pos.distance_to(_move_target)
			if distance >= _progress_distance - 0.5:
				_try_recover_from_stuck()
			_progress_distance = distance
			_progress_elapsed = 0.0

func locomotion_velocity() -> Vector2:
	return _locomotion_velocity


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESET_PHYSICS_INTERPOLATION:
		previous_physics_position = position


func render_canvas_transform(source: Node2D) -> Transform2D:
	var result := source.get_global_transform_with_canvas()
	if not is_physics_interpolated_and_enabled() or source.is_set_as_top_level():
		return result
	# Unit simulation changes translation only. Billboard scale/rotation and
	# hotspot offsets stay local to that translation. Transform the difference
	# through the parent basis and canvas camera, preserving pan/zoom/stretch.
	var delta := previous_physics_position.lerp(position, Engine.get_physics_interpolation_fraction()) - position
	if not is_set_as_top_level() and get_parent() is CanvasItem:
		delta = (get_parent() as CanvasItem).get_global_transform().basis_xform(delta)
	result.origin += get_canvas_transform().basis_xform(delta)
	return result

func _process_move(delta: float) -> void:
	_refresh_reserved_goal()
	var from_pos := sim_pos
	if sim_pos.distance_to(_move_target) <= ARRIVAL_DISTANCE:
		_finish_move()
		return
	if _path_pending and _path.is_empty():
		var steer := _steer_velocity_toward(delta)
		if steer.length_squared() > 0.0001:
			_update_move_facing(steer, delta, false)
		_refresh_move_debug(steer, from_pos)
		return
	if _path.is_empty():
		if _path_retry_cooldown > 0.0:
			var wait_dir := _move_target - sim_pos
			if wait_dir.length_squared() > 0.0001:
				_update_move_facing(wait_dir, delta, false)
			_refresh_move_debug(Vector2.ZERO, from_pos)
			return
		_path_retry_cooldown = PATH_RETRY_COOLDOWN
		_request_nav_path(_move_target)
		_refresh_move_debug(_steer_velocity_toward(delta), from_pos)
		return
	_skip_visible_waypoints()
	var steer_target := _current_steer_target()
	var offset := steer_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if _advance_path_waypoint():
			return
		# A temporary crowd detour may end at a nearby free cell, not our goal.
		_request_nav_path(_move_target)
		return
	var step := minf(_movement_speed() * delta, distance)
	var velocity := offset.normalized() * step
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context(), delta)
	_sync_visual()
	_refresh_move_debug(velocity, from_pos)
	_track_move_progress(from_pos, velocity, step, delta, offset)

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
	if hp <= 0.0 or is_queued_for_deletion():
		return
	_build_queue.clear()
	_formation_move_speed = 0.0
	if order == Enums.OrderType.MOVE and _requested_move_target.is_equal_approx(target):
		return
	_cancel_gather_search()
	_cancel_combat_action()
	_requested_move_target = target
	_has_move_command = true
	_move_target = _choose_move_goal(target)
	_nav_goal = _move_target
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	_no_progress_frames = 0
	_stuck_repath_attempts = 0
	_stuck_seconds = 0
	_repath_cooldown = 0
	_progress_distance = sim_pos.distance_to(_move_target)
	_progress_elapsed = 0
	_goal_refresh_remaining = 0
	_request_nav_path(_move_target)
	order = Enums.OrderType.MOVE
	_unit_log("order", "MOVE target=%s" % target)

func set_formation_move_speed(speed: float) -> void:
	if def != null and is_finite(speed):
		_formation_move_speed = clampf(speed, 0.0, def.move_speed)

func _movement_speed() -> float:
	if order == Enums.OrderType.MOVE and _formation_move_speed > 0.0:
		return minf(def.move_speed, _formation_move_speed)
	return def.move_speed

func command_stop() -> void:
	if hp <= 0.0 or is_queued_for_deletion():
		return
	_build_queue.clear()
	_cancel_gather_search()
	_cancel_combat_action()
	_has_move_command = false
	var nav := _get_nav_service()
	if nav != null and nav.has_method("cancel_path"):
		nav.cancel_path(get_instance_id())
	_locomotion_velocity = Vector2.ZERO
	_stuck_seconds = 0
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
	_unit_log("order", "STOP")

func command_gather(resource: Node2D) -> void:
	if hp <= 0.0 or is_queued_for_deletion():
		return
	if not FogAccess.can_see(self, resource):
		return
	if not is_instance_valid(resource) or resource.is_queued_for_deletion() or float(resource.get("amount")) <= 0.0:
		return
	_build_queue.clear()
	_cancel_gather_search()
	_cancel_combat_action()
	_has_move_command = false
	_build_target = null
	_attack_target = null
	var new_type := int(resource.get("resource_type"))
	_gather_resource_type = new_type
	_gather_source_depleted = false
	_last_seen_resource_pos = resource.get("sim_pos")
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
	_unit_log("order", "GATHER resource=%s" % resource.name)

func command_build(building: Node2D, preserve_queue := false) -> void:
	if hp <= 0.0 or is_queued_for_deletion():
		return
	if (
		building == null
		or bool(building.get("is_complete"))
		or def == null
		or def.id != &"villager"
	):
		return
	if not preserve_queue: _build_queue.clear()
	_cancel_gather_search()
	_cancel_combat_action()
	_build_target = building
	_has_move_command = false
	_attack_target = null
	_gather_target = null
	_drop_off_target = null
	_gather_state = ""
	order = Enums.OrderType.BUILD
	_unit_log("order", "BUILD target=%s" % building.name)

func command_attack(target: Node) -> void:
	if hp <= 0.0 or is_queued_for_deletion():
		return
	if def != null and def.attack <= 0: return
	if not FogAccess.can_see(self, target):
		return
	var target_2d := target as Node2D
	if (
		target_2d == null
		or not is_instance_valid(target_2d)
		or target_2d.get("team") == team
		or target_2d.get("is_placement_ghost") == true
		or not target_2d.has_method("take_damage")
	):
		return
	_cancel_gather_search()
	_build_queue.clear()
	_last_seen_attack_pos = target_2d.get("sim_pos")
	if _attack_target != target_2d:
		_cancel_combat_action()
	_has_move_command = false
	_attack_target = target_2d
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_gather_state = ""
	order = Enums.OrderType.ATTACK
	_unit_log("order", "ATTACK target=%s" % target_2d.name)

func _process_attack(delta: float) -> void:
	if _combat_action == &"die":
		_process_die(delta)
		return
	# Freed references fail typed Object arguments before the callee can guard them.
	if not is_instance_valid(_attack_target) or _attack_target.is_queued_for_deletion():
		_cancel_combat_action()
		_attack_target = null
		order = Enums.OrderType.NONE
		return
	if match_state != null and match_state.fog_enabled and not FogAccess.can_see(self, _attack_target):
		_cancel_combat_action()
		command_move(_last_seen_attack_pos)
		return
	_last_seen_attack_pos = _attack_target.get("sim_pos")
	if not _attack_target_available():
		_cancel_combat_action()
		_attack_target = null
		order = Enums.OrderType.NONE
		return
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
	_avoidance_cache.clear()
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
		var release_time := def.attack_release_delay if def.attack_release_delay >= 0.0 else duration * RANGED_RELEASE_FRACTION
		if not _projectile_spawned and _combat_anim_time >= release_time:
			if _in_attack_range(_attack_target):
				_spawn_projectile()
				audio_cue.emit(&"arrow")
				_projectile_spawned = true
	elif not _attack_hit_applied:
		if _combat_anim_time >= duration * ATTACK_HIT_FRACTION:
			if _attack_target_available():
				CombatSystemScript.apply_hit(def, _attack_target, {"attacker": self})
				audio_cue.emit(&"melee")
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
	# Vertical launch height belongs to presentation, never to the ground ray.
	var origin := sim_pos
	var aim := ProjectileAgentScript.aim_point_for_target(origin, _attack_target)
	projectile.call("setup", origin, aim, def, team, self)

func _process_die(delta: float) -> void:
	var duration := _combat_anim_duration(&"die")
	_combat_anim_time += delta
	_apply_billboard_frame(true, &"die", false)
	if _combat_anim_time >= duration:
		queue_free()

func _begin_die() -> void:
	audio_cue.emit(&"death")
	_cancel_gather_search()
	if match_state != null and match_state.fog != null:
		match_state.fog.dirty = true
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
	return maxf(float(frame_count) / _animation_fps(action), 0.1)


func _animation_fps(action: StringName) -> float:
	var meta: Dictionary = _sprite_metas.get(action, _sprite_metas.get(&"", {}) if action == &"walk" else {})
	var frame_duration := float(meta.get("frame_duration", 0.0))
	if action == &"attack" and def != null:
		var profiles: Dictionary = GameCatalog.siege_projectiles() if def.projectile_kind == &"stone" else GameCatalog.arrow_projectiles().get("units", {})
		var profile: Dictionary = profiles.get(String(def.id), {})
		frame_duration = float(profile.get("attack_frame_duration", frame_duration))
	return 1.0 / frame_duration if frame_duration > 0.0 else ANIM_FPS

func _combat_animation_name(action: StringName) -> StringName:
	if _villager_actions:
		return _pick_villager_animation(action)
	return StringName("%s_dir_%d" % [action, _facing_dir])

func take_damage(amount: float, source: Node = null) -> void:
	if amount <= 0.0 or hp <= 0.0 or _combat_action == &"die":
		return
	hp = maxf(0.0, hp - amount)
	damaged.emit(self)
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
		and FogAccess.can_see(self, _attack_target)
		and not _attack_target.is_queued_for_deletion()
		and float(_attack_target.get("hp")) > 0.0
		and _attack_target.get("team") != team
	)

func _process_build(delta: float) -> void:
	if not is_instance_valid(_build_target) or bool(_build_target.get("is_complete")):
		_finish_build_order()
		return
	if _distance_to(_build_target) > _building_interaction_range(_build_target):
		_move_toward(_build_approach_point(_build_target), delta)
		return
	_face_toward(_build_target.get("sim_pos"), delta, true)
	_build_target.call("add_build_progress", delta)
	if bool(_build_target.get("is_complete")):
		_finish_build_order()

func _finish_build_order() -> void:
	var completed := _build_target
	_build_target = null
	order = Enums.OrderType.NONE
	if _advance_build_queue(): return
	if not is_instance_valid(completed) or completed.is_queued_for_deletion():
		return
	var building_def := completed.get("def") as BuildingDef
	if building_def != null and building_def.id == &"farm" and bool(completed.get("is_complete")) and completed.get("team") == team and completed.has_method("extract"):
		command_gather(completed)

func _process_gather(delta: float) -> void:
	if _gather_state == "searching_resource":
		_update_idle_animation(delta)
		return
	if _gather_state in ["to_resource", "gathering"] and (not is_instance_valid(_gather_target) or _gather_target.is_queued_for_deletion()):
		_gather_target = null
		_finish_or_drop_off()
		return
	if _gather_state in ["to_resource", "gathering"] and match_state != null and match_state.fog_enabled and not FogAccess.can_see(self, _gather_target):
		# Returning through fog is still part of the gather order. A MOVE command
		# clears the resource target and leaves the worker idle after one delivery.
		# Use only the remembered location until sight returns, never hidden stock.
		_gather_state = "to_resource"
		_move_toward(_automatic_gather_goal if _automatic_gather_target else _last_seen_resource_pos, delta)
		return
	match _gather_state:
		"to_resource":
			if not _resource_available(_gather_target):
				_finish_or_drop_off()
			elif _gather_reach_distance(_gather_target) <= _gather_interaction_range(_gather_target):
				_gather_state = "gathering"
				_unit_log("gather", "reached resource, gathering")
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
	if _gather_reach_distance(_gather_target) > _gather_interaction_range(_gather_target):
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
	if not _resource_available(_gather_target):
		_finish_or_drop_off()
	elif carry_amount >= carry_capacity:
		_begin_drop_off()

func _begin_drop_off() -> void:
	if carry_amount <= 0.0:
		order = Enums.OrderType.NONE
		return
	_drop_off_target = GatherSystemScript.nearest_drop_off(self, carry_type)
	if _drop_off_target == null:
		_drop_off_log("no drop-off building found", {"carry_type": carry_type})
		order = Enums.OrderType.NONE
		return
	_clear_gather_path()
	_gather_state = "to_drop_off"
	_drop_off_log(
		"begin",
		{
			"target": _drop_off_target.name,
			"tc_pos": _drop_off_target.get("sim_pos"),
			"carry": carry_amount,
		}
	)

func _process_drop_off(delta: float) -> void:
	if DEBUG_DROP_OFF:
		_drop_off_debug_timer = maxf(0.0, _drop_off_debug_timer - delta)
	if not is_instance_valid(_drop_off_target):
		_drop_off_log("target invalid, re-querying")
		_begin_drop_off()
		return
	var approach := _build_approach_point(_drop_off_target)
	var interact_range := _building_interaction_range(_drop_off_target)
	var edge_dist := _distance_to(_drop_off_target)
	if edge_dist > interact_range:
		_drop_off_log_throttled(
			"approaching",
			{
				"edge_dist": edge_dist,
				"need": interact_range,
				"approach": approach,
				"path_len": _path.size(),
				"path_idx": _path_index,
				"pending": _path_pending,
				"stuck_frames": _no_progress_frames,
			}
		)
		_move_toward(approach, delta)
		return
	_drop_off_log(
		"deposit",
		{"edge_dist": edge_dist, "amount": carry_amount, "type": carry_type}
	)
	if match_state != null:
		match_state.add_resource(team, carry_type, int(round(carry_amount)))
	carry_amount = 0.0
	carry_type = -1
	_drop_off_target = null
	if not _gather_source_depleted and is_instance_valid(_last_resource) and not _last_resource.is_queued_for_deletion() and not FogAccess.can_see(self, _last_resource):
		_gather_target = _last_resource
		_gather_state = "to_resource"
		_clear_gather_path()
	elif not _gather_source_depleted and _resource_available(_last_resource):
		_gather_target = _last_resource
		_gather_state = "to_resource"
		_clear_gather_path()
	else:
		_finish_or_drop_off()

func _finish_or_drop_off() -> void:
	_gather_source_depleted = true
	# Remember the next visible source before leaving the work site. Otherwise
	# the forest may be entirely hidden when a full worker reaches its drop-off.
	if _start_gather_search():
		return
	elif carry_amount > 0.0:
		_begin_drop_off()
	else:
		_cancel_gather_search()
		_gather_target = null
		_last_resource = null
		order = Enums.OrderType.NONE
		_gather_state = ""
		_update_idle_animation(0.0)


func _cancel_gather_search() -> void:
	if order == Enums.OrderType.GATHER:
		_clear_gather_path()
	_gather_candidates.clear()
	_gather_work_points.clear()
	_automatic_gather_target = false
	_gather_resource_type = -1
	_gather_source_depleted = false


func _clear_gather_path() -> void:
	var nav := _get_nav_service()
	if nav != null and nav.has_method("cancel_path"):
		nav.cancel_path(get_instance_id())
	_path.clear()
	_path_index = 0
	_path_pending = false
	_pending_crowd_route = false
	_path_is_crowd_route = false
	_path_retry_cooldown = 0.0
	_stuck_seconds = 0.0
	_no_progress_frames = 0
	_stuck_repath_attempts = 0
	_repath_cooldown = 0.0


func _start_gather_search() -> bool:
	_clear_gather_path()
	_gather_target = null
	_automatic_gather_target = false
	_gather_work_points.clear()
	if _gather_resource_type < 0:
		return false
	_gather_candidates = GatherSystemScript.resource_candidates(self, _gather_resource_type, _last_seen_resource_pos)
	return _queue_next_gather_resource()


func _queue_next_gather_resource() -> bool:
	var nav := _get_nav_service()
	while not _gather_candidates.is_empty():
		var reference: WeakRef = _gather_candidates.pop_front()
		var resource := reference.get_ref() as Node2D
		if not GatherSystemScript.resource_usable(self, resource, _gather_resource_type):
			continue
		_gather_target = resource
		var actual_point := GatherSystemScript.work_point(resource, sim_pos, _pathfinding_radius())
		var center: Vector2 = resource.get("sim_pos")
		var reach := GATHER_RANGE if actual_point != center else maxf(GATHER_RANGE, _pathfinding_radius() * 2.0 + GATHER_CENTER_RANGE_SLACK)
		_gather_work_points = GatherSystemScript.work_points(resource, sim_pos, _pathfinding_radius(), nav, reach)
		if _gather_work_points.is_empty():
			continue
		_last_resource = resource
		_gather_source_depleted = false
		_automatic_gather_target = true
		_automatic_gather_resource_pos = center
		if nav == null:
			_automatic_gather_goal = _gather_work_points[0]
			_gather_work_points.clear()
			_last_seen_resource_pos = center
			_gather_state = "to_resource"
			if carry_amount >= carry_capacity and carry_amount > 0.0:
				_begin_drop_off()
			return true
		return _queue_gather_work_point()
	_gather_target = null
	return false


func _queue_gather_work_point() -> bool:
	if _gather_work_points.is_empty():
		return _queue_next_gather_resource()
	_automatic_gather_goal = _gather_work_points[0]
	_gather_work_points.remove_at(0)
	_move_target = _automatic_gather_goal
	_nav_goal = _automatic_gather_goal
	_gather_state = "searching_resource"
	_request_nav_path(_automatic_gather_goal)
	return true


func _apply_gather_search_path(path: PackedVector2Array) -> void:
	if not is_instance_valid(_gather_target) or _gather_target.is_queued_for_deletion() or (FogAccess.can_see(self, _gather_target) and not _resource_available(_gather_target)):
		_gather_work_points.clear()
		path = PackedVector2Array()
	if path.is_empty() or path[-1].distance_to(_automatic_gather_goal) > GATHER_RANGE:
		if not _queue_gather_work_point():
			_gather_source_depleted = true
			if carry_amount > 0.0:
				_begin_drop_off()
			else:
				_cancel_gather_search()
				order = Enums.OrderType.NONE
				_gather_state = ""
		return
	_last_seen_resource_pos = _automatic_gather_resource_pos
	_gather_state = "to_resource"
	_path = path
	_path_index = 0
	if carry_amount >= carry_capacity and carry_amount > 0.0:
		_begin_drop_off()

func _resource_available(resource: Variant) -> bool:
	# May receive a cached resource that was freed during the drop-off trip.
	return is_instance_valid(resource) and not resource.is_queued_for_deletion() and float(resource.get("amount")) > 0.0


func _gather_approach_point(resource: Node2D) -> Vector2:
	if _automatic_gather_target and resource == _gather_target:
		return _automatic_gather_goal
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
		return sim_pos.distance_to(GatherSystemScript.work_point(resource, sim_pos, _pathfinding_radius()))
	return sim_pos.distance_to(resource.get("sim_pos"))


## In-range threshold for starting/staying in gathering.
## Center-targeted nodes (food) expand to ~2× unit radius so crowded gatherers still count.
func _gather_interaction_range(resource: Node2D) -> float:
	if resource == null:
		return GATHER_RANGE
	var center_variant: Variant = resource.get("sim_pos")
	if not (center_variant is Vector2):
		return GATHER_RANGE
	var approach := GatherSystemScript.work_point(resource, sim_pos, _pathfinding_radius())
	if approach.distance_squared_to(center_variant as Vector2) > 0.0001:
		return GATHER_RANGE
	return maxf(GATHER_RANGE, _pathfinding_radius() * 2.0 + GATHER_CENTER_RANGE_SLACK)


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

## Same reach band as construction: nav often stops short of the approach point.
func _building_interaction_range(building: Node2D) -> float:
	var building_def := building.get("def") as BuildingDef if building != null else null
	if building_def == null:
		return GATHER_RANGE
	return 1.0 + maxf(building_def.footprint.x, building_def.footprint.y) * 0.5

func _drop_off_log(message: String, details: Dictionary = {}) -> void:
	if not DEBUG_DROP_OFF:
		return
	_unit_log("drop-off", message, details)


func _unit_log(channel: String, message: String, details: Dictionary = {}) -> void:
	UnitDebugFocusScript.log(self, channel, message, details)

func _drop_off_log_throttled(message: String, details: Dictionary = {}) -> void:
	if not DEBUG_DROP_OFF or _drop_off_debug_timer > 0.0:
		return
	_drop_off_debug_timer = DEBUG_DROP_OFF_INTERVAL
	_drop_off_log(message, details)

func _distance_to(target: Node2D) -> float:
	var target_pos: Vector2 = target.get("sim_pos")
	var building_def := target.get("def") as BuildingDef
	if building_def != null:
		var footprint: Vector2 = target.get_placement_footprint() if target.has_method("get_placement_footprint") else building_def.footprint
		var half := footprint * 0.5
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
	var distance := _distance_to(target)
	return distance >= def.minimum_attack_range and distance <= _effective_attack_range(target)


func _needs_attack_chase(target: Node2D) -> bool:
	if def.is_ranged or def.minimum_attack_range > 0.0:
		return not _in_attack_range(target)
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
		if _distance_to(target) < def.minimum_attack_range:
			standoff = minf(def.attack_range, def.minimum_attack_range + 1.0)
		elif _distance_to(target) > _effective_attack_range(target):
			standoff = minf(standoff, dist)
		else:
			return sim_pos
		var target_edge := ProjectileAgentScript.aim_point_for_target(sim_pos, target)
		return target_edge + approach_dir * standoff
	if target.get("def") is BuildingDef:
		var building_standoff := _effective_attack_range(target) * 0.95
		# Aim for the near edge. A goal inside the solid footprint may project
		# to the far side of a wall, producing an unreachable route indefinitely.
		var target_edge := ProjectileAgentScript.aim_point_for_target(sim_pos, target)
		var edge_direction := (sim_pos - target_edge).normalized()
		return target_edge + (edge_direction if edge_direction != Vector2.ZERO else approach_dir) * building_standoff
	# Melee: ring slots so units squeeze around the target instead of one stack point.
	var ring_r := _effective_attack_range(target) * 0.98
	var slot := get_instance_id() % MELEE_ATTACK_SLOTS
	var slot_dir := Vector2.from_angle(TAU * float(slot) / float(MELEE_ATTACK_SLOTS))
	var blended := (approach_dir * 1.6 + slot_dir).normalized()
	return target_pos + blended * ring_r


func _move_resolve_context() -> Dictionary:
	# Combat range already includes both radii; targets remain physical obstacles.
	return {}


func _apply_resolved_position(from_pos: Vector2, desired_pos: Vector2, _move_context: Dictionary = {}, delta := 1.0 / 60.0) -> void:
	var units: Array = []
	var solids: Array = []
	var query_radius := maxf(Avoidance.NEIGHBOR_RANGE, 2.0 * (_pathfinding_radius() + def.move_speed * (Avoidance.HORIZON + delta)))
	if is_inside_tree():
		var vision := _get_vision_service()
		if vision != null and vision.has_method("units_in_radius"):
			units = vision.units_in_radius(self, query_radius)
		elif vision != null and vision.has_method("others_in_radius"):
			for other in vision.others_in_radius(self, query_radius):
				if other.get("def") is UnitDef:
					units.append(other)
		else:
			for other in get_tree().get_nodes_in_group("units"):
				if other != self and sim_pos.distance_squared_to(other.sim_pos) < query_radius * query_radius:
					units.append(other)
		var nav_holder := get_tree().get_first_node_in_group("nav_service")
		if nav_holder != null and nav_holder.has_method("query_static_blockers"):
			# Include the complete prediction circle: avoidance may turn in any
			# direction, and large footprints are indexed by all occupied buckets.
			var reach := _pathfinding_radius() + def.move_speed * maxf(Avoidance.HORIZON, delta)
			solids = nav_holder.query_static_blockers(from_pos, from_pos, reach)
		else:
			# Small standalone arenas may not install the navigation holder.
			solids.append_array(get_tree().get_nodes_in_group("buildings"))
			solids.append_array(get_tree().get_nodes_in_group("path_blockers"))
			for resource in get_tree().get_nodes_in_group("resource_nodes"):
				if resource.amount > 0 and ResourceNode.resource_blocks_pathfinding(resource.resource_type):
					solids.append(resource)
	var preferred := (desired_pos - from_pos) / maxf(delta, 0.00001)
	sim_pos = Avoidance.step_scheduled(self, preferred, _locomotion_velocity, delta, units, solids, _move_target, _avoidance_cache)
	_vision_sync_position()


## Reserve separate, walkable destinations even for repeated AI rally commands.
func _choose_move_goal(target: Vector2) -> Vector2:
	if not is_inside_tree():
		return target
	var radius := _pathfinding_radius()
	var nav := _get_nav_service()
	var center := CollisionResolverScript.clamp_to_map(target, radius)
	if nav != null:
		center = nav.nearest_walkable_world(center, radius)
	var units := get_tree().get_nodes_in_group("units")
	var spacing := radius * 2.0 + 0.3
	var approach := (sim_pos - center).angle()
	for ring in range(0, 13):
		var count := 1 if ring == 0 else ring * 8
		for slot in count:
			var candidate := center + Vector2.from_angle(approach + TAU * slot / count) * spacing * ring
			if not CollisionResolverScript.clamp_to_map(candidate, radius).is_equal_approx(candidate):
				continue
			if nav != null and not nav.is_world_walkable_with_radius(candidate, radius):
				continue
			var available := true
			for other in units:
				if other == self or other.hp <= 0:
					continue
				var occupied: Vector2 = other._move_target if other.order == Enums.OrderType.MOVE else other.sim_pos
				if candidate.distance_to(occupied) < radius + CollisionResolverScript.unit_radius(other) + 0.2:
					available = false
					break
			if available:
				return candidate
	return center


func _refresh_reserved_goal() -> void:
	if _goal_refresh_remaining > 0 or _move_target.is_equal_approx(_requested_move_target) or not is_inside_tree():
		return
	_goal_refresh_remaining = 0.5
	var radius := _pathfinding_radius()
	var nav := _get_nav_service()
	if not CollisionResolverScript.clamp_to_map(_requested_move_target, radius).is_equal_approx(_requested_move_target):
		return
	if nav != null and not nav.is_world_walkable_with_radius(_requested_move_target, radius):
		return
	for other in get_tree().get_nodes_in_group("units"):
		if other == self or other.hp <= 0:
			continue
		var occupied: Vector2 = other._move_target if other.order == Enums.OrderType.MOVE else other.sim_pos
		if _requested_move_target.distance_to(occupied) < radius + CollisionResolverScript.unit_radius(other) + 0.2:
			return
	_move_target = _requested_move_target
	_request_nav_path(_move_target)


func _skip_visible_waypoints() -> void:
	var nav := _get_nav_service()
	while _path_index + 1 < _path.size():
		var next: Vector2 = _path[_path_index + 1]
		if sim_pos.distance_to(_path[_path_index]) <= ARRIVAL_DISTANCE:
			_path_index += 1
		elif not _path_is_crowd_route and nav != null and nav.has_method("is_segment_walkable") and nav.is_segment_walkable(sim_pos, next, _pathfinding_radius()):
			_path_index += 1
		else:
			break


func _move_toward(target: Vector2, delta: float) -> void:
	_move_target = target
	if (_nav_goal.distance_to(target) > 0.75 or _path.is_empty()) and not _path_pending and _path_retry_cooldown <= 0:
		if _path.is_empty():
			_request_nav_path(target)
		else:
			_request_nav_path_keeping_route(target)
		_nav_goal = target
	if _path_pending and _path.is_empty():
		var steer := _steer_velocity_toward(delta)
		if steer.length_squared() > 0.0001:
			_update_move_facing(steer, delta, false)
		_refresh_move_debug(steer, sim_pos)
		return
	if _path.is_empty():
		_update_move_facing(target - sim_pos, delta, false)
		return
	_skip_visible_waypoints()
	var steer_target := _current_steer_target()
	var offset := steer_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if _advance_path_waypoint():
			return
		# A clearance grid may stop before the precise working position. Once
		# consumed, keep steering toward that position instead of walking back
		# to the final grid point after each short direct step.
		_path_index = _path.size()
		if sim_pos.distance_to(_move_target) > ARRIVAL_DISTANCE:
			_direct_step_toward(_move_target, delta)
			return
		if _villager_actions:
			_update_idle_animation(0.0)
		else:
			_apply_billboard_frame(false)
		return
	var step := minf(_movement_speed() * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context(), delta)
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
	var step := minf(_movement_speed() * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity, _move_resolve_context(), delta)
	_sync_visual()
	_refresh_move_debug(velocity, from_pos)
	_track_move_progress(from_pos, velocity, step, delta, offset)


func _track_move_progress(
	from_pos: Vector2, _velocity: Vector2, step: float, delta: float, face_vector: Vector2
) -> void:
	var actual := sim_pos - from_pos
	var walking := actual.length() > maxf(0.001, step * 0.08)
	if walking:
		_no_progress_frames = 0
		_stuck_seconds = 0
	else:
		# Keep the legacy 60-Hz stalled-frame counters' real-time thresholds.
		_no_progress_frames += maxi(1, roundi(60.0 / Engine.physics_ticks_per_second))
		_stuck_seconds += delta
		if _stuck_seconds >= STUCK_REPATH_SECONDS:
			_try_recover_from_stuck()
	# Sideways avoidance is intentional walking; face actual travel, not a blocked goal.
	_update_move_facing(actual if walking else face_vector, delta, walking)


func _update_move_facing(face_vector: Vector2, delta: float, moved: bool) -> void:
	# Face travel direction even while waiting for clearance; walk anim only when moved.
	_update_billboard_facing_from_vector(face_vector, delta, moved, moved)


func _get_nav_service() -> Object:
	if not is_inside_tree():
		return null
	var holders := get_tree().get_nodes_in_group("nav_service")
	if holders.is_empty():
		return null
	for holder in holders:
		if holder.get_parent().is_ancestor_of(self) and holder.has_meta("nav"):
			return holder.get_meta("nav")
	return null

func _request_nav_path(target: Vector2) -> void:
	_pending_crowd_route = false
	_path_is_crowd_route = false
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


## The goal drifted (a moving attack target): keep walking the current route
## while the new one is computed. Clearing it stalled the chaser on every
## re-path, and a target that moved more than the drift tolerance per frame
## (any fast unit at a coarse simulation step) froze its chaser in place.
func _request_nav_path_keeping_route(target: Vector2) -> void:
	var nav := _get_nav_service()
	if nav == null or not nav.has_method("enqueue_path"):
		_request_nav_path(target)
		return
	_pending_crowd_route = false
	nav.call("enqueue_path", get_instance_id(), sim_pos, target, _pathfinding_radius())
	_path_pending = true


func _pathfinding_radius() -> float:
	return CollisionResolverScript.unit_radius(self)

func apply_nav_path(path: PackedVector2Array) -> void:
	if not _path_pending:
		return
	_path_pending = false
	if order == Enums.OrderType.GATHER and _automatic_gather_target and _gather_state in ["searching_resource", "to_resource"]:
		_apply_gather_search_path(path)
		return
	_path_retry_cooldown = 0.0
	_path_is_crowd_route = _pending_crowd_route
	if path.is_empty():
		# Unreachable is not permission to walk straight through a wall.
		_path = PackedVector2Array()
		_path_retry_cooldown = PATH_RETRY_COOLDOWN
		_path_index = 0
		return
	_path = path
	_path_index = 0
	var nav := _get_nav_service()
	if _path[-1].distance_to(_move_target) > ARRIVAL_DISTANCE and nav != null and nav.is_segment_walkable(_path[-1], _move_target, _pathfinding_radius()):
		_path.append(_move_target)


func refresh_nav_path_if_moving() -> void:
	match order:
		Enums.OrderType.MOVE:
			_stuck_repath_attempts = 0
			_request_nav_path(_move_target)
		Enums.OrderType.GATHER, Enums.OrderType.BUILD:
			_path = PackedVector2Array()
			_path_index = 0
			_stuck_repath_attempts = 0
		Enums.OrderType.ATTACK:
			_stuck_repath_attempts = 0
			_request_nav_path(_move_target)


func _try_recover_from_stuck() -> bool:
	if _repath_cooldown > 0 or _path_pending:
		return false
	if _try_settle_shared_goal():
		return true
	_stuck_seconds = 0
	_no_progress_frames = 0
	_stuck_repath_attempts += 1
	_repath_cooldown = REPATH_INTERVAL + float(get_instance_id() % 7) * 0.04
	_request_nav_path_avoiding_crowd(_move_target)
	return true


## A shared rally point is an area: once teammates have arrived, accept a free
## nearby spot instead of trying forever to enter a ring of stationary bodies.
## Solo commands, different goals, and unreachable terrain never use this rule.
func _try_settle_shared_goal() -> bool:
	if order != Enums.OrderType.MOVE or not is_inside_tree():
		return false
	var peers := 1
	var settled := false
	var units := get_tree().get_nodes_in_group("units")
	for other in units:
		if other == self or other.hp <= 0 or other.team != team:
			continue
		if other._has_move_command and other._requested_move_target.distance_to(_requested_move_target) < 0.1:
			peers += 1
			settled = settled or other.order == Enums.OrderType.NONE
	if peers < 2 or not settled:
		return false
	var arrival_radius := _pathfinding_radius() * 2.0 * sqrt(float(peers))
	if sim_pos.distance_to(_requested_move_target) > arrival_radius:
		return false
	var nav := _get_nav_service()
	if nav != null and not nav.is_segment_walkable(sim_pos, _requested_move_target, _pathfinding_radius()):
		return false
	for other in units:
		if other != self and other.hp > 0 and sim_pos.distance_to(other.sim_pos) < _pathfinding_radius() + CollisionResolverScript.unit_radius(other) + 0.05:
			return false
	_move_target = sim_pos
	_finish_move()
	return true


func _request_nav_path_avoiding_crowd(target: Vector2) -> void:
	var nav := _get_nav_service()
	if nav == null:
		_path = PackedVector2Array([target])
		_path_index = 0
		return
	# The same per-frame budget applies to recovery; no synchronous crowd A* burst.
	nav.enqueue_path(get_instance_id(), sim_pos, target, _pathfinding_radius(), _crowd_blockers_for_stuck_repath(target))
	_path_pending = true
	_pending_crowd_route = true


func _crowd_blockers_for_stuck_repath(target: Vector2) -> Array:
	var blockers: Array = []
	var move_dir := target - sim_pos
	if move_dir.length_squared() < 0.0001:
		move_dir = _current_steer_target() - sim_pos
	if move_dir.length_squared() < 0.0001:
		return blockers
	move_dir = move_dir.normalized()
	var cone_cos := cos(deg_to_rad(STUCK_CROWD_BLOCK_ANGLE_DEG))
	var query_r := minf(resolved_vision_radius(), STUCK_CROWD_QUERY_RADIUS)
	var candidates: Array = []
	var vision := _get_vision_service()
	if vision != null and vision.has_method("others_in_radius"):
		candidates = vision.call("others_in_radius", self, query_r)
	elif is_inside_tree():
		for node in get_tree().get_nodes_in_group("units"):
			if node == self:
				continue
			if float(node.get("hp")) <= 0.0:
				continue
			var dist: float = sim_pos.distance_to(node.get("sim_pos"))
			if dist <= query_r:
				candidates.append(node)
	for other in candidates:
		var unit := other as Object
		if unit == null or unit == self or not is_instance_valid(unit):
			continue
		if float(unit.get("hp")) <= 0.0:
			continue
		var other_pos: Vector2 = unit.get("sim_pos")
		var to_other := other_pos - sim_pos
		var dist := to_other.length()
		if dist < 0.001:
			continue
		var to_dir := to_other / dist
		if to_dir.dot(move_dir) < cone_cos:
			continue
		if to_other.dot(move_dir) < 0.15:
			continue
		blockers.append(unit)
	return blockers


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
	var step := minf(_movement_speed() * delta, distance)
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


func get_inspect_summary() -> String:
	var team_name := "玩家" if team == Enums.Team.PLAYER else "AI"
	var lines: PackedStringArray = ["阵营: %s" % team_name]
	lines.append("order=%s" % _order_name(order))
	if order == Enums.OrderType.GATHER and not _gather_state.is_empty():
		lines.append("gather=%s carry=%.0f" % [_gather_state, carry_amount])
	if order == Enums.OrderType.BUILD and is_instance_valid(_build_target):
		lines.append("建造中")
	if order == Enums.OrderType.ATTACK and is_instance_valid(_attack_target):
		lines.append("攻击 %s" % _attack_target.name)
	if _path_pending:
		lines.append("寻路等待")
	elif not _path.is_empty():
		lines.append("路径 %d/%d" % [_path_index + 1, _path.size()])
	if _no_progress_frames > 0:
		lines.append("无进展 %d 帧" % _no_progress_frames)
	return "\n".join(lines)


func get_inspect_debug_line() -> String:
	var dbg := get_move_debug()
	return (
		"order=%s gather=%s pos=%s path=%d/%d stuck=%s pending=%s"
		% [
			_order_name(order),
			_gather_state if order == Enums.OrderType.GATHER else "-",
			sim_pos,
			_path_index,
			_path.size(),
			dbg.get("stuck", false),
			dbg.get("pending", false),
		]
	)


func _order_name(value: Enums.OrderType) -> String:
	match value:
		Enums.OrderType.NONE:
			return "NONE"
		Enums.OrderType.MOVE:
			return "MOVE"
		Enums.OrderType.GATHER:
			return "GATHER"
		Enums.OrderType.BUILD:
			return "BUILD"
		Enums.OrderType.ATTACK:
			return "ATTACK"
		_:
			return "?"


func _advance_path_waypoint() -> bool:
	if _path_index + 1 < _path.size():
		_path_index += 1
		return true
	return false

func set_selected(selected: bool) -> void:
	_ensure_selection_circle()
	var selection_ring := get_node_or_null("SelectionRing") as CanvasItem
	if selection_ring != null:
		selection_ring.visible = selected
	var badge := get_node_or_null("ControlGroupBadge") as Label
	if badge != null:
		badge.visible = selected and not badge.text.is_empty()


## Local input state only; group membership is not simulation/network state.
func set_control_group_ids(groups: Array[int]) -> void:
	var badge := get_node_or_null("ControlGroupBadge") as Label
	if badge == null and groups.is_empty():
		return
	if badge == null:
		badge = Label.new()
		badge.name = "ControlGroupBadge"
		badge.position = Vector2(18, -14)
		badge.z_index = 2
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_theme_font_size_override("font_size", 12)
		badge.add_theme_color_override("font_color", Color.WHITE)
		badge.add_theme_color_override("font_outline_color", Color.BLACK)
		badge.add_theme_constant_override("outline_size", 3)
		add_child(badge)
	var numbers := PackedStringArray()
	for group in groups:
		numbers.append(str(group))
	badge.text = ",".join(numbers)
	var ring := get_node_or_null("SelectionRing") as CanvasItem
	badge.visible = ring != null and ring.visible and not groups.is_empty()

func _sync_visual() -> void:
	IsoMathScript.sync_node(self, sim_pos)

func _setup_presentation() -> void:
	var body := get_node_or_null("Body") as CanvasItem
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	_use_billboard = false
	_player_color_sheet = ""
	_player_color_id = -1
	_player_color_animation = &""
	_player_color_unit_id = &""
	_hotspot_animation = &""
	_hotspot_frame = -1
	if billboard != null and def != null:
		var sprite_frames: SpriteFrames = SpriteCatalogScript.unit_sprite_frames(def.id)
		_sprite_metas = {}
		_villager_actions = false
		if def.id == &"villager":
			_sprite_metas = SpriteCatalogScript.load_villager_metas_by_action()
			_villager_actions = (
				sprite_frames != null
				and sprite_frames.has_animation(&"walk_dir_0")
			)
		if not _villager_actions:
			var base := SpriteCatalogScript.unit_sheet_base(def.id)
			if SpriteCatalogScript.sheet_paths_exist(base):
				var meta := SpriteCatalogScript.load_meta(base)
				if not meta.is_empty() and sprite_frames != null:
					_sprite_metas = {&"": meta}
					for action: StringName in [&"idle", &"attack", &"die"]:
						var action_base := SpriteCatalogScript.combat_sheet_base(def.id, action)
						if not action_base.is_empty():
							var action_meta := SpriteCatalogScript.load_meta(action_base)
							if not action_meta.is_empty():
								_sprite_metas[action] = action_meta
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
		body.visible = not _use_billboard or not billboard.visible
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
		# Authored maps use older, oversized collision radii. Match the original
		# actor's visual footprint without changing movement/collision balance.
		var visual_def := GameCatalog.get_unit(&"militia" if def.id == &"swordsman" else def.id)
		if visual_def != null: radius = visual_def.resolved_footprint_radius()
	SpriteCatalogScript.configure_selection_circle(self, radius)


func _ensure_selection_circle() -> void:
	var ring := get_node_or_null("SelectionRing")
	if ring is Line2D:
		return
	_configure_selection_ring()

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


func _projectile_origin_sim() -> Vector2:
	return sim_pos


func _projectile_spawn_local_y() -> float:
	## Local screen Y above feet (negative = up). Uses sprite top ≈ head height.
	var top_y := _sprite_top_local_y()
	if top_y < -4.0:
		return top_y * 0.88
	return -32.0


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
		_anim_frame = fmod(_anim_frame + _animation_fps(&"walk") * delta, 1024.0)
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
			_anim_frame = fmod(_anim_frame + _animation_fps(&"idle") * delta, 1024.0)
		_apply_billboard_frame(true, &"", false)
	else:
		_apply_billboard_frame(false, &"idle", false)


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
			var idle_anim := StringName("idle_dir_%d" % _facing_dir)
			if not actually_moving and billboard.sprite_frames.has_animation(idle_anim):
				action = &"idle"
				anim = idle_anim
			else:
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
	_apply_billboard_player_color(billboard, anim)
	var one_shot := action in [&"attack", &"die"]
	var frame_idx := 0
	if one_shot:
		frame_idx = mini(int(_combat_anim_time * _animation_fps(action)), frame_count - 1)
	elif animate:
		frame_idx = int(_anim_frame) % frame_count
	billboard.frame = frame_idx
	_apply_billboard_hotspot(billboard, anim, frame_idx)
	if hp > 0.0 and hp < _max_hp:
		_position_world_hp_bar()


func _apply_billboard_hotspot(
	billboard: AnimatedSprite2D, anim: StringName, frame_idx: int
) -> void:
	# Simulation commonly updates at 60 Hz while the same sprite frame remains
	# on screen. Its hotspot depends only on animation, frame and mirroring.
	if anim == _hotspot_animation and frame_idx == _hotspot_frame and _facing_flip == _hotspot_flip:
		if not billboard.offset.is_equal_approx(_hotspot_offset):
			billboard.offset = _hotspot_offset
		return
	var parsed: Dictionary = SpriteCatalogScript.parse_directional_animation(anim)
	var action: StringName = parsed["action"]
	var direction: int = int(parsed["direction"])
	var meta: Dictionary = _sprite_metas.get(action, _sprite_metas.get(&"", {}))
	if meta.is_empty():
		return
	var offset := SpriteCatalogScript.offset_for_frame_2d(
		meta, direction, frame_idx, _facing_flip
	)
	_hotspot_animation = anim
	_hotspot_frame = frame_idx
	_hotspot_flip = _facing_flip
	_hotspot_offset = offset
	if not billboard.offset.is_equal_approx(offset):
		billboard.offset = offset


func _apply_team_color() -> void:
	var color_id := TeamColorCatalogScript.resolve_color_id(team, match_state)
	var body := get_node_or_null("Body") as CanvasItem
	if body != null:
		body.modulate = TeamColorCatalogScript.fallback_color(color_id)
	var billboard := get_node_or_null("Billboard") as AnimatedSprite2D
	if billboard != null and _use_billboard:
		billboard.modulate = Color.WHITE
		_apply_billboard_player_color(billboard, billboard.animation)


func _apply_billboard_player_color(billboard: AnimatedSprite2D, anim: StringName) -> void:
	if def == null:
		return
	var color_id := TeamColorCatalogScript.resolve_color_id(team, match_state)
	if anim == _player_color_animation and def.id == _player_color_unit_id and color_id == _player_color_id:
		return
	var base := SpriteCatalogScript.unit_animation_sheet_base(def.id, anim)
	_player_color_animation = anim
	_player_color_unit_id = def.id
	if base == _player_color_sheet and color_id == _player_color_id:
		return
	_player_color_sheet = base
	_player_color_id = color_id
	var valid := SpriteCatalogScript.apply_player_color(billboard, base, color_id)
	billboard.visible = valid
	var body := get_node_or_null("Body") as CanvasItem
	if body != null:
		body.visible = not valid
		body.modulate = TeamColorCatalogScript.fallback_color(color_id)


func refresh_team_color() -> void:
	## Rebind an immutable cached material, never mutate its uniforms in-place.
	_player_color_id = -1
	_apply_team_color()


func _on_team_color_changed(changed_team: int) -> void:
	if changed_team == team:
		refresh_team_color()

func _exit_tree() -> void:
	EntityRegistryScript.unregister(self, "removed")
	_vision_unregister()
	if _population_registered and match_state != null and def != null:
		match_state.register_pop(team, -def.population, 0)
		_population_registered = false


## Network playback updates presentation without issuing orders or simulating hits.
func network_presentation() -> Dictionary:
	var sprite := get_node_or_null("Billboard") as AnimatedSprite2D
	return {
		"facing": _facing_dir, "flip": _facing_flip,
		"animation": String(sprite.animation) if sprite != null else "",
		"frame": sprite.frame if sprite != null else 0,
		"combat_action": String(_combat_action), "gather_state": _gather_state,
	}


func apply_network_presentation(data: Dictionary) -> void:
	_sync_visual()
	_facing_dir = int(data.get("facing", 0))
	_facing_flip = bool(data.get("flip", false))
	_combat_action = StringName(data.get("combat_action", ""))
	_gather_state = String(data.get("gather_state", ""))
	var sprite := get_node_or_null("Billboard") as AnimatedSprite2D
	var animation := StringName(data.get("animation", ""))
	if sprite != null and sprite.sprite_frames != null and sprite.sprite_frames.has_animation(animation):
		sprite.stop()
		sprite.animation = animation
		sprite.frame = clampi(int(data.get("frame", 0)), 0, sprite.sprite_frames.get_frame_count(animation) - 1)
		sprite.flip_h = _facing_flip
		_apply_billboard_player_color(sprite, animation)
		_apply_billboard_hotspot(sprite, animation, sprite.frame)
	_refresh_world_hp_bar()


func _get_vision_service() -> Object:
	if not is_inside_tree():
		return null
	var holders := get_tree().get_nodes_in_group("vision_service")
	if holders.is_empty():
		return null
	var holder := holders[0]
	if holder.has_meta("vision"):
		return holder.get_meta("vision")
	return null


func _vision_register() -> void:
	var vision := _get_vision_service()
	if vision != null and vision.has_method("register"):
		vision.call("register", self)


func _vision_unregister() -> void:
	var vision := _get_vision_service()
	if vision != null and vision.has_method("unregister"):
		vision.call("unregister", self)


func _vision_sync_position() -> void:
	var vision := _get_vision_service()
	if vision != null and vision.has_method("sync_position"):
		vision.call("sync_position", self)

## Change a researched unit line without resetting its orders or registering population again.
func apply_definition_upgrade(value: UnitDef) -> void:
	if value == null or def == value: return
	var ratio := hp / maxf(_max_hp,1)
	def = value
	_max_hp = float(value.max_hp)
	hp = _max_hp * ratio
	melee_armor = value.melee_armor + (civ.melee_armor_bonus if civ != null and not value.is_ranged else 0)
	pierce_armor = value.pierce_armor
	_sprite_metas.clear()
	_player_color_sheet = ""
	_setup_presentation()
	_refresh_world_hp_bar()
