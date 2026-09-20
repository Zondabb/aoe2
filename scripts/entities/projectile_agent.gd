class_name ProjectileAgent
extends Node2D

## Ground sim_pos flies straight to aim_pos; sprite follows a parabolic arc for visuals.

const ARROW_SPEED := 11.0
const IMPACT_RADIUS := 0.6
## Peak arc height scales with flight distance (sim tiles).
const ARC_HEIGHT_PER_TILE := 0.18
const ARC_APEX_MIN := 0.45
const ARC_APEX_MAX := 2.8
## Screen pixels per sim tile of arc height (negative Y = up on screen).
const ARC_SCREEN_SCALE := 22.0
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

var sim_pos := Vector2.ZERO
var aim_pos := Vector2.ZERO
var attacker_def: UnitDef
var attacker: Node = null
var team: Enums.Team = Enums.Team.PLAYER
var _consumed := false
var _origin := Vector2.ZERO
var _total_distance := 0.0
var _traveled := 0.0
var _clock_hours := SpriteCatalogScript.ARROW_CLOCK_START_HOURS
var _projectile_meta: Dictionary = {}
var _projectile_texture: Texture2D

func setup(
	origin: Vector2,
	impact_aim: Vector2,
	attacker_unit_def: UnitDef,
	attacker_team: Enums.Team,
	attacker_node: Node = null
) -> void:
	_origin = origin
	sim_pos = origin
	aim_pos = impact_aim
	attacker_def = attacker_unit_def
	attacker = attacker_node
	team = attacker_team
	_total_distance = _origin.distance_to(aim_pos)
	_traveled = 0.0
	_clock_hours = _compute_clock_hours()
	if _total_distance <= 0.0001:
		aim_pos = _origin
	_configure_visual()
	_sync_visual(0.0)

func _physics_process(delta: float) -> void:
	if _consumed:
		return
	var step := ARROW_SPEED * delta
	if _total_distance <= 0.0001 or _traveled + step >= _total_distance:
		sim_pos = aim_pos
		_sync_visual(1.0)
		_impact()
		return
	_traveled += step
	var t := _flight_progress()
	sim_pos = _origin.lerp(aim_pos, t)
	_sync_visual(t)

func _flight_progress() -> float:
	if _total_distance <= 0.0001:
		return 1.0
	return clampf(_traveled / _total_distance, 0.0, 1.0)

func _arc_apex_sim() -> float:
	return clampf(_total_distance * ARC_HEIGHT_PER_TILE, ARC_APEX_MIN, ARC_APEX_MAX)

func _arc_height_sim(t: float) -> float:
	var apex := _arc_apex_sim()
	return apex * 4.0 * t * (1.0 - t)

func _screen_pos_for_progress(t: float) -> Vector2:
	var ground := _origin.lerp(aim_pos, t)
	var screen := IsoMathScript.world_to_screen(ground)
	screen.y -= _arc_height_sim(t) * ARC_SCREEN_SCALE
	return screen

func _sync_visual(t: float) -> void:
	position = _screen_pos_for_progress(t)
	_update_sprite_frame(t)

func _compute_clock_hours() -> float:
	var from_screen := IsoMathScript.world_to_screen(_origin)
	var to_screen := IsoMathScript.world_to_screen(aim_pos)
	return SpriteCatalogScript.screen_delta_to_clock_hours(to_screen - from_screen)

func _sequence_step(t: float) -> int:
	var progress := clampf(t, 0.0, 1.0)
	return mini(
		int(progress * float(SpriteCatalogScript.ARROW_FRAMES_PER_DIRECTION)),
		SpriteCatalogScript.ARROW_FRAMES_PER_DIRECTION - 1
	)

func _impact() -> void:
	_consumed = true
	set_physics_process(false)
	_apply_splash_damage()
	queue_free()

func _apply_splash_damage() -> void:
	if attacker_def == null:
		return
	var victims: Array = _collect_splash_victims()
	for victim in victims:
		CombatSystemScript.apply_hit(attacker_def, victim, {"attacker": attacker})

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
	if int(node.get("team")) == team:
		return false
	if float(node.get("hp")) <= 0.0:
		return false
	if not node.has_method("take_damage"):
		return false
	return _distance_to_entity(node) <= IMPACT_RADIUS

func _distance_to_entity(node: Object) -> float:
	var center: Vector2 = node.get("sim_pos")
	var building_def := node.get("def") as BuildingDef
	if building_def != null:
		var half := building_def.footprint * 0.5
		if half.x > 0.0 and half.y > 0.0:
			return _distance_to_aabb(sim_pos, center, half)
	return sim_pos.distance_to(center)

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
	var half := building_def.footprint * 0.5
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
	var base := SpriteCatalogScript.projectile_sheet_base()
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			_projectile_meta = meta
			_projectile_texture = texture
			sprite.texture = SpriteCatalogScript.atlas_frame_at(_projectile_meta, _projectile_texture, 0)
			SpriteCatalogScript.configure_sprite_2d(
				sprite, SpriteCatalogScript.UNIT_PIXEL_SCALE_2D * 0.65, Vector2.ZERO
			)
			sprite.rotation = 0.0
			sprite.visible = true
			return
	sprite.visible = true

func _update_sprite_frame(t: float) -> void:
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite == null:
		return
	if not _projectile_meta.is_empty() and _projectile_texture != null:
		var frame := SpriteCatalogScript.projectile_frame_for_flight(_clock_hours, _sequence_step(t))
		sprite.texture = SpriteCatalogScript.atlas_frame_at(
			_projectile_meta, _projectile_texture, int(frame["index"])
		)
		sprite.flip_h = bool(frame["flip"])
		sprite.rotation = 0.0
		var hotspot := SpriteCatalogScript.hotspot_at_index(_projectile_meta, int(frame["index"]))
		if bool(frame["flip"]):
			hotspot.x = float(_projectile_meta.get("frame_w", 1)) - hotspot.x
		sprite.offset = SpriteCatalogScript.offset_for_hotspot_2d(_projectile_meta, hotspot)
		return
	sprite.rotation = 0.0
