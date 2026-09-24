class_name MapCatalog
extends RefCounted

## Explicit resource catalog: map files contain IDs, never executable resource paths.
const BUILDINGS := {
	"town_center": preload("res://data/buildings/town_center.tres"),
	"house": preload("res://data/buildings/house.tres"),
	"barracks": preload("res://data/buildings/barracks.tres"),
	"archery_range": preload("res://data/buildings/archery_range.tres"),
	"stable": preload("res://data/buildings/stable.tres"),
	"mill": preload("res://data/buildings/mill.tres"),
	"lumber_camp": preload("res://data/buildings/lumber_camp.tres"),
	"mining_camp": preload("res://data/buildings/mining_camp.tres"),
}
const UNITS := {
	"villager": preload("res://data/units/villager.tres"),
	"swordsman": preload("res://data/units/swordsman.tres"),
	"archer": preload("res://data/units/archer.tres"),
	"chu_ko_nu": preload("res://data/units/chu_ko_nu.tres"),
	"teutonic_knight": preload("res://data/units/teutonic_knight.tres"),
}
const RESOURCES := {"food": Enums.ResourceType.FOOD, "wood": Enums.ResourceType.WOOD, "gold": Enums.ResourceType.GOLD}
const NAMES := {
	"town_center": "城镇中心", "house": "房屋", "barracks": "兵营",
	"archery_range": "靶场", "stable": "马厩", "mill": "磨坊",
	"lumber_camp": "伐木场", "mining_camp": "采矿场",
	"villager": "村民", "swordsman": "剑士", "archer": "弓箭手",
	"chu_ko_nu": "诸葛弩", "teutonic_knight": "条顿武士",
	"food": "浆果 / 食物", "wood": "橡树 / 木材", "gold": "金矿",
}

static func ids(kind: String) -> Array:
	match kind:
		"building": return BUILDINGS.keys()
		"unit": return UNITS.keys()
		"resource": return RESOURCES.keys()
	return []

static func definition_id(record: Dictionary) -> String:
	match record.get("type", ""):
		"building": return record.get("building_id", "")
		"unit": return record.get("unit_id", "")
		"resource": return record.get("resource_type", "")
	return ""

static func half_size(record: Dictionary) -> Vector2:
	var id := definition_id(record)
	match record.get("type", ""):
		"building": return (BUILDINGS[id] as BuildingDef).footprint * 0.5
		"unit": return Vector2.ONE * (UNITS[id] as UnitDef).resolved_footprint_radius()
		"resource": return ResourceNode.selection_footprint(RESOURCES[id]) * 0.5
	return Vector2.ONE

static func make_record(kind: String, id: String, pos: Vector2, team := "player") -> Dictionary:
	var result := {"id": "", "type": kind, "pos": [pos.x, pos.y]}
	match kind:
		"building": result.merge({"building_id": id, "team": team})
		"unit": result.merge({"unit_id": id, "team": team})
		"resource": result.merge({"resource_type": id, "amount": 200.0, "gather_rate": 4.0})
	return result
