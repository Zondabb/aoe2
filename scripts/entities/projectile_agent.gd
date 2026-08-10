class_name ProjectileAgent
extends Node2D

const ARROW_SPEED := 22.0
const HIT_DISTANCE := 0.35
const CombatSystemScript := preload("res://scripts/systems/combat_system.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

var sim_pos := Vector2.ZERO
var target: Node2D
var attacker_def: UnitDef
var team: Enums.Team = Enums.Team.PLAYER
var _consumed := false

func setup(
	origin: Vector2,
	attack_target: Node2D,
	attacker_unit_def: UnitDef,
	attacker_team: Enums.Team
) -> void:
	sim_pos = origin
	target = attack_target
	attacker_def = attacker_unit_def
	team = attacker_team
	_sync_visual()
	_configure_visual()

func _physics_process(delta: float) -> void:
	if _consumed or not _target_valid():
		queue_free()
		return
	var target_pos: Vector2 = target.get("sim_pos")
	var offset := target_pos - sim_pos
	var distance := offset.length()
	if distance <= HIT_DISTANCE:
		_consumed = true
		set_physics_process(false)
		CombatSystemScript.apply_hit(attacker_def, target)
		queue_free()
		return
	var step := minf(ARROW_SPEED * delta, distance)
	sim_pos += offset.normalized() * step
	_sync_visual()
	_update_facing(offset)

func _target_valid() -> bool:
	return (
		is_instance_valid(target)
		and not target.is_queued_for_deletion()
		and float(target.get("hp")) > 0.0
		and int(target.get("team")) != team
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
