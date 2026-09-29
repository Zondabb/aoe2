class_name UnitDef
extends Resource

@export var id: StringName
@export var display_name: String
@export var max_hp: int
@export var attack: int
@export var attack_cooldown: float
@export_group("Combat")
## Maximum distance at which this unit can deal damage (sim tiles).
@export var attack_range: float = 1.0
## Ranged only: desired firing distance; 0 uses attack_range * 0.85.
@export var preferred_attack_range: float = 0.0
@export var melee_armor: int
@export var pierce_armor: int
@export var move_speed: float
## Logical circle radius (sim tiles): soft collision + selection ring under feet.
@export var footprint_radius: float = 0.42
## How far this unit can spot hostiles (sim tiles). Used by VisionService.
@export var vision_radius: float = 8.0
@export var cost_food: int
@export var cost_wood: int
@export var cost_gold: int
@export var cost_stone: int
@export var train_time: float
@export var population: int
@export var is_ranged: bool
@export_group("Technology tree")
@export var required_age: Enums.Age = Enums.Age.DARK
## An empty list makes the unit available to every civilization.
@export var civilizations: Array[StringName] = []
@export var train_at: StringName
@export var required_technology: StringName
@export var upgrades_from: StringName
@export var source_id: int = -1
@export var icon_id: int = -1


func resolved_preferred_attack_range() -> float:
	if preferred_attack_range > 0.0:
		return preferred_attack_range
	if is_ranged:
		return attack_range * 0.85
	return attack_range


func resolved_footprint_radius() -> float:
	if footprint_radius > 0.0:
		return footprint_radius
	return 0.42


func resolved_vision_radius() -> float:
	if vision_radius > 0.0:
		return vision_radius
	return 8.0
