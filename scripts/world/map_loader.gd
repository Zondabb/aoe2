class_name MapLoader
extends RefCounted

const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const CHINESE := preload("res://data/civs/chinese.tres")
const TEUTONS := preload("res://data/civs/teutons.tres")
const MAX_FILE_BYTES := 4 * 1024 * 1024

static func load_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "无法打开地图：%s" % error_string(FileAccess.get_open_error())}
	if file.get_length() > MAX_FILE_BYTES:
		return {"error": "地图文件超过 4 MiB。"}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK:
		return {"error": "JSON 第 %d 行：%s" % [json.get_error_line(), json.get_error_message()]}
	var errors := Data.validate(json.data)
	if not errors.is_empty():
		return {"error": "\n".join(errors)}
	return {"data": Data.normalized(json.data)}

static func save_file(data: Dictionary, path: String) -> String:
	var errors := Data.validate(data)
	if not errors.is_empty():
		return "\n".join(errors)
	# Replace only after the entire formatted UTF-8 document has been written.
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return "无法写入地图：%s" % error_string(FileAccess.get_open_error())
	file.store_string(JSON.stringify(data, "  ", true, true) + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		DirAccess.remove_absolute(temporary)
		return "保存失败，原文件保留：%s" % error_string(error)
	return ""

static func spawn_entity(record: Dictionary, parent: Node2D, state: MatchState, editing := false) -> Node2D:
	var entity: Node2D
	var id := Catalog.definition_id(record)
	match record.type:
		"building":
			entity = BUILDING_VIEW.instantiate()
			entity.set("def", Catalog.BUILDINGS[id])
			entity.set("accepts_all_resources", id == "town_center")
		"unit":
			entity = UNIT_VIEW.instantiate()
			entity.set("def", Catalog.UNITS[id])
		"resource":
			entity = ResourceNode.new()
			entity.set("resource_type", Catalog.RESOURCES[id])
			entity.set("amount", float(record.amount))
			entity.set("gather_rate", float(record.gather_rate))
	if entity == null:
		return null
	if record.type != "resource":
		var team := Enums.Team.PLAYER if record.team == "player" else Enums.Team.AI
		entity.set("team", team)
		entity.set("civ", CHINESE if team == Enums.Team.PLAYER else TEUTONS)
		entity.set("match_state", state)
	entity.set("sim_pos", Data.position_of(record))
	entity.set_meta("map_id", record.id)
	entity.set_meta("map_record", record.duplicate(true))
	if editing:
		entity.process_mode = Node.PROCESS_MODE_DISABLED
	parent.add_child(entity)
	return entity

static func spawn_entities(data: Dictionary, parent: Node2D, state: MatchState, editing := false) -> void:
	for record in data.entities:
		spawn_entity(record, parent, state, editing)

static func setup_ground(data: Dictionary, parent: Node2D) -> void:
	for child in parent.get_children():
		child.free()
	var rect := Data.bounds(data)
	var polygon := Polygon2D.new()
	var points := PackedVector2Array()
	for point in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		points.append(IsoMath.world_to_screen(point))
	polygon.polygon = points
	polygon.texture = preload("res://assets/terrain/grass.png")
	polygon.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	polygon.texture_scale = Vector2(0.35, 0.35)
	polygon.z_index = -100
	parent.add_child(polygon)
