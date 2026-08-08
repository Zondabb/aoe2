class_name UnitAgent
extends Node2D

const ARRIVAL_DISTANCE := 0.15
const GATHER_RANGE := 1.2
const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
const PLAYER_BILLBOARD_TINT := Color(0.65, 0.82, 1.0, 1.0)
const AI_BILLBOARD_TINT := Color(1.0, 0.62, 0.58, 1.0)
const ANIM_FPS := 18.0
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

func _ready() -> void:
	add_to_group("units")
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	_sync_visual()
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
	else:
		_update_idle_animation(delta)

func _process_move(delta: float) -> void:
	var offset := _move_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		var from_pos := sim_pos
		_apply_resolved_position(from_pos, _move_target)
		_sync_visual()
		order = Enums.OrderType.NONE
		_update_idle_animation(0.0)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity)
	_sync_visual()
	# Face intended move direction; only walk when collision actually moved us.
	var moved := _position_changed(from_pos)
	_update_billboard_facing_from_vector(offset, delta, moved, moved)

func command_move(target: Vector2) -> void:
	_move_target = target
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	order = Enums.OrderType.MOVE

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
	if not _attack_target_available():
		_attack_target = null
		order = Enums.OrderType.NONE
		return
	_attack_cooldown_remaining = maxf(0.0, _attack_cooldown_remaining - delta)
	if _distance_to(_attack_target) > def.range:
		_move_toward(_attack_target.get("sim_pos"), delta)
		return
	_face_toward(_attack_target.get("sim_pos"), delta, _villager_actions)
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
		_move_toward(_build_target.get("sim_pos"), delta)
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
			elif _distance_to(_gather_target) <= GATHER_RANGE:
				_gather_state = "gathering"
				_face_toward(_gather_target.get("sim_pos"), delta, true)
			else:
				_move_toward(_gather_target.get("sim_pos"), delta)
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

func _apply_resolved_position(from_pos: Vector2, desired_pos: Vector2) -> void:
	var units: Array = []
	var buildings: Array = []
	if is_inside_tree():
		var tree := get_tree()
		units = tree.get_nodes_in_group("units")
		buildings = tree.get_nodes_in_group("buildings")
	sim_pos = CollisionResolverScript.resolve_move(self, from_pos, desired_pos, units, buildings)

func _move_toward(target: Vector2, delta: float) -> void:
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
	_apply_resolved_position(from_pos, from_pos + velocity)
	_sync_visual()
	var moved := _position_changed(from_pos)
	_update_billboard_facing_from_vector(offset, delta, moved, moved)

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


func _position_changed(from_pos: Vector2) -> bool:
	return sim_pos.distance_squared_to(from_pos) > 0.000001


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
			return &"idle"
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
	var anim := StringName("%s_dir_%d" % [action, _facing_dir])
	if billboard.sprite_frames.has_animation(anim):
		return anim
	var action_dir0 := StringName("%s_dir_0" % action)
	if not String(action).is_empty() and billboard.sprite_frames.has_animation(action_dir0):
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
	if _villager_actions:
		var action := forced_action if not forced_action.is_empty() else _resolve_visual_action()
		if not actually_moving and action == &"walk":
			action = &"idle"
		anim = _pick_villager_animation(action)
	else:
		anim = StringName("dir_%d" % _facing_dir)
		if not billboard.sprite_frames.has_animation(anim):
			return
	billboard.flip_h = _facing_flip
	if billboard.animation != anim:
		billboard.animation = anim
	var frame_count := billboard.sprite_frames.get_frame_count(anim)
	if frame_count <= 0:
		return
	var frame_idx := (int(_anim_frame) % frame_count) if animate else 0
	billboard.frame = frame_idx
	_apply_billboard_hotspot(billboard, anim, frame_idx)


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
