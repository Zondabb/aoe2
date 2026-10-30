class_name ProjectileAgent
extends Node2D

## Ground sim_pos flies straight to aim_pos; sprite follows a parabolic arc for visuals.

const ARROW_SPEED := 28.0
const IMPACT_RADIUS := 0.6
## Screen pixels per sim tile of arc height (negative Y = up on screen).
const ARC_SCREEN_SCALE := 22.0
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")

var sim_pos := Vector2.ZERO
var aim_pos := Vector2.ZERO
var attacker_def: UnitDef
var attacker: Node = null
var match_state: MatchState
var team: Enums.Team = Enums.Team.PLAYER
var _consumed := false
var _origin := Vector2.ZERO
var _total_distance_fixed: int = 0
var _traveled_fixed: int = 0
var _travel_remainder: int = 0
var _total_distance: float:
	get: return Fixed.to_float(_total_distance_fixed)
	set(value): _total_distance_fixed = Fixed.from_float(value)
var _traveled: float:
	get: return Fixed.to_float(_traveled_fixed)
	set(value): _traveled_fixed = Fixed.from_float(value)
var _clock_hours := SpriteCatalogScript.ARROW_CLOCK_START_HOURS
var _projectile_meta: Dictionary = {}
var _projectile_texture: Texture2D
var _impact_meta: Dictionary = {}
var _impact_texture: Texture2D
var _scatter_meta: Dictionary = {}
var _scatter_texture: Texture2D
var _shadow_meta: Dictionary = {}
var _shadow_texture: Texture2D
var _impact_elapsed_time: int = 0
var _impact_elapsed: float:
	get: return Fixed.time_to_seconds(_impact_elapsed_time)
	set(value): _impact_elapsed_time = Fixed.time_from_seconds(value)
var _launch_height := 0.0
var _stone := false
var _ground_shadow: Sprite2D

func _ready() -> void:
	if has_meta("network_replica"):
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

func setup(
	origin: Vector2,
	impact_aim: Vector2,
	attacker_unit_def: UnitDef,
	attacker_team: Enums.Team,
	attacker_node: Node = null
) -> void:
	_origin = Fixed.quantize_vector(origin)
	sim_pos = _origin
	aim_pos = Fixed.quantize_vector(impact_aim)
	attacker_def = attacker_unit_def
	attacker = attacker_node
	if attacker != null and is_instance_valid(attacker):
		match_state = attacker.get("match_state") as MatchState
	team = attacker_team
	_stone = attacker_def != null and attacker_def.projectile_kind == &"stone"
	_launch_height = attacker_def.projectile_launch_height if attacker_def != null else 0.0
	if not _stone and _launch_height <= 0.0 and attacker is UnitAgent:
		_launch_height = -attacker._projectile_spawn_local_y()
	_total_distance_fixed = Fixed.isqrt(Fixed.distance_squared(_origin, aim_pos))
	_traveled_fixed = 0
	_travel_remainder = 0
	_clock_hours = _compute_clock_hours()
	if _total_distance_fixed == 0:
		aim_pos = _origin
	_configure_visual()
	_sync_visual(0.0)
	# setup follows add_child in live combat. Start the interpolation history at
	# the launch point, including the initial height, rather than the scene origin.
	reset_physics_interpolation()

@warning_ignore("integer_division")
func _physics_process(delta: float) -> void:
	if match_state != null and match_state.lockstep_enabled and not match_state.lockstep_stepping: return
	if has_meta("network_replica") or (match_state != null and match_state.frozen):
		return
	var elapsed_time := Fixed.delta_time(delta, match_state != null and match_state.lockstep_enabled)
	if _consumed:
		_impact_elapsed_time += elapsed_time
		_sync_impact_visual()
		if _impact_elapsed_time >= Fixed.time_from_seconds(_impact_duration()):
			queue_free()
		return
	var speed := attacker_def.projectile_speed if attacker_def != null else ARROW_SPEED
	var distance_numerator: int = Fixed.from_float(speed) * elapsed_time + _travel_remainder
	var step_fixed: int = distance_numerator / Fixed.TIME_SCALE
	_travel_remainder = distance_numerator % Fixed.TIME_SCALE
	if _total_distance_fixed == 0 or _traveled_fixed + step_fixed >= _total_distance_fixed:
		_traveled_fixed = _total_distance_fixed
		sim_pos = aim_pos
		_sync_visual(1.0)
		_impact()
		return
	_traveled_fixed += step_fixed
	var t := _flight_progress()
	sim_pos = Fixed.interpolate(_origin, aim_pos, _traveled_fixed, _total_distance_fixed)
	_sync_visual(t)


