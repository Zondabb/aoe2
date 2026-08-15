class_name CivAiProfile
extends Resource

@export var civ_id: StringName
@export var villager_target := 8
@export var high_food_stockpile := 400
@export var military_attack_count := 6
@export var attack_time_seconds := 180.0
@export var food_ratio := 0.5
@export var wood_ratio := 0.3
@export var gold_ratio := 0.2
@export var retarget_radius := 8.0
@export var rally_radius := 6.0
@export var build_order: Array[StringName] = [&"house", &"barracks", &"archery_range"]
@export var army_composition: Dictionary = {&"swordsman": 4, &"archer": 2}
@export var unique_unit_priority := true
@export var opening_seconds := 120.0
@export var defend_radius := 20.0


static func for_civ(civ: CivDef) -> CivAiProfile:
	if civ == null:
		return load("res://data/ai/profile_default.tres") as CivAiProfile
	var path := "res://data/ai/profile_%s.tres" % String(civ.id)
	if ResourceLoader.exists(path):
		return load(path) as CivAiProfile
	return load("res://data/ai/profile_default.tres") as CivAiProfile


func ratios_for_phase(phase: int) -> Dictionary:
	# Must match AiDirector.Phase: ECO=0, BOOM=1, ATTACK=2, DEFEND=3
	match phase:
		0:  # ECO
			return {
				Enums.ResourceType.FOOD: 0.6,
				Enums.ResourceType.WOOD: 0.3,
				Enums.ResourceType.GOLD: 0.1,
			}
		1:  # BOOM
			return {
				Enums.ResourceType.FOOD: 0.4,
				Enums.ResourceType.WOOD: 0.35,
				Enums.ResourceType.GOLD: 0.25,
			}
		_:  # ATTACK, DEFEND
			return {
				Enums.ResourceType.FOOD: 0.3,
				Enums.ResourceType.WOOD: 0.3,
				Enums.ResourceType.GOLD: 0.4,
			}
