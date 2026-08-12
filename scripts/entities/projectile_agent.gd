class_name ProjectileAgent
extends Node2D

## Fixed-trajectory projectile: flies to aim_pos, then damages hostiles in a splash.

const ARROW_SPEED := 22.0
const IMPACT_RADIUS := 0.6
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

var sim_pos := Vector2.ZERO
var aim_pos := Vector2.ZERO
var attacker_def: UnitDef
var attacker: Node = null
var team: Enums.Team = Enums.Team.PLAYER
var _consumed := false
var _flight_dir := Vector2.RIGHT

func setup(
	origin: Vector2,
	impact_aim: Vector2,
	attacker_unit_def: UnitDef,
	attacker_team: Enums.Team,
	attacker_node: Node = null
) -> void:
	sim_pos = origin
	aim_pos = impact_aim
	attacker_def = attacker_unit_def
	attacker = attacker_node
	team = attacker_team
	var offset := aim_pos - origin
	if offset.length_squared() < 0.0001:
		_flight_dir = Vector2.RIGHT
		aim_pos = origin
	else:
		_flight_dir = offset.normalized()
	_sync_visual()
	_configure_visual()
	_update_facing(_flight_dir)

func _physics_process(delta: float) -> void:
	if _consumed:
		return
	var remaining := aim_pos - sim_pos
	var distance := remaining.length()
	var step := ARROW_SPEED * delta
	if distance <= step or distance <= 0.001:
		sim_pos = aim_pos
		_sync_visual()
		_impact()
		return
	sim_pos += _flight_dir * step
	_sync_visual()

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

func _sync_visual() -> void:
	IsoMathScript.sync_node(self, sim_pos)

func _configure_visual() -> void:
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite == null:
		return
	var base := SpriteCatalogScript.projectile_sheet_base()
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			sprite.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			SpriteCatalogScript.configure_sprite_2d(
				sprite, SpriteCatalogScript.UNIT_PIXEL_SCALE_2D * 0.65, Vector2.ZERO
			)
			sprite.visible = true
			return
	sprite.visible = true

func _update_facing(offset: Vector2) -> void:
	var sprite := get_node_or_null("Sprite") as Sprite2D
	if sprite == null or offset.length_squared() < 0.0001:
		return
	sprite.rotation = offset.angle()
