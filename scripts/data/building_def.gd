class_name BuildingDef
extends Resource

@export var id: StringName
@export var display_name: String
@export var max_hp: int
@export var footprint: Vector2
## Movement can pass beneath an open building while its placement footprint stays intact.
@export var blocks_movement := true
@export var vision_radius := 16.0
## Cumulative original DAT age bonuses, indexed Dark through Imperial.
@export var vision_age_bonus: Array[float] = []
@export var construction_vision_radius := 2.0
@export var melee_armor: int = 0
@export var pierce_armor: int = 0
@export var cost_food: int
@export var cost_wood: int
@export var cost_gold: int
@export var cost_stone: int
@export var build_time: float
@export var population_provided: int
@export var trainable: Array[UnitDef] = []
@export var has_drop_off: bool
@export var drop_off: Enums.ResourceType = Enums.ResourceType.FOOD
@export_group("Technology tree")
@export var required_age: Enums.Age = Enums.Age.DARK
@export var prerequisites: Array[StringName] = []
@export var civilizations: Array[StringName] = []
@export var source_id: int = -1
@export var icon_id: int = -1

func resolved_vision_radius(age: int = Enums.Age.DARK) -> float:
	var bonus := vision_age_bonus[clampi(age, 0, vision_age_bonus.size() - 1)] if not vision_age_bonus.is_empty() else 0.0
	return maxf(0.0, vision_radius + bonus)