func network_presentation() -> Dictionary:
	return {
		"origin": [_origin.x, _origin.y], "aim": [aim_pos.x, aim_pos.y], "traveled": _traveled,
		"projectile_kind": "stone" if _stone else "arrow",
		"source_def": String(attacker_def.id) if attacker_def != null else "",
		"launch_height": _launch_height, "impact": _consumed, "impact_elapsed": _impact_elapsed,
	}


func apply_network_presentation(data: Dictionary) -> void:
	if has_meta("network_replica"):
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var source_def := StringName(data.get("source_def", ""))
	var stone: bool = data.get("projectile_kind", "arrow") == "stone"
	if stone != _stone or attacker_def == null or attacker_def.id != source_def:
		_stone = stone
		attacker_def = GameCatalog.get_unit(source_def) if not source_def.is_empty() else null
		if attacker_def == null and not source_def.is_empty():
			attacker_def = GameCatalog.building_weapon(source_def)
		_configure_visual()
	_launch_height = float(data.get("launch_height", 0.0))
	_consumed = bool(data.get("impact", false))
	_impact_elapsed = float(data.get("impact_elapsed", 0.0))
	var origin: Array = data.get("origin", [0.0, 0.0])
	var aim: Array = data.get("aim", [0.0, 0.0])
	_origin = Fixed.quantize_vector(Vector2(float(origin[0]), float(origin[1])))
	aim_pos = Fixed.quantize_vector(Vector2(float(aim[0]), float(aim[1])))
	_total_distance_fixed = Fixed.isqrt(Fixed.distance_squared(_origin, aim_pos))
	_traveled = float(data.get("traveled", 0.0))
	_travel_remainder = 0
	sim_pos = Fixed.interpolate(_origin, aim_pos, _traveled_fixed, _total_distance_fixed)
	_clock_hours = _compute_clock_hours()
	if _consumed:
		_sync_impact_visual()
	else:
		_sync_visual(_flight_progress())

func _flight_progress() -> float:
	if _total_distance <= 0.0001:
		return 1.0
	return clampf(_traveled / _total_distance, 0.0, 1.0)

func _arc_apex_sim() -> float:
	if _stone:
		# DAT arc sets the shape; the screen parabola is a visual approximation.
		var launch_angle := attacker_def.projectile_arc if attacker_def != null else 0.4
		return _total_distance * tan(launch_angle) * 0.25
	# Native signed arc is preserved in the profile. Genie does not publish its
	# equation; adapt its magnitude to a shallow parabola, with height separate.
	var arc := absf(attacker_def.projectile_arc) if attacker_def != null else 0.06
	return _total_distance * tan(arc) * 0.25

func _arc_height_sim(t: float) -> float:
	var apex := _arc_apex_sim()
	return apex * 4.0 * t * (1.0 - t)

func _screen_pos_for_progress(t: float) -> Vector2:
	var ground := _origin.lerp(aim_pos, t)
	var screen := IsoMathScript.world_to_screen(ground)
	screen.y -= _arc_height_sim(t) * ARC_SCREEN_SCALE
	screen.y -= _launch_height * (1.0 - t)
	return screen

func _sync_visual(t: float) -> void:
	position = _screen_pos_for_progress(t)
	_update_sprite_frame(t)
	if is_instance_valid(_ground_shadow):
		_ground_shadow.position = IsoMathScript.world_to_screen(_origin.lerp(aim_pos, t)) - position
	if _stone:
		queue_redraw()

func _compute_clock_hours() -> float:
	var from_screen := IsoMathScript.world_to_screen(_origin)
	var to_screen := IsoMathScript.world_to_screen(aim_pos)
	return SpriteCatalogScript.screen_delta_to_clock_hours(to_screen - from_screen)

func _sequence_step(t: float) -> int:
	return _pitch_step(t, _projectile_meta)

