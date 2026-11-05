extends Node
## Shared support behaviors for imported land content. Runs only on the authority.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Projectile := preload("res://scenes/entities/projectile_view.tscn")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
var state: MatchState
var entities: Node
## Seconds dictionaries remain a save/UI boundary. Simulation owns integer time.
var cooldowns: Dictionary = {}
var cooldown_times: Dictionary = {}
var heal_remainders: Dictionary = {}
var elapsed_time: int = 0
var elapsed: float:
	get: return float(elapsed_time) / Fixed.TIME_SCALE
	set(value): elapsed_time = roundi(value * Fixed.TIME_SCALE)

func setup(value: MatchState, root: Node) -> void:
	state = value
	entities = root

func sync_compatibility_state() -> void:
	for id in cooldown_times.keys():
		if not cooldowns.has(id): cooldown_times.erase(id)
	for id in cooldowns:
		if not cooldown_times.has(id) or float(cooldowns[id]) != Fixed.time_to_seconds(cooldown_times[id]):
			cooldown_times[id] = maxi(0, Fixed.time_from_seconds(float(cooldowns[id])))

func refresh_compatibility_state() -> void:
	cooldowns.clear()
	for id in cooldown_times:
		cooldowns[id] = Fixed.time_to_seconds(cooldown_times[id])

@warning_ignore("integer_division")
func _process(delta: float) -> void:
	if state != null and state.lockstep_enabled and not state.lockstep_stepping: return
	if state == null or state.frozen: return
	sync_compatibility_state()
	elapsed_time += Fixed.delta_time(delta, state.lockstep_enabled)
	if elapsed_time < Fixed.TIME_SCALE / 4: return
	var step_time := elapsed_time
	elapsed_time = 0
	var children := entities.get_children()
	for source in children:
		if source.has_meta("network_replica") or source.is_queued_for_deletion() or source.get("hp") == null or source.hp <= 0: continue
		if source is UnitAgent and source.def.id == &"monk":
			if source.order != Enums.OrderType.NONE: continue
			for target in children:
				if target is UnitAgent and target != source and target.team == source.team and target.hp_q > 0 and target.hp_q < target.def.max_hp * Fixed.SCALE and Fixed.distance_squared(source.sim_pos, target.sim_pos) <= 36 * Fixed.SCALE * Fixed.SCALE:
					var healer_id: int = source.get_instance_id()
					var numerator: int = 2560 * step_time + int(heal_remainders.get(healer_id, 0))
					target.hp_q = mini(target.def.max_hp * Fixed.SCALE, target.hp_q + numerator / Fixed.TIME_SCALE)
					heal_remainders[healer_id] = numerator % Fixed.TIME_SCALE
					break
		elif source is BuildingAgent and source.is_complete and not source.is_placement_ghost:
			var id: int = source.get_instance_id()
			cooldown_times[id] = maxi(0, int(cooldown_times.get(id, 0)) - step_time)
			cooldowns[id] = Fixed.time_to_seconds(cooldown_times[id])
			if cooldown_times[id] > 0: continue
			var weapon := Catalog.building_weapon(source.def.id)
			if weapon == null: continue
			var nearest: Node2D
			var radius := Fixed.from_float(weapon.attack_range)
			var distance: int = radius * radius
			var minimum := Fixed.from_float(weapon.minimum_attack_range)
			for target in children:
				if not (target is UnitAgent or target is BuildingAgent) or target.team == source.team or target.hp <= 0 or target.is_queued_for_deletion(): continue
				if target.get("is_placement_ghost") == true: continue
				if not FogAccess.can_see(source,target): continue
				var d: int = Fixed.distance_squared(source.sim_pos, ProjectileAgent.aim_point_for_target(source.sim_pos, target))
				if d >= minimum * minimum and d <= distance:
					nearest = target
					distance = d
			if nearest == null: continue
			var projectile := Projectile.instantiate()
			entities.add_child(projectile)
			projectile.setup(source.sim_pos, ProjectileAgent.aim_point_for_target(source.sim_pos, nearest), weapon, source.team, source)
			cooldown_times[id] = Fixed.time_from_seconds(weapon.attack_cooldown)
			cooldowns[id] = Fixed.time_to_seconds(cooldown_times[id])
