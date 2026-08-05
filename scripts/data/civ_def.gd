class_name CivDef
extends Resource

@export var id: StringName
@export var display_name: String
@export var extra_starting_villagers: int
@export var villager_train_time_mul: float = 1.0
@export var building_hp_mul: float = 1.0
@export var melee_armor_bonus: int
@export var allowed_buildings: Array[Enums.BuildingType] = []
@export var unique_unit: UnitDef