func _pitch_step(t: float, meta: Dictionary) -> int:
	var count := maxi(1, int(meta.get("frames_per_direction", SpriteCatalogScript.ARROW_FRAMES_PER_DIRECTION)))
	var vertical := 4.0 * _arc_apex_sim() * (1.0 - 2.0 * clampf(t, 0.0, 1.0)) * ARC_SCREEN_SCALE - _launch_height
	var pitch := atan2(vertical, maxf(0.0001, _total_distance * ARC_SCREEN_SCALE))
	return clampi(roundi((0.5 - pitch / PI) * (count - 1)), 0, count - 1)

func _impact() -> void:
	if _consumed:
		return
	_consumed = true
	_apply_splash_damage()
	if _stone:
		_impact_elapsed = 0.0
		_sync_impact_visual()
	else:
		set_physics_process(false)
		queue_free()

func _apply_splash_damage() -> void:
	if attacker_def == null:
		return
	var victims: Array = _collect_splash_victims()
	for victim in victims:
		var multiplier: int = Fixed.SCALE
		if _stone and attacker_def.projectile_splash_radius > 0.0:
			multiplier = clampi(Fixed.SCALE - Fixed.div(Fixed.isqrt(_distance_squared_to_entity(victim)), Fixed.from_float(_impact_radius())), 0, Fixed.SCALE)
		CombatSystemScript.apply_hit(attacker_def, victim, {"attacker": attacker, "damage_multiplier_fixed": multiplier})

func _collect_splash_victims() -> Array:
	# Prefer sibling scan so headless tests (nodes not yet in SceneTree) still work.
	# Live matches parent projectiles under the same Entities node as units/buildings.
	var victims: Array = []
	var seen: Dictionary = {}
	var parent := get_parent()
	if parent != null:
		for node in parent.get_children():
			if node == self:
				continue
			if not (node.is_in_group("units") or node.is_in_group("buildings")):
				continue
			if _is_hostile_in_splash(node):
				victims.append(node)
				seen[node] = true
	if is_inside_tree():
		var tree := get_tree()
		if tree != null:
			for node in tree.get_nodes_in_group("units"):
				if seen.has(node):
					continue
				if _is_hostile_in_splash(node):
					victims.append(node)
					seen[node] = true
			for node in tree.get_nodes_in_group("buildings"):
				if seen.has(node):
					continue
				if _is_hostile_in_splash(node):
					victims.append(node)
	return victims

func _is_hostile_in_splash(node: Object) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.get("is_placement_ghost") == true:
		return false
	if int(node.get("team")) == team and not (attacker_def != null and attacker_def.projectile_friendly_fire):
		return false
	if float(node.get("hp")) <= 0.0:
		return false
	if not node.has_method("take_damage"):
		return false
	var radius_fixed := Fixed.from_float(_impact_radius())
	return _distance_squared_to_entity(node) <= radius_fixed * radius_fixed


func _impact_radius() -> float:
	return maxf(0.15, attacker_def.projectile_splash_radius) if attacker_def != null else IMPACT_RADIUS

func _distance_to_entity(node: Object) -> float:
	return Fixed.to_float(Fixed.isqrt(_distance_squared_to_entity(node)))

func _distance_squared_to_entity(node: Object) -> int:
	var center := Fixed.vector(node.get("sim_pos"))
	var point := Fixed.vector(sim_pos)
	var building_def := node.get("def") as BuildingDef
	if building_def != null:
		var footprint: Vector2 = node.get_placement_footprint() if node.has_method("get_placement_footprint") else building_def.footprint
		var half := Fixed.vector(footprint * 0.5)
		if half.x > 0 and half.y > 0:
			var offset := point - center
			return Fixed.length_sq(offset - Vector2i(clampi(offset.x, -half.x, half.x), clampi(offset.y, -half.y, half.y)))
	return Fixed.length_sq(point - center)

static func _distance_to_aabb(point: Vector2, center: Vector2, half: Vector2) -> float:
	var delta := point - center
	var nearest := center + Vector2(
		clampf(delta.x, -half.x, half.x),
		clampf(delta.y, -half.y, half.y)
	)
	return point.distance_to(nearest)

