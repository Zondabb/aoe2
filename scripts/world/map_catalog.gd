class_name MapCatalog
extends RefCounted

## Explicit resource catalog: map files contain IDs, never executable resource paths.
const GameCatalogScript := preload("res://scripts/data/game_catalog.gd")
static var BUILDINGS: Dictionary = GameCatalogScript.buildings()
static var UNITS: Dictionary = GameCatalogScript.units()
const RESOURCES := {"food": Enums.ResourceType.FOOD, "wood": Enums.ResourceType.WOOD, "gold": Enums.ResourceType.GOLD, "stone": Enums.ResourceType.STONE}
static var NAMES: Dictionary = _names()

static func _names() -> Dictionary:
	var result := {
	"town_center": "城镇中心", "house": "房屋", "barracks": "兵营",
	"archery_range": "靶场", "stable": "马厩", "mill": "磨坊",
	"lumber_camp": "伐木场", "mining_camp": "采矿场",
	"villager": "村民", "swordsman": "剑士", "archer": "弓箭手",
	"chu_ko_nu": "诸葛弩", "teutonic_knight": "条顿武士",
	"food": "浆果 / 食物", "wood": "橡树 / 木材", "gold": "金矿",
	}
	for key in BUILDINGS: result[key] = BUILDINGS[key].display_name
	for key in UNITS: result[key] = UNITS[key].display_name
	result["stone"] = "石矿"
	return result

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
