extends SceneTree

const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
const Loader := preload("res://scripts/world/map_loader.gd")
const Document := preload("res://scripts/world/map_document.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	root.size = Vector2i(1280, 720)
	_test_validation()
	_test_document()
	_test_files()
	_test_rectangular_nav()
	var editor: Node2D = load("res://scenes/editor/map_editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	check(editor.document.data.entities.is_empty(), "editor starts with a blank map")
	check(editor._ui.size == Vector2(1280, 720), "UI fills the viewport")
	editor._width.value = 64
	editor._height.value = 32
	editor._name_edit.text = "自动化测试地图"
	editor._apply_settings()
	check(Data.bounds(editor.document.data).size == Vector2(64, 32), "settings apply rectangular dimensions")
	check(editor._nav.nav.get_map_rect().size == Vector2(64, 32), "editor nav uses rectangular dimensions")
	editor._kind = "building"
	editor._brush_id = "town_center"
	check(editor.place_at(Vector2(-12, -6)), "place a town center")
	editor._kind = "resource"
	editor._brush_id = "wood"
	check(editor.place_at(Vector2(-5, -5)), "place a tree")
	editor._kind = "unit"
	editor._brush_id = "villager"
	check(editor.place_at(Vector2(0, 0)), "place a villager")
	var villager_id: String = editor.selected_id
	check(not editor.place_at(Vector2(0, 0)), "overlap is rejected")
	check(not editor.place_at(Vector2(32, 15)), "footprint outside map is rejected")
	check(editor.entities.get_child_count() == 3, "rejected placements leave the world unchanged")
	var villager: Node2D = editor._nodes[villager_id]
	check(villager.process_mode == Node.PROCESS_MODE_DISABLED and editor.state.frozen, "editor disables simulation")
	check(editor.state.population[Enums.Team.PLAYER] == 1, "population reflects placed units")
	check(not editor._nav.nav.is_world_solid(Vector2(-12, -6)), "town center retains its walkable passage in editor navigation")
	check(editor._nav.nav.is_world_solid(Vector2(-5, -5)), "trees block editor navigation")
	editor._x.value = 3
	editor._z.value = 2
	editor._owner.select(1)
	editor._apply_inspector()
	check(editor._nodes[villager_id].sim_pos == Vector2(3, 2), "inspector updates entity position")
	check(editor._nodes[villager_id].team == Enums.Team.AI, "inspector updates entity ownership")
	check(editor.state.population[Enums.Team.PLAYER] == 0 and editor.state.population[Enums.Team.AI] == 1, "replacement preserves population accounting")
	editor._history(false)
	check(editor._nodes[villager_id].sim_pos == Vector2.ZERO, "undo restores prior placement")
	editor._history(true)
	check(editor._nodes[villager_id].sim_pos == Vector2(3, 2), "redo restores changed placement")
	editor._select(villager_id)
	editor.delete_selected()
	check(editor.document.data.entities.size() == 2, "delete removes selected entity")
	editor._history(false)
	check(editor.document.data.entities.size() == 3, "undo restores deleted unit")
	# A real viewport click must place one object, while a toolbar click must not.
	editor._set_tool(editor.Tool.PLACE)
	var target := Vector2(9, 0)
	var screen := editor.get_global_transform_with_canvas() * IsoMath.world_to_screen(target)
	_click(screen)
	check(editor.document.data.entities.size() == 4, "viewport left click places a unit")
	_click(Vector2(320, 24))
	check(editor.document.data.entities.size() == 4, "toolbar consumes clicks without placing")
	# Drag uses viewport event coordinates, including release over the sidebar.
	editor._set_tool(editor.Tool.SELECT)
	var drag_start: Vector2 = editor.get_global_transform_with_canvas() * IsoMath.world_to_screen(Vector2(3, 2))
	var drag_end: Vector2 = editor.get_global_transform_with_canvas() * IsoMath.world_to_screen(Vector2(3, 5))
	_mouse(drag_start, true)
	var motion := InputEventMouseMotion.new()
	motion.position = drag_end
	motion.relative = drag_end - drag_start
	root.push_input(motion, true)
	_mouse(Vector2(20, 120), false)
	check(editor._nodes[villager_id].sim_pos == Vector2(3, 5), "drag commits world coordinates on release over UI")
	check(editor._drag_record.is_empty(), "drag state clears when released over sidebar")
	editor._history(false)
	check(editor._nodes[villager_id].sim_pos == Vector2(3, 2), "drag is one undoable action")
	editor._release_focus()
	# Resource values survive serialization and world reconstruction.
	var tree_record: Dictionary = editor.document.data.entities[1]
	editor._select(tree_record.id)
	editor._amount.value = 1234.5
	editor._rate.value = 7.5
	editor._apply_inspector()
	check(editor._nodes[tree_record.id].amount == 1234.5, "resource inspector applies amount")
	check(editor._nodes[tree_record.id].gather_rate == 7.5, "resource inspector applies gather rate")
	check(editor.save_map("user://editor-test.json"), "editor saves a formatted map")
	check(not editor.document.is_dirty(), "save clears dirty state")
	var saved: Dictionary = editor.document.data.duplicate(true)
	editor._new_map()
	check(editor.open_map("user://editor-test.json"), "editor reopens saved map")
	check(editor.document.data == saved, "reopened map preserves every field")
	check(editor.entities.get_child_count() == 4, "reopen reconstructs entities")
	editor._apply_settings()
	check(not editor.document.is_dirty(), "applying unchanged settings after load is a no-op")
	check(not editor.open_map("user://editor-bad.json"), "invalid file is rejected by editor")
	check(editor.document.data == saved, "failed open preserves document")
	editor._error.hide()
	# Discard guard preserves the map until the user explicitly confirms.
	editor._name_edit.text = "未保存名称"
	editor._apply_settings()
	editor._request_discard(editor._new_map)
	check(editor._confirm.visible and editor.document.data.display_name == "未保存名称", "new-map action asks before discarding changes")
	editor._confirm.hide()
	editor.open_map("user://editor-test.json")
	# Verify real path-following, not just an order flag.
	editor.toggle_play()
	var runtime_unit: Node2D = editor._nodes[villager_id]
	check(runtime_unit.process_mode != Node.PROCESS_MODE_DISABLED and not editor.state.frozen, "play mode enables unit simulation")
	editor._select_runtime(runtime_unit)
	var start: Vector2 = runtime_unit.sim_pos
	editor.command_at(Vector2(3, 9))
	for frame in 60:
		await physics_frame
	check(runtime_unit.sim_pos.distance_to(start) > 1, "runtime unit moves along navigation path")
	check(Data.bounds(editor.document.data).has_point(runtime_unit.sim_pos), "moving unit stays inside rectangular map")
	check(editor.document.data == saved, "simulation never mutates map document")
	var runtime_tree: ResourceNode = editor._nodes[tree_record.id]
	runtime_tree.extract(2.0)
	check(runtime_tree.amount < 1234.5, "resource is dynamic in play mode")
	editor.toggle_play()
	check(editor._nodes[villager_id].sim_pos == start, "stop restores original unit position")
	check(editor._nodes[tree_record.id].amount == 1234.5, "stop restores original resource amount")
	check(not editor.document.is_dirty(), "playtest does not dirty saved map")
	# Shrinking through an existing object must not silently crop it.
	editor._width.value = 16
	editor._height.value = 16
	editor._apply_settings()
	check(Data.bounds(editor.document.data).size == Vector2(64, 32), "unsafe shrinking preserves old bounds")
	editor._error.hide()
	await _test_gameplay(editor)
	check(editor.open_map("res://data/maps/editor_demo.json"), "bundled demo loads")
	check(editor.document.path.is_empty(), "example uses Save As instead of overwriting project file")
	if "--render" in OS.get_cmdline_user_args():
		await _render(editor)
	editor.free()
	await process_frame
	DirAccess.remove_absolute("user://editor-test.json")
	DirAccess.remove_absolute("user://editor-bad.json")
	DirAccess.remove_absolute("user://map-roundtrip-test.json")
	if failures.is_empty():
		print("MAP EDITOR: %d CHECKS PASSED" % checks)
		quit(0)
	else:
		print("MAP EDITOR: %d / %d CHECKS FAILED" % [failures.size(), checks])
		quit(1)

func _test_validation() -> void:
	var data := Data.create(63, 31, "矩形地图")
	check(Data.validate(data).is_empty(), "odd rectangular sizes validate")
	check(Data.bounds(data).size == Vector2(63, 31), "odd sizes retain exact width and height")
	for value in [null, [], 3, "bad", {}, {"format": Data.FORMAT, "schema_version": 1, "display_name": 6}]:
		check(not Data.validate(value).is_empty(), "malformed root rejected: %s" % str(value))
	for patch in [{"schema_version": 2}, {"schema_version": 1.5}, {"bounds": {"min": [0, 0], "max": [12, 12]}}, {"bounds": {"min": [0, 0], "max": [257, 32]}}, {"bounds": {"min": [0.5, 0], "max": [40, 40]}}, {"bounds": {"min": [0, "0"], "max": [40, 40]}}, {"entities": [null]}, {"entities": {}}]:
		var invalid := data.duplicate(true)
		invalid.merge(patch, true)
		check(not Data.validate(invalid).is_empty(), "invalid field rejected: %s" % str(patch))
	var record := Catalog.make_record("resource", "gold", Vector2.ZERO)
	record.id = "gold_1"
	data.entities.append(record)
	check(Data.validate(data).is_empty(), "resource record validates")
	for patch in [{"id": ""}, {"type": "script"}, {"resource_type": "../../bad"}, {"pos": ["x", 0]}, {"pos": [INF, 0]}, {"amount": -1}, {"gather_rate": "4"}, {"pos": [32, 0]}]:
		var invalid := data.duplicate(true)
		invalid.entities[0].merge(patch, true)
		check(not Data.validate(invalid).is_empty(), "invalid entity rejected: %s" % str(patch))
	data.entities.append(record.duplicate(true))
	check(not Data.validate(data).is_empty(), "duplicate entity IDs rejected")
	var full_catalog := Data.create(120, 120)
	var count := 0
	for kind in ["building", "unit", "resource"]:
		for id in Catalog.ids(kind):
			var entry := Catalog.make_record(kind, id, Vector2(-45 + (count % 12) * 8, -40 + floori(count / 12.0) * 8))
			entry.id = "catalog_%d" % count
			full_catalog.entities.append(entry)
			count += 1
	check(Data.validate(full_catalog).is_empty(), "all catalog definitions validate")

func _test_document() -> void:
	var document := Document.new()
	var changed := document.data.duplicate(true)
	changed.display_name = "新名称"
	document.commit(changed)
	changed.display_name = "外部修改"
	check(document.data.display_name == "新名称", "history owns copies of input dictionaries")
	check(document.is_dirty(), "commit marks document dirty")
	document.mark_saved()
	document.undo()
	check(document.is_dirty(), "undo before saved state marks document dirty")
	document.redo()
	check(not document.is_dirty(), "redo back to saved state clears dirty flag")
	document.undo()
	changed = document.data.duplicate(true)
	changed.display_name = "分支"
	document.commit(changed)
	check(not document.redo(), "new edit clears redo branch")

func _test_files() -> void:
	var demo := Loader.load_file("res://data/maps/editor_demo.json")
	check(demo.has("data"), "demo JSON validates")
	if not demo.has("data"):
		return
	var path := "user://map-roundtrip-test.json"
	check(Loader.save_file(demo.data, path).is_empty(), "formatted file save succeeds")
	var content := FileAccess.get_file_as_string(path)
	check(content.contains("\n  ") and content.ends_with("\n"), "JSON is indented and newline terminated")
	check(content.contains("编辑示例"), "UTF-8 Chinese text is preserved")
	check(JSON.stringify(Loader.load_file(path).data) == JSON.stringify(demo.data), "file round trip is lossless")
	demo.data.display_name = "覆盖保存"
	check(Loader.save_file(demo.data, path).is_empty(), "atomic overwrite succeeds")
	check(Loader.load_file(path).data.display_name == "覆盖保存", "overwrite replaces file contents")
	check(not FileAccess.file_exists(path + ".tmp"), "save leaves no temporary file")
	demo.data.schema_version = 999
	check(not Loader.save_file(demo.data, path).is_empty(), "invalid save is rejected")
	check(Loader.load_file(path).data.display_name == "覆盖保存", "invalid save preserves previous file")
	var bad := FileAccess.open("user://editor-bad.json", FileAccess.WRITE)
	bad.store_string("{broken json")
	bad.close()
	check(Loader.load_file("user://editor-bad.json").has("error"), "malformed JSON reports an error")
	check(Loader.load_file("user://does-not-exist-map.json").has("error"), "missing file reports an error")

func _test_rectangular_nav() -> void:
	var nav := NavGridService.new()
	nav.setup_rect(Vector2i(-32, -16), Vector2i(32, 16))
	check(nav.get_map_rect() == Rect2(-32, -16, 64, 32), "rectangular nav reports exact origin and size")
	check(nav.is_world_solid(Vector2(0, -17)), "short-axis exterior is blocked")
	check(not nav.is_world_solid(Vector2(30, 0)), "long-axis interior is walkable")
	var path := nav.find_path(Vector2(-25, 0), Vector2(25, 0))
	check(not path.is_empty(), "rectangular nav finds paths across long axis")
	for point in path:
		check(nav.get_map_rect().has_point(point), "path remains inside rectangular bounds")

func _click(point: Vector2) -> void:
	_mouse(point, true)
	_mouse(point, false)

func _mouse(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	root.push_input(event, true)

func _test_gameplay(editor: Node2D) -> void:
	var data := Data.create(40, 24, "动态单位测试")
	data.entities = [
		Catalog.make_record("unit", "villager", Vector2(0, -5)),
		Catalog.make_record("resource", "food", Vector2(3, -5)),
		Catalog.make_record("unit", "swordsman", Vector2(0, 5)),
		Catalog.make_record("unit", "swordsman", Vector2(4, 5), "ai"),
	]
	for index in data.entities.size():
		data.entities[index].id = "dynamic_%d" % index
	editor.document.replace(data)
	editor._rebuild_world()
	editor.toggle_play()
	var villager: UnitAgent = editor._nodes.dynamic_0
	var food: ResourceNode = editor._nodes.dynamic_1
	var soldier: UnitAgent = editor._nodes.dynamic_2
	var enemy: UnitAgent = editor._nodes.dynamic_3
	editor._select_runtime(villager)
	editor.command_at(food.sim_pos)
	check(villager.order == Enums.OrderType.GATHER, "right clicking resources issues gather order")
	editor._select_runtime(soldier)
	editor.command_at(enemy.sim_pos)
	check(soldier.order == Enums.OrderType.ATTACK, "right clicking hostile unit issues attack order")
	for frame in 120:
		await physics_frame
	check(food.amount < 200, "villager actually harvests in playtest")
	check(enemy.hp < enemy.def.max_hp, "soldier actually deals combat damage in playtest")
	editor.toggle_play()
	check(editor._nodes.dynamic_3.hp == editor._nodes.dynamic_3.def.max_hp, "stopping playtest restores unit health")
	check(editor._nodes.dynamic_1.amount == 200, "stopping playtest restores harvested resources")

func _render(editor: Node2D) -> void:
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/map-editor-preview.png")
	editor.toggle_play()
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/map-editor-playtest.png")
