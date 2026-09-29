extends Node
## Shared support behaviors for imported land content. Runs only on the authority.
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Projectile := preload("res://scenes/entities/projectile_view.tscn")
const FogAccess := preload("res://scripts/systems/fog_access.gd")
var state: MatchState
var entities: Node
var cooldowns: Dictionary = {}
var weapons: Dictionary = {}
var elapsed := 0.0

func setup(value: MatchState, root: Node) -> void:
	state = value
	entities = root

func _process(delta: float) -> void:
	if state == null or state.frozen: return
	elapsed += delta
	if elapsed < 0.25: return
	var step := elapsed
	elapsed = 0
	var children := entities.get_children()
	for source in children:
		if source.has_meta("network_replica") or source.is_queued_for_deletion() or source.get("hp") == null or source.hp <= 0: continue
		if source is UnitAgent and source.def.id == &"monk":
			if source.order != Enums.OrderType.NONE: continue
			for target in children:
				if target is UnitAgent and target != source and target.team == source.team and target.hp > 0 and target.hp < target.def.max_hp and source.sim_pos.distance_to(target.sim_pos) <= 6:
					target.hp = minf(target.def.max_hp, target.hp + 2.5 * step)
					break
		elif source is BuildingAgent and source.is_complete and not source.is_placement_ghost:
			var id: int = source.get_instance_id()
			cooldowns[id] = maxf(0, float(cooldowns.get(id,0))-step)
			if cooldowns[id] > 0: continue
			var r := Catalog.building_record(source.def.id)
			if int(r.get("attack",0)) <= 0: continue
			var nearest: Node2D
			var distance := float(r.get("attack_range",0))
			for target in children:
				if not (target is UnitAgent or target is BuildingAgent) or target.team == source.team or target.hp <= 0 or target.is_queued_for_deletion(): continue
				if not FogAccess.can_see(source,target): continue
				var d: float = source.sim_pos.distance_to(target.sim_pos)
				if d < distance:
					nearest = target
					distance = d
			if nearest == null: continue
			if not weapons.has(source.def.id):
				var weapon := UnitDef.new()
				weapon.id = source.def.id
				weapon.attack = int(r.attack)
				weapon.is_ranged = true
				weapons[source.def.id] = weapon
			var projectile := Projectile.instantiate()
			entities.add_child(projectile)
			projectile.setup(source.sim_pos, nearest.sim_pos, weapons[source.def.id], source.team, source)
			cooldowns[id] = maxf(0.5,float(r.get("cooldown",2)))
