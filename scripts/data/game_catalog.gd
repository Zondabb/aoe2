class_name GameCatalog
extends RefCounted

## Read-only original-game definitions. JSON IDs are data, never resource paths.
const PATH := "res://data/civilization_catalog.json"
const AGE_NAMES := ["黑暗时代", "封建时代", "城堡时代", "帝王时代"]
## Adapt original DAT movement to this project's map scale and pre-import pace.
## Keep the source catalog intact and preserve relative speeds across unit lines.
const MOVEMENT_SPEED_SCALE := 4.0
static var _data: Dictionary = {}
static var _units: Dictionary = {}
static var _buildings: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty() and FileAccess.file_exists(PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary: _data = parsed
	return _data

static func unit_record(id: StringName) -> Dictionary:
	return data().get("units", {}).get(String(id), {})

static func building_record(id: StringName) -> Dictionary:
	return data().get("buildings", {}).get(String(id), {})

static func technologies() -> Dictionary:
	return data().get("technologies", data().get("techs", {}))

static func _cost(record: Dictionary, key: String) -> int:
	return int(record.get("cost", {}).get(key, 0))

static func units() -> Dictionary:
	if not _units.is_empty(): return _units
	for key in data().get("units", {}):
		var r: Dictionary = unit_record(key)
		var u := UnitDef.new()
		u.id = StringName(key)
		u.display_name = r.get("display_name", key)
		u.source_id = int(r.get("source_id", -1))
		u.max_hp = int(r.get("hp", 30))
		u.attack = int(r.get("attack", 0))
		u.attack_cooldown = maxf(0.1, float(r.get("cooldown", 2)))
		u.attack_range = maxf(0.4, float(r.get("attack_range", 0.4)))
		u.is_ranged = u.attack_range > 1.5
		u.preferred_attack_range = u.attack_range * 0.85 if u.is_ranged else 0.0
		u.melee_armor = int(r.get("melee_armor", 0))
		u.pierce_armor = int(r.get("pierce_armor", 0))
		u.move_speed = maxf(0.1, float(r.get("speed", 0.8))) * MOVEMENT_SPEED_SCALE
		u.footprint_radius = clampf(float(r.get("radius", 0.35)), 0.2, 1.0)
		u.vision_radius = maxf(0, float(r.get("vision", 6)))
		u.vision_age_bonus.assign(r.get("vision_age_bonus", []))
		u.cost_food = _cost(r, "food")
		u.cost_wood = _cost(r, "wood")
		u.cost_gold = _cost(r, "gold")
		u.cost_stone = _cost(r, "stone")
		u.train_time = maxf(0.1, float(r.get("train_time", 20)))
		u.population = int(r.get("population", 1))
		u.required_age = int(r.get("required_age", 0))
		u.civilizations.assign(r.get("civilizations", ["chinese", "teutons"]))
		u.train_at = StringName(r.get("train_at", ""))
		u.icon_id = int(r.get("icon_id", 0))
		u.required_technology = StringName(r.get("required_technology", ""))
		u.upgrades_from = StringName(r.get("upgrades_from", ""))
		_units[key] = u
	# Existing authored maps keep their old swordsman ID; ordinary production uses militia.
	if not _units.has("swordsman"):
		_units["swordsman"] = load("res://data/units/swordsman.tres")
	return _units

static func buildings() -> Dictionary:
	if not _buildings.is_empty(): return _buildings
	for key in data().get("buildings", {}):
		var r: Dictionary = building_record(key)
		var b := BuildingDef.new()
		b.id = StringName(key)
		b.display_name = r.get("display_name", key)
		b.source_id = int(r.get("source_id", -1))
		b.max_hp = int(r.get("hp", 1000))
		var footprint: Array = r.get("footprint", [3,3])
		b.footprint = Vector2(footprint[0], footprint[1])
		b.blocks_movement = key not in ["town_center", "farm", "gate", "palisade_gate"]
		b.vision_radius = maxf(0, float(r.get("vision", 8)))
		b.vision_age_bonus.assign(r.get("vision_age_bonus", []))
		b.melee_armor = int(r.get("melee_armor", 0))
		b.pierce_armor = int(r.get("pierce_armor", 0))
		b.cost_food = _cost(r, "food")
		b.cost_wood = _cost(r, "wood")
		b.cost_gold = _cost(r, "gold")
		b.cost_stone = _cost(r, "stone")
		b.build_time = maxf(0.1, float(r.get("build_time", 30)))
		b.population_provided = int(r.get("population_provided", 0))
		b.required_age = int(r.get("required_age", 0))
		b.icon_id = int(r.get("icon_id", 0))
		b.civilizations.assign(r.get("civilizations", ["chinese", "teutons"]))
		b.prerequisites.assign(r.get("prerequisites", r.get("required_buildings", [])))
		b.has_drop_off = key in ["town_center", "mill", "lumber_camp", "mining_camp"]
		b.drop_off = Enums.ResourceType.WOOD if key == "lumber_camp" else Enums.ResourceType.GOLD if key == "mining_camp" else Enums.ResourceType.FOOD
		_buildings[key] = b
	return _buildings

static func get_unit(id: StringName) -> UnitDef:
	return units().get(String(id)) as UnitDef

static func get_building(id: StringName) -> BuildingDef:
	return buildings().get(String(id)) as BuildingDef

static func display_name(id: StringName) -> String:
	var record := unit_record(id)
	if record.is_empty(): record = building_record(id)
	if record.is_empty(): record = technologies().get(String(id), {})
	return String(record.get("display_name", id))

static func civilization_allows(record: Dictionary, civ_id: StringName) -> bool:
	var allowed: Array = record.get("civilizations", [])
	return allowed.is_empty() or String(civ_id) in allowed

static func building_reason(state: MatchState, team: int, civ: CivDef, definition: BuildingDef, entities: Node) -> String:
	if definition == null or state == null or state.frozen: return "当前无法建造"
	if not state.progression_enabled and civ != null and definition.id == &"stable" and Enums.BuildingType.STABLE not in civ.allowed_buildings: return "此文明不能建造"
	if state.progression_enabled:
		if civ != null and not definition.civilizations.is_empty() and civ.id not in definition.civilizations:
			return "此文明不能建造"
		if state.age_of(team) < definition.required_age: return "需要" + AGE_NAMES[definition.required_age]
		var record := building_record(definition.id)
		var research := String(record.get("required_technology", ""))
		if not research.is_empty() and not state.researched_technologies.get(team, {}).has(research): return "需要研究：" + display_name(research)
		for required in definition.prerequisites:
			if not has_building(entities, team, required): return "需要已建成的" + display_name(required)
	if not state.can_afford(team, definition.cost_food, definition.cost_wood, definition.cost_gold, definition.cost_stone): return "资源不足"
	return ""

static func has_building(entities: Node, team: int, id: StringName) -> bool:
	if entities == null: return false
	for entity in entities.get_children():
		if entity.get("def") is BuildingDef and entity.team == team and entity.def != null and entity.def.id == id and entity.is_complete and entity.hp > 0 and not entity.is_placement_ghost and not entity.is_queued_for_deletion(): return true
	return false

static func unit_sheet(id: StringName, action: StringName) -> String:
	return String(unit_record(id).get("sprites", {}).get(String(action), ""))

static func building_sheet(id: StringName, civ_id: StringName, age: int) -> String:
	var sheets: Dictionary = building_record(id).get("sprites", {}).get(String(civ_id), {})
	for era in range(clampi(age, 0, 3), -1, -1):
		if sheets.has(str(era)): return sheets[str(era)]
	return ""

static func techs() -> Dictionary:
	return technologies()

static func is_upgrade(source: String, target: String) -> bool:
	if source == target: return true
	var visited := {source:true}
	var queue: Array = [source]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for tech in technologies().values():
			for pair in tech.get("upgrades",[]):
				if pair.from != current: continue
				if pair.to == target: return true
				if not visited.has(pair.to):
					visited[pair.to] = true
					queue.append(pair.to)
	return false
