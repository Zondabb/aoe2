class_name BuildingDef
extends Resource

@export var id: StringName
@export var max_hp: int
@export var footprint: Vector2
@export var melee_armor: int = 0
@export var pierce_armor: int = 0
@export var cost_food: int
@export var cost_wood: int
@export var cost_gold: int
@export var build_time: float
@export var population_provided: int
@export var trainable: Array[UnitDef] = []
@export var has_drop_off: bool
@export var drop_off: Enums.ResourceType = Enums.ResourceType.FOOD
