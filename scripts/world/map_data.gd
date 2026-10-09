class_name MapData
extends RefCounted

const Catalog := preload("res://scripts/world/map_catalog.gd")
const FORMAT := "aoe2-rts-map"
const VERSION := 1
const MIN_SIZE := 16
const MAX_SIZE := 1024
const MAX_ENTITIES := 2000

static func create(width := 80, height := 80, title := "未命名地图") -> Dictionary:
	var minimum := Vector2i(-floori(width / 2.0), -floori(height / 2.0))
	return {
		"format": FORMAT, "schema_version": VERSION, "display_name": title,
		"bounds": {"min": [minimum.x, minimum.y], "max": [minimum.x + width, minimum.y + height]},
		"entities": [],
	}

static func bounds(data: Dictionary) -> Rect2:
	var minimum: Array = data.bounds.min
	var maximum: Array = data.bounds.max
	var origin := Vector2(minimum[0], minimum[1])
	return Rect2(origin, Vector2(maximum[0], maximum[1]) - origin)

static func position_of(record: Dictionary) -> Vector2:
	return Vector2(record.pos[0], record.pos[1])

## JSON parses every number as float. Restore the integer fields after validation
## so save/load cycles and no-op settings changes have stable document identities.
static func normalized(data: Dictionary) -> Dictionary:
	var result := data.duplicate(true)
	result.schema_version = int(result.schema_version)
	for key in ["min", "max"]:
		result.bounds[key] = [int(result.bounds[key][0]), int(result.bounds[key][1])]
	return result

static func number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func vector(value: Variant) -> bool:
	return value is Array and value.size() == 2 and number(value[0]) and number(value[1])

## Validate before converting/casting input so corrupt JSON never changes the open map.
static func validate(data: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not data is Dictionary:
		return PackedStringArray(["文件根节点必须是 JSON 对象。"])
	if data.get("format") != FORMAT or not number(data.get("schema_version")) or data.get("schema_version") != VERSION:
		errors.append("不支持的地图格式或版本（需要 aoe2-rts-map / 1）。")
	if not data.get("display_name") is String or data.get("display_name", "").strip_edges().is_empty() or data.get("display_name", "").length() > 120:
		errors.append("地图名称需要 1–120 个字符。")
	var box: Variant = data.get("bounds")
	if not box is Dictionary or not vector(box.get("min")) or not vector(box.get("max")):
		errors.append("bounds.min / max 必须是两个有限数值组成的数组。")
		return errors
	var rect := bounds(data)
	for value in box.min + box.max:
		if float(value) != floorf(float(value)) or absf(float(value)) > 10000:
			errors.append("地图边界必须是 -10000 到 10000 内的整数。")
			break
	if rect.size.x < MIN_SIZE or rect.size.y < MIN_SIZE or rect.size.x > MAX_SIZE or rect.size.y > MAX_SIZE:
		errors.append("地图宽、高必须分别在 %d–%d 格之间。" % [MIN_SIZE, MAX_SIZE])
	if not data.get("entities") is Array:
		errors.append("entities 必须是数组。")
		return errors
	if data.entities.size() > MAX_ENTITIES:
		errors.append("单张地图最多 %d 个对象。" % MAX_ENTITIES)
		return errors
	var ids := {}
	for i in data.entities.size():
		var record: Variant = data.entities[i]
		var prefix := "对象 #%d：" % (i + 1)
		if not record is Dictionary:
			errors.append(prefix + "必须是 JSON 对象。")
			continue
		var id: Variant = record.get("id")
		if not id is String or id.is_empty() or id.length() > 80:
			errors.append(prefix + "id 需要 1–80 个字符。")
		elif ids.has(id):
			errors.append(prefix + "id 重复：" + id)
		else:
			ids[id] = true
		var kind: Variant = record.get("type")
		if kind not in ["building", "unit", "resource"]:
			errors.append(prefix + "未知对象类型。")
			continue
		var key: String = {"building": "building_id", "unit": "unit_id", "resource": "resource_type"}[kind]
		if record.get(key) not in Catalog.ids(kind):
			errors.append(prefix + "未知的 " + key + "。")
			continue
		if kind != "resource" and record.get("team") not in ["player", "ai"]:
			errors.append(prefix + "team 必须是 player 或 ai。")
		if kind == "resource":
			if record.has("block_size"):
				var size: Variant = record.block_size
				if not vector(size) or size[0] <= 0 or size[1] <= 0 or size[0] > 64 or size[1] > 64:
					errors.append(prefix + "block_size 必须是两个大于 0 且不超过 64 的有限数值。")
					continue
			for field in ["amount", "gather_rate"]:
				var value: Variant = record.get(field)
				if not number(value) or value <= 0 or value > 1000000:
					errors.append(prefix + field + " 必须大于 0 且不超过 1000000。")
		if not vector(record.get("pos")):
			errors.append(prefix + "pos 必须是两个有限数值组成的数组。")
			continue
		var point := position_of(record)
		var half := Catalog.half_size(record)
		if not rect.encloses(Rect2(point - half, half * 2.0)):
			errors.append(prefix + "占地超出地图边界。")
	return errors

## Placement disallows footprint overlaps, but imported scenarios may intentionally overlap.
static func placement_error(data: Dictionary, record: Dictionary, except_id := "") -> String:
	var point := position_of(record)
	var half := Catalog.half_size(record)
	var footprint := Rect2(point - half, half * 2.0)
	if not bounds(data).encloses(footprint):
		return "对象占地超出地图边界。"
	for other in data.entities:
		if other.id == except_id:
			continue
		var other_half := Catalog.half_size(other)
		if footprint.intersects(Rect2(position_of(other) - other_half, other_half * 2.0)):
			return "占地与 %s 重叠，请留出空隙。" % other.id
	return ""

static func next_id(data: Dictionary) -> String:
	var used := {}
	for record in data.entities:
		used[record.id] = true
	var index := 1
	while used.has("entity_%04d" % index):
		index += 1
	return "entity_%04d" % index