static func aim_point_for_target(from: Vector2, target: Node2D) -> Vector2:
	if target == null or not is_instance_valid(target):
		return from
	var center: Vector2 = target.get("sim_pos")
	var building_def := target.get("def") as BuildingDef
	if building_def == null:
		return center
	var footprint: Vector2 = target.get_placement_footprint() if target.has_method("get_placement_footprint") else building_def.footprint
	var half := footprint * 0.5
	if half.x <= 0.0 or half.y <= 0.0:
		return center
	var delta := from - center
	return center + Vector2(
		clampf(delta.x, -half.x, half.x),
		clampf(delta.y, -half.y, half.y)
	)

func _configure_visual() -> void:
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite == null:
		return
	if is_instance_valid(_ground_shadow):
		_ground_shadow.free()
		_ground_shadow = null
	if _stone:
		_projectile_meta = SpriteCatalogScript.load_meta(attacker_def.projectile_flight_sheet)
		_projectile_texture = SpriteCatalogScript.load_texture(attacker_def.projectile_flight_sheet)
		_impact_meta = SpriteCatalogScript.load_meta(attacker_def.projectile_impact_sheet)
		_impact_texture = SpriteCatalogScript.load_texture(attacker_def.projectile_impact_sheet)
		_shadow_meta = SpriteCatalogScript.load_meta(attacker_def.projectile_shadow_sheet) if not attacker_def.projectile_shadow_sheet.is_empty() else {}
		_shadow_texture = SpriteCatalogScript.load_texture(attacker_def.projectile_shadow_sheet) if not _shadow_meta.is_empty() else null
		_scatter_meta = SpriteCatalogScript.load_meta(attacker_def.projectile_scatter_sheet) if not attacker_def.projectile_scatter_sheet.is_empty() else {}
		_scatter_texture = SpriteCatalogScript.load_texture(attacker_def.projectile_scatter_sheet) if not _scatter_meta.is_empty() else null
		SpriteCatalogScript.configure_sprite_2d(sprite, SpriteCatalogScript.ORIGINAL_ART_PIXEL_SCALE_2D, Vector2.ZERO)
		sprite.visible = _projectile_texture != null
		# Airborne stones must not disappear into terrain/actor Y sorting.
		z_index = 2
		return
	z_index = 2
	var base := attacker_def.projectile_flight_sheet if attacker_def != null else ""
	if base.is_empty(): base = SpriteCatalogScript.projectile_sheet_base()
	var shadow_base := attacker_def.projectile_shadow_sheet if attacker_def != null else ""
	if shadow_base.is_empty(): shadow_base = "res://assets/sprites/projectiles/arrow_shadow"
	_shadow_meta = SpriteCatalogScript.load_meta(shadow_base)
	_shadow_texture = SpriteCatalogScript.load_texture(shadow_base)
	if not _shadow_meta.is_empty() and _shadow_texture != null:
		_ground_shadow = Sprite2D.new()
		_ground_shadow.name = "GroundShadow"
		_ground_shadow.z_as_relative = false
		_ground_shadow.z_index = 0
		add_child(_ground_shadow)
		SpriteCatalogScript.configure_sprite_2d(_ground_shadow, SpriteCatalogScript.ORIGINAL_ART_PIXEL_SCALE_2D, Vector2.ZERO)
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			_projectile_meta = meta
			_projectile_texture = texture
			sprite.texture = SpriteCatalogScript.atlas_frame_at(_projectile_meta, _projectile_texture, 0)
			SpriteCatalogScript.configure_sprite_2d(
				sprite, SpriteCatalogScript.ORIGINAL_ART_PIXEL_SCALE_2D, Vector2.ZERO
			)
			sprite.rotation = 0.0
			sprite.visible = true
			return
	sprite.visible = true

func _update_sprite_frame(t: float) -> void:
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite == null:
		return
	if _stone:
		var elapsed := _traveled / maxf(0.001, attacker_def.projectile_speed)
		var frame_duration := float(_projectile_meta.get("frame_duration", 0.0))
		var frame := int(elapsed / frame_duration) % maxi(1, int(_projectile_meta.get("frame_count", 1))) if frame_duration > 0.0 else 0
		_apply_stone_frame(sprite, _projectile_meta, _projectile_texture, frame)
		return
	if not _projectile_meta.is_empty() and _projectile_texture != null:
		_apply_arrow_frame(sprite, _projectile_meta, _projectile_texture, _sequence_step(t))
		if is_instance_valid(_ground_shadow):
			_apply_arrow_frame(_ground_shadow, _shadow_meta, _shadow_texture, _pitch_step(t, _shadow_meta))
		return
	sprite.rotation = 0.0

