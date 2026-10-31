class_name TechnologyProgression
extends Node

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const AgeClock := preload("res://scripts/systems/age_progression.gd")
var state: MatchState
var entities: Node
var jobs: Dictionary = {}
var replica := false

func setup(value: MatchState, root: Node) -> void:
	state = value
	entities = root
	state.technology_progression = self

## Catalog ids grouped by their research_at value, in catalog order. Rebuilt
## whenever the catalog dictionary itself is replaced.
static var _ids_by_research_at: Dictionary = {}
static var _ids_source: Dictionary = {}

static func _ids_researched_at(building_id: String) -> Array:
	var all := Catalog.technologies()
	if not is_same(all, _ids_source):
		_ids_by_research_at = {}
		for id in all:
			var at: Variant = all[id].get("research_at", "")
			if not _ids_by_research_at.has(at): _ids_by_research_at[at] = []
			_ids_by_research_at[at].append(id)
		_ids_source = all
	return _ids_by_research_at.get(building_id, [])

## Walls, houses and other buildings that research nothing skip the catalog.
func available(building: BuildingAgent) -> Array[String]:
	var result: Array[String] = []
	if not is_instance_valid(building) or building.def == null: return result
	for id in _ids_researched_at(String(building.def.id)):
		var tech: Dictionary = Catalog.technologies()[id]
		if not Catalog.civilization_allows(tech, building.civ.id): continue
		if state.researched_technologies.get(building.team, {}).has(id): continue
		# Show the next upgrade in each branch, even while its age is locked.
		var required := String(tech.get("prerequisite_technology", ""))
		if not required.is_empty() and not state.researched_technologies.get(building.team, {}).has(required): continue
		result.append(id)
	return result

func blocked_reason(building: BuildingAgent, id: String) -> String:
	if not is_instance_valid(building) or state == null or state.frozen or not state.progression_enabled: return "当前无法研究"
	if building.hp <= 0 or not building.is_complete or building.is_placement_ghost: return "需要已建成的建筑"
	if id not in available(building): return "此文明或建筑不能研究该科技"
	if not building.train_queue.is_empty() or building.is_age_researching() or is_researching(building): return "建筑正在生产或研究"
	for job in jobs.values():
		if job.team == building.team and job.technology_id == id: return "已经在研究"
	var tech: Dictionary = Catalog.technologies()[id]
	var age := int(tech.get("required_age", 0))
	if state.age_of(building.team) < age: return "需要" + Catalog.AGE_NAMES[age]
	var c: Dictionary = tech.get("cost", {})
	if not state.can_afford(building.team, int(c.get("food",0)), int(c.get("wood",0)), int(c.get("gold",0)), int(c.get("stone",0))): return "资源不足"
	return ""

func start_research(building: BuildingAgent, id: String) -> bool:
	if replica or not blocked_reason(building, id).is_empty(): return false
	var tech: Dictionary = Catalog.technologies()[id]
	var c: Dictionary = tech.get("cost", {})
	if not state.spend(building.team, int(c.get("food",0)), int(c.get("wood",0)), int(c.get("gold",0)), int(c.get("stone",0))): return false
	jobs[building.get_instance_id()] = {"building": weakref(building), "building_id": building.get_instance_id(), "technology_id": id, "team": building.team, "elapsed": 0.0, "progress": 0.0, "duration": maxf(0.1,float(tech.get("time",30))), "cost":c.duplicate()}
	AgeClock._sync_job_clock(jobs[building.get_instance_id()])
	building.train_queue_changed.emit()
	return true

func is_researching(building: BuildingAgent) -> bool:
	return is_instance_valid(building) and jobs.has(building.get_instance_id())

func progress_for(building: BuildingAgent) -> Dictionary:
	if not is_instance_valid(building) or not jobs.has(building.get_instance_id()): return {}
	var job: Dictionary = jobs[building.get_instance_id()]
	AgeClock._sync_job_clock(job)
	return {"technology_id":job.technology_id,"elapsed":job.elapsed,"duration":job.duration,"progress":clampf(float(job.elapsed_time) / maxi(1, int(job.duration_time)), 0.0, 1.0),"team":job.team,"building_id":job.building_id}

func cancel_research(building: BuildingAgent) -> bool:
	if replica or not is_researching(building): return false
	var job: Dictionary = jobs[building.get_instance_id()]
	_refund(job)
	jobs.erase(building.get_instance_id())
	building.train_queue_changed.emit()
	return true

func _refund(job: Dictionary) -> void:
	var c: Dictionary = job.get("cost", {})
	for i in 4:
		state.add_resource(job.team, i, int(c.get(["food","wood","gold","stone"][i],0)))

func _process(delta: float) -> void:
	if state != null and state.lockstep_enabled and not state.lockstep_stepping: return
	if state == null or replica or state.frozen: return
	for key in jobs.keys():
		var job: Dictionary = jobs[key]
		var building: Variant = job.building.get_ref()
		if not is_instance_valid(building) or building.is_queued_for_deletion() or building.hp <= 0:
			_refund(job)
			jobs.erase(key)
			continue
		AgeClock._sync_job_clock(job)
		job.elapsed_time = mini(int(job.elapsed_time) + Fixed.delta_time(delta, state.lockstep_enabled), int(job.duration_time))
		job.elapsed = Fixed.time_to_seconds(job.elapsed_time)
		job.progress = clampf(float(job.elapsed_time) / maxi(1, int(job.duration_time)), 0.0, 1.0)
		if int(job.elapsed_time) < int(job.duration_time): continue
		jobs.erase(key)
		_complete(job.team, job.technology_id)
		building.train_queue_changed.emit()

func _complete(team: int, id: String) -> void:
	state.researched_technologies[team][id] = true
	var tech: Dictionary = Catalog.technologies()[id]
	var source := StringName(tech.get("from", ""))
	var target := StringName(tech.get("to", ""))
	var upgraded := Catalog.get_unit(target)
	var upgraded_building := Catalog.get_building(target)
	for entity in entities.get_children():
		if entity.get("team") != team or entity.get("hp") == null or entity.hp <= 0: continue
		if entity is UnitAgent and upgraded != null and entity.def.id == source:
			entity.apply_definition_upgrade(upgraded)
		elif entity is BuildingAgent:
			if upgraded_building != null and entity.def.id == source:
				entity.apply_definition_upgrade(upgraded_building)
			# Existing training is upgraded without charging the player twice.
			for i in entity.train_queue.size():
				if upgraded != null and entity.train_queue[i].id == source: entity.train_queue[i] = upgraded
	state.technology_changed.emit(team, StringName(id))
	if state.fog != null: state.fog.dirty = true

func apply_network_state(records: Array) -> void:
	replica = true
	jobs.clear()
	for record in records:
		for entity in entities.get_children():
			if not entity is BuildingAgent or int(entity.get_meta("net_id",-1)) != int(record.get("building_id",-2)): continue
			var job: Dictionary = record.duplicate()
			job.building = weakref(entity)
			jobs[entity.get_instance_id()] = job
			break
