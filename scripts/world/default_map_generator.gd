class_name DefaultMapGenerator
extends RefCounted

## Original 1v1 / tiny map size, expressed in the same distance scale as DAT LOS.
## The local Green Arabia RMS supplies group sizes / starting resource distances.
const MAP_ORIGINAL_TILES := 120
const WORLD_DISTANCE_SCALE := 4.0
const DEFAULT_SIZE := 480
const DEFAULT_SEED := 54000120
const BASE_POSITION := Vector2(-120, -120)
const BASE_CLEAR_RADIUS := 30.0
const FOREST_NODE_COUNT := 70
const TREE_SPACING := 4.0
const RESOURCE_AMOUNTS := {"food": 125.0, "wood": 100.0, "gold": 800.0, "stone": 350.0}
const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const CHINESE := preload("res://data/civs/chinese.tres")
const TEUTONS := preload("res://data/civs/teutons.tres")

static func generate(seed_value := DEFAULT_SEED, player_civ_id: StringName = &"chinese", ai_civ_id: StringName = &"teutons") -> Dictionary:
	var data := Data.create(DEFAULT_SIZE, DEFAULT_SIZE, "经典双营地 · 陆地")
	data["generator"] = {"id": "classic_land", "version": 1, "seed": seed_value, "original_tiles": MAP_ORIGINAL_TILES, "distance_scale": WORLD_DISTANCE_SCALE}
	var random := RandomNumberGenerator.new()
	random.seed = seed_value
	_add_base(data, "player", "Player", BASE_POSITION, player_civ_id)
	_add_base(data, "ai", "Ai", -BASE_POSITION, ai_civ_id)
	# Keep both halves rotationally symmetric. The local RMS places main berries
	# 10–12 tiles away, main gold 12–16, and main stone 14–18.
	_add_mirrored_cluster(data, "food", "FoodBush", BASE_POSITION + Vector2(30, 30), 6, 2.6, "home_food")
	_add_mirrored_cluster(data, "gold", "GoldMine", BASE_POSITION + Vector2(52, -16), 7, 3.4, "home_gold")
	_add_mirrored_cluster(data, "stone", "StoneMine", BASE_POSITION + Vector2(-16, 62), 5, 3.4, "home_stone")
	_add_mirrored_cluster(data, "gold", "SecondaryGold", Vector2(-42, -88), 4, 3.4, "secondary_gold_1")
	_add_mirrored_cluster(data, "gold", "RemoteGold", Vector2(-72, 36), 4, 3.4, "secondary_gold_2")
	_add_mirrored_cluster(data, "stone", "SecondaryStone", Vector2(-208, -66), 4, 3.4, "secondary_stone")
	_add_mirrored_cluster(data, "food", "SecondaryFood", Vector2(-126, 4), 6, 2.6, "secondary_food")
	_add_mirrored_cluster(data, "gold", "NeutralGold", Vector2(-24, 24), 5, 3.4, "neutral_gold")
	_add_mirrored_cluster(data, "stone", "NeutralStone", Vector2(-20, -12), 4, 3.4, "neutral_stone")
	var forest_centers := [Vector2(-120, -188), Vector2(-188, -120), Vector2(-195, -195), Vector2(-160, -24), Vector2(-40, -185), Vector2(-52, -40), Vector2(-195, 60)]
	for index in forest_centers.size():
		_add_forest_pair(data, forest_centers[index], index, random)
	return data

static func _add_base(data: Dictionary, team: String, prefix: String, origin: Vector2, civ_id: StringName) -> void:
	var town := Catalog.make_record("building", "town_center", origin, team)
	town.id = prefix + "TownCenter"
	data.entities.append(town)
	var civ: CivDef = TEUTONS if civ_id == &"teutons" else CHINESE
	var direction := 1.0 if team == "player" else -1.0
	var offsets := [Vector2(5, 0), Vector2(3.5, 3.5), Vector2(0, 5), Vector2(5, 5)]
	for index in 3 + civ.extra_starting_villagers:
		var villager := Catalog.make_record("unit", "villager", origin + offsets[index] * direction, team)
		villager.id = "%sVillager%d" % [prefix, index + 1]
		data.entities.append(villager)
	var scout := Catalog.make_record("unit", "scout_cavalry", origin + Vector2(14, -8) * direction, team)
	scout.id = prefix + "Scout"
	data.entities.append(scout)

static func _add_mirrored_cluster(data: Dictionary, kind: String, suffix: String, center: Vector2, count: int, spacing: float, group: String) -> void:
	var offsets := [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT, Vector2.UP, Vector2(1, 1), Vector2(-1, -1)]
	for side in 2:
		var sign_value := 1.0 if side == 0 else -1.0
		var prefix := "Player" if side == 0 else "Ai"
		for index in count:
			var point: Vector2 = (center + offsets[index] * spacing) * sign_value
			var id := prefix + suffix + ("" if index == 0 else str(index + 1))
			_add_resource(data, kind, id, point, prefix + "_" + group)

static func _add_forest_pair(data: Dictionary, center: Vector2, forest_index: int, random: RandomNumberGenerator) -> void:
	var candidates: Array[Dictionary] = []
	var ellipse := Vector2(random.randf_range(0.92, 1.14), random.randf_range(0.9, 1.08))
	for x in range(-6, 7):
		for y in range(-6, 7):
			var cell := Vector2(x, y) * TREE_SPACING
			var score := (cell / ellipse).length_squared() + random.randf_range(-24, 24)
			candidates.append({"offset": cell + Vector2(random.randf_range(-0.25, 0.25), random.randf_range(-0.25, 0.25)), "score": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score < b.score)
	var points: Array[Vector2] = []
	for candidate in candidates:
		var point: Vector2 = center + candidate.offset
		if not _tree_space_available(data, point): continue
		points.append(point)
		if points.size() == FOREST_NODE_COUNT: break
	# The named home tree is on the reachable forest edge, so legacy gather
	# orders and the first-click target never point into the center of a grove.
	points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_squared_to(BASE_POSITION) < b.distance_squared_to(BASE_POSITION))
	var added := 0
	for point in points:
		var group := "forest_%02d" % (forest_index + 1)
		var suffix := "Tree" if forest_index == 0 and added == 0 else "Forest%02dTree%03d" % [forest_index + 1, added + 1]
		_add_resource(data, "wood", "Player" + suffix, point, "Player_" + group)
		_add_resource(data, "wood", "Ai" + suffix, -point, "Ai_" + group)
		added += 1

static func _tree_space_available(data: Dictionary, point: Vector2) -> bool:
	if point.distance_to(BASE_POSITION) < BASE_CLEAR_RADIUS or point.distance_to(-BASE_POSITION) < BASE_CLEAR_RADIUS: return false
	if absf(point.x) > DEFAULT_SIZE * 0.5 - 8 or absf(point.y) > DEFAULT_SIZE * 0.5 - 8: return false
	for other in data.entities:
		if other.type != "resource" or other.resource_type == "wood": continue
		# Leave a wide working band around ore / berry clusters for camps and workers.
		if Data.position_of(other).distance_to(point) < 12.0: return false
	return true

static func _add_resource(data: Dictionary, kind: String, id: String, point: Vector2, group: String) -> void:
	var record := Catalog.make_record("resource", kind, point)
	record.id = id
	record.amount = RESOURCE_AMOUNTS[kind]
	if kind == "wood": record["block_size"] = [TREE_SPACING, TREE_SPACING]
	record["resource_group"] = group
	data.entities.append(record)