func _apply_arrow_frame(sprite: Sprite2D, meta: Dictionary, texture: Texture2D, pitch: int) -> void:
	var frame := SpriteCatalogScript.projectile_frame_for_flight(_clock_hours, pitch, meta)
	sprite.texture = SpriteCatalogScript.atlas_frame_at(meta, texture, int(frame.index))
	sprite.flip_h = bool(frame.flip)
	sprite.rotation = 0.0
	var hotspot := SpriteCatalogScript.hotspot_at_index(meta, int(frame.index))
	if bool(frame.flip):
		hotspot.x = float(meta.get("frame_w", 1)) - hotspot.x
	sprite.offset = SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)


func _apply_stone_frame(sprite: Sprite2D, meta: Dictionary, texture: Texture2D, frame: int) -> void:
	if meta.is_empty() or texture == null:
		sprite.visible = false
		return
	frame = clampi(frame, 0, int(meta.get("frame_count", 1)) - 1)
	sprite.texture = SpriteCatalogScript.atlas_frame_at(meta, texture, frame)
	sprite.offset = SpriteCatalogScript.offset_for_hotspot_2d(meta, SpriteCatalogScript.hotspot_at_index(meta, frame))
	sprite.flip_h = false
	sprite.rotation = 0.0
	sprite.visible = true


func _impact_duration() -> float:
	return maxf(0.1, float(_impact_meta.get("frame_duration", 0.0465)) * int(_impact_meta.get("frame_count", 10)))


func _sync_impact_visual() -> void:
	position = IsoMathScript.world_to_screen(aim_pos)
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite != null:
		var frame_time := maxf(0.001, float(_impact_meta.get("frame_duration", 0.0465)))
		_apply_stone_frame(sprite, _impact_meta, _impact_texture, int(_impact_elapsed / frame_time))
	queue_redraw()


func _draw() -> void:
	if not _stone:
		return
	if _consumed:
		if _impact_texture == null:
			var progress := clampf(_impact_elapsed / _impact_duration(), 0.0, 1.0)
			draw_circle(Vector2.ZERO, lerpf(3.0, 18.0, progress), Color(0.65, 0.55, 0.38, 1.0 - progress), false, 2.0)
		return
	var t := _flight_progress()
	var height := _arc_height_sim(t) * ARC_SCREEN_SCALE + _launch_height * (1.0 - t)
	var scale_factor := SpriteCatalogScript.ORIGINAL_ART_PIXEL_SCALE_2D
	if _shadow_texture != null:
		draw_set_transform(Vector2(0.0, height), 0.0, Vector2.ONE * scale_factor)
		draw_texture(SpriteCatalogScript.atlas_frame_at(_shadow_meta, _shadow_texture, 0), -SpriteCatalogScript.hotspot_at_index(_shadow_meta, 0), Color(0.0, 0.0, 0.0, 0.35))
	else:
		draw_set_transform(Vector2(0.0, height), 0.0, Vector2(1.0, 0.45))
		draw_circle(Vector2.ZERO, 5.0, Color(0.0, 0.0, 0.0, 0.3))
	draw_set_transform(Vector2.ZERO)
	if _projectile_texture == null:
		draw_circle(Vector2.ZERO, 3.5, Color(0.40, 0.36, 0.30))
	if _scatter_texture == null or attacker_def == null:
		return
	# The original scatter stones are visual companions of one area-damage shot.
	var count := maxi(0, attacker_def.projectile_scatter_count - 1)
	for i in count:
		var angle := TAU * float(i) / maxf(1.0, count)
		var spread := Vector2.from_angle(angle) * (4.0 + 8.0 * t)
		spread.y *= 0.5
		var frame := (i + int(t * 10.0)) % maxi(1, int(_scatter_meta.get("frame_count", 1)))
		var texture := SpriteCatalogScript.atlas_frame_at(_scatter_meta, _scatter_texture, frame)
		var hotspot := SpriteCatalogScript.hotspot_at_index(_scatter_meta, frame)
		draw_set_transform(spread, 0.0, Vector2.ONE * scale_factor)
		draw_texture(texture, -hotspot)
	draw_set_transform(Vector2.ZERO)
