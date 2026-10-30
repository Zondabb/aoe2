class_name AgeProgression
extends Node
## One paid age research per team. Jobs retain a weak reference to their town center.

signal research_started(team: int, target_age: int)
signal research_progress(team: int, elapsed: float, duration: float)
signal research_cancelled(team: int)
signal research_completed(team: int, age: int)

const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const AGE_NAMES := ["黑暗时代", "封建时代", "城堡时代", "帝王时代"]
const REQUIREMENTS := {
	Enums.Age.FEUDAL: {"food": 500, "gold": 0, "duration": 130.0,
		"buildings": [&"barracks", &"mill", &"lumber_camp", &"mining_camp"]},
	Enums.Age.CASTLE: {"food": 800, "gold": 200, "duration": 160.0,
		"buildings": [&"archery_range", &"stable", &"blacksmith", &"market"]},
	Enums.Age.IMPERIAL: {"food": 1000, "gold": 800, "duration": 190.0,
		"buildings": [&"university", &"monastery", &"siege_workshop"]},
}

var match_state: MatchState
var entity_root: Node
var network_replica := false
var replica_progress: Dictionary = {}
var _jobs: Dictionary = {}


func setup(state: MatchState, entities: Node) -> void:
	match_state = state
	entity_root = entities
	state.age_progression = self


static func age_name(age: int) -> String:
	return AGE_NAMES[clampi(age, Enums.Age.DARK, Enums.Age.IMPERIAL)]


static func requirements_for(target_age: int) -> Dictionary:
	return REQUIREMENTS.get(target_age, {}).duplicate(true)


func is_researching(team: int) -> bool:
	return not replica_progress.get(team, {}).is_empty() if network_replica else _jobs.has(team)


func is_building_researching(building: Node) -> bool:
	if not is_instance_valid(building) or not is_researching(building.team):
		return false
	if network_replica:
		return int(progress_for(building.team).get("building_id", -2)) == int(building.get_meta("net_id", -1))
	return _job_building(building.team) == building


func progress_for(team: int) -> Dictionary:
	if network_replica:
		return replica_progress.get(team, {}).duplicate(true)
	if not _jobs.has(team):
		return {}
	var job: Dictionary = _jobs[team]
	_sync_job_clock(job)
	var building := _job_building(team)
	var building_id := -1
	if is_instance_valid(building):
		building_id = int(building.get_meta("net_id", Registry.id_of(building)))
	return {
		"from_age": int(job.target_age) - 1, "target_age": int(job.target_age),
		"elapsed": Fixed.time_to_seconds(job.elapsed_time), "duration": Fixed.time_to_seconds(job.duration_time),
		"progress": clampf(float(job.elapsed_time) / maxi(1, int(job.duration_time)), 0.0, 1.0),
		"building_id": building_id,
	}


func apply_network_state(records: Array) -> void:
	network_replica = true
	replica_progress.clear()
	for team in Enums.Team.values():
		var record: Dictionary = records[team] if team < records.size() and records[team] is Dictionary else {}
		replica_progress[team] = record.duplicate(true)
		if match_state != null:
			match_state.age_progress_changed.emit(team, replica_progress[team])


func completed_prerequisites(team: int, target_age: int) -> Array[StringName]:
	var found: Array[StringName] = []
	if not is_instance_valid(entity_root) or not REQUIREMENTS.has(target_age):
		return found
	var candidates: Array = REQUIREMENTS[target_age].buildings
	for building in entity_root.get_children():
		if not building is BuildingAgent or not _building_alive(building):
			continue
		if building.team != team or not building.is_complete:
			continue
		var id: StringName = building.def.id
		if (id in candidates or (target_age == Enums.Age.IMPERIAL and id == &"castle")) and id not in found:
			found.append(id)
	return found


func has_prerequisites(team: int, target_age: int) -> bool:
	var found := completed_prerequisites(team, target_age)
	return found.size() >= 2 or (target_age == Enums.Age.IMPERIAL and &"castle" in found)


func blocked_reason(building: Node) -> String:
	if match_state == null or not match_state.progression_enabled:
		return "本局未启用时代升级"
	if match_state.frozen:
		return "对局已暂停或结束"
	if not _building_alive(building) or building.def.id != &"town_center" or building.match_state != match_state:
		return "请选择己方城镇中心"
	if not building.is_complete:
		return "城镇中心尚未建成"
	if not building.train_queue.is_empty() or building.is_technology_researching():
		return "城镇中心正在训练或研究"
	if is_researching(building.team):
		return "己方正在升级时代"
	var target_age := match_state.age_of(building.team) + 1
	if not REQUIREMENTS.has(target_age):
		return "已到达帝王时代"
	if not has_prerequisites(building.team, target_age):
		return "需要两种已建成的当前时代建筑%s" % ("，或一座城堡" if target_age == Enums.Age.IMPERIAL else "")
	var info: Dictionary = REQUIREMENTS[target_age]
	if not match_state.can_afford(building.team, int(info.food), 0, int(info.gold)):
		return "资源不足：需要 %d 食物、%d 黄金" % [info.food, info.gold]
	return ""


