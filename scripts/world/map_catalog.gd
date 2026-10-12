class_name MapCatalog
extends RefCounted

## Explicit resource catalog: map files contain IDs, never executable resource paths.
const GameCatalogScript := preload("res://scripts/data/game_catalog.gd")
static var BUILDINGS: Dictionary = GameCatalogScript.buildings()
static var UNITS: Dictionary = GameCatalogScript.units()
const RESOURCES := {"food": Enums.ResourceType.FOOD, "wood": Enums.ResourceType.WOOD, "gold": Enums.ResourceType.GOLD, "stone": Enums.ResourceType.STONE}
const TERRAINS := {"water": "水域", "cliff": "悬崖"}
const TERRAIN_DEFAULT_SIZES := {"water": Vector2(16, 12), "cliff": Vector2(16, 4)}
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
	result.merge(TERRAINS)
	return result

static func ids(kind: String) -> Array:
	match kind:
		"building": return BUILDINGS.keys()
		"unit": return UNITS.keys()
		"resource": return RESOURCES.keys()
		"terrain": return TERRAINS.keys()
	return []

static func definition_id(record: Dictionary) -> String:
	match record.get("type", ""):
		"building": return record.get("building_id", "")
		"unit": return record.get("unit_id", "")
		"resource": return record.get("resource_type", "")
		"terrain": return record.get("terrain_id", "")
	return ""

static func half_size(record: Dictionary) -> Vector2:
	var id := definition_id(record)
	match record.get("type", ""):
		"building": return (BUILDINGS[id] as BuildingDef).footprint * 0.5
		"unit": return Vector2.ONE * (UNITS[id] as UnitDef).resolved_footprint_radius()
		"resource":
			if record.has("block_size"): return Vector2(record.block_size[0],record.block_size[1]) * 0.5
			return ResourceNode.selection_footprint(RESOURCES[id]) * 0.5
		"terrain":
			if record.has("block_size"): return Vector2(record.block_size[0], record.block_size[1]) * 0.5
			return terrain_size(id) * 0.5
	return Vector2.ONE

static func terrain_size(id: String) -> Vector2:
	return TERRAIN_DEFAULT_SIZES.get(id, Vector2(16, 12))

static func make_record(kind: String, id: String, pos: Vector2, team := "player") -> Dictionary:
	var result := {"id": "", "type": kind, "pos": [pos.x, pos.y]}
	match kind:
		"building": result.merge({"building_id": id, "team": team})
		"unit": result.merge({"unit_id": id, "team": team})
		"resource": result.merge({"resource_type": id, "amount": 200.0, "gather_rate": 4.0})
		"terrain":
			var size := terrain_size(id)
			result.merge({"terrain_id": id, "block_size": [size.x, size.y]})
	return result
