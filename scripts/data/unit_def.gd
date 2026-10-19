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
## Original DAT range for display; negative means an authored simulation value.
@export var source_attack_range: float = -1.0
## Ranged only: desired firing distance; 0 uses attack_range * 0.85.
@export var preferred_attack_range: float = 0.0
## Ranged weapons cannot fire at targets inside this distance.
@export var minimum_attack_range: float = 0.0
## Delivery and armor class are independent: thrown stones deal melee damage.
@export var attack_uses_melee_armor: bool = false
@export var attack_class_bonuses: Dictionary = {}
## Negative retains the generic animation-fraction release timing.
@export var attack_release_delay: float = -1.0
@export var projectile_kind: StringName = &"arrow"
@export var projectile_speed: float = 28.0
@export var projectile_splash_radius: float = 0.6
@export var projectile_friendly_fire: bool = false
@export var projectile_arc: float = -0.06
@export var projectile_launch_height: float = 0.0
@export var projectile_flight_sheet: String = ""
@export var projectile_impact_sheet: String = ""
@export var projectile_shadow_sheet: String = ""
@export var projectile_scatter_sheet: String = ""
@export var projectile_scatter_count: int = 0
@export var melee_armor: int
@export var pierce_armor: int
@export var move_speed: float
## Logical circle radius (sim tiles): soft collision + selection ring under feet.
@export var footprint_radius: float = 0.42
## How far this unit can spot hostiles (sim tiles). Used by VisionService.
@export var vision_radius: float = 8.0
## Cumulative original DAT age bonuses, indexed Dark through Imperial.
@export var vision_age_bonus: Array[float] = []
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


func resolved_vision_radius(age: int = Enums.Age.DARK) -> float:
	var bonus := vision_age_bonus[clampi(age, 0, vision_age_bonus.size() - 1)] if not vision_age_bonus.is_empty() else 0.0
	return maxf(0.0, vision_radius + bonus)