func can_advance(building: Node) -> bool:
	return blocked_reason(building).is_empty()


func start_advance(building: Node) -> bool:
	if network_replica or not can_advance(building):
		return false
	var team: int = building.team
	var target_age := match_state.age_of(team) + 1
	var info: Dictionary = REQUIREMENTS[target_age]
	if not match_state.spend(team, int(info.food), 0, int(info.gold)):
		return false
	_jobs[team] = {
		"building": weakref(building), "target_age": target_age,
		"elapsed": 0.0, "duration": float(info.duration),
		"elapsed_time": 0, "duration_time": Fixed.time_from_seconds(info.duration),
		"food": int(info.food), "gold": int(info.gold),
	}
	building.train_queue_changed.emit()
	research_started.emit(team, target_age)
	_emit_progress(team)
	return true


func cancel_advance(team: int, refund: bool = true) -> bool:
	if network_replica or not _jobs.has(team):
		return false
	var job: Dictionary = _jobs[team]
	var building := _job_building(team)
	_jobs.erase(team)
	if refund and match_state != null:
		match_state.add_resource(team, Enums.ResourceType.FOOD, int(job.food))
		match_state.add_resource(team, Enums.ResourceType.GOLD, int(job.gold))
	if is_instance_valid(building):
		building.train_queue_changed.emit()
	research_cancelled.emit(team)
	_emit_progress(team)
	return true


func _process(delta: float) -> void:
	if match_state != null and match_state.lockstep_enabled and not match_state.lockstep_stepping: return
	if network_replica or match_state == null:
		return
	for team in _jobs.keys():
		var building := _job_building(team)
		if not _building_alive(building):
			cancel_advance(team)
			continue
		if match_state.frozen or delta <= 0.0:
			continue
		var job: Dictionary = _jobs[team]
		_sync_job_clock(job)
		job.elapsed_time = mini(int(job.elapsed_time) + Fixed.delta_time(delta, match_state.lockstep_enabled), int(job.duration_time))
		job.elapsed = Fixed.time_to_seconds(job.elapsed_time)
		_emit_progress(team)
		if int(job.elapsed_time) >= int(job.duration_time):
			_jobs.erase(team)
			match_state.set_age(team, int(job.target_age))
			building.train_queue_changed.emit()
			research_completed.emit(team, int(job.target_age))
			_emit_progress(team)


## Import compatibility values only at the API boundary. Simulation advances
## elapsed_time with integer addition; seconds are a presentation mirror.
static func _sync_job_clock(job: Dictionary) -> void:
	if not job.has("duration_time") or (job.has("duration") and float(job.duration) != Fixed.time_to_seconds(job.duration_time)):
		job.duration_time = maxi(1, Fixed.time_from_seconds(float(job.get("duration", 0.0))))
	if not job.has("elapsed_time") or (job.has("elapsed") and float(job.elapsed) != Fixed.time_to_seconds(job.elapsed_time)):
		job.elapsed_time = maxi(0, Fixed.time_from_seconds(float(job.get("elapsed", 0.0))))
	job.duration = Fixed.time_to_seconds(job.duration_time)
	job.elapsed = Fixed.time_to_seconds(job.elapsed_time)


func _emit_progress(team: int) -> void:
	var record := progress_for(team)
	if not record.is_empty():
		research_progress.emit(team, float(record.elapsed), float(record.duration))
	if match_state != null:
		match_state.age_progress_changed.emit(team, record)


func _job_building(team: int) -> Node:
	if not _jobs.has(team):
		return null
	var reference: WeakRef = _jobs[team].building
	return reference.get_ref() as Node


func _building_alive(building: Node) -> bool:
	return is_instance_valid(building) and building is BuildingAgent \
		and not building.is_queued_for_deletion() and building.is_inside_tree() \
		and building.def != null and building.hp > 0.0 and not building.is_placement_ghost


func _exit_tree() -> void:
	for team in _jobs.keys():
		cancel_advance(team)
	if match_state != null and match_state.age_progression == self:
		match_state.age_progression = null
