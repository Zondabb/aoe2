extends SceneTree

const Data := preload("res://scripts/world/map_data.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
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
	var editor: Node2D = load("res://scenes/editor/map_editor.tscn").instantiate()
	root.add_child(editor)
	await process_frame
	await process_frame
	check(editor._category.item_count == 4, "editor has an explicit fourth terrain category")
	check(editor._category.get_item_text(3).contains("地形"), "terrain category has a visible Chinese label")
	editor._category.select(3)
	editor._category.item_selected.emit(3)
	check(editor._kind == "terrain", "category selection activates terrain placement")
	check(editor._palette.item_count == 2, "terrain palette contains water and cliff")
	check(editor._terrain_brush_fields.visible and not editor._team.visible, "terrain brush exposes dimensions instead of ownership")
	var default_water := Catalog.make_record("terrain", "water", Vector2.ZERO)
	var default_size := Catalog.half_size(default_water) * 2.0
	check(editor._terrain_brush_width.value == default_size.x and editor._terrain_brush_height.value == default_size.y, "water brush inherits catalog dimensions")
	check(editor._terrain_brush_width.min_value == 1 and editor._terrain_brush_width.max_value == 128 and editor._terrain_brush_width.step == 1, "terrain brush width is bounded to integer 1–128 cells")
	check(editor._terrain_brush_height.min_value == 1 and editor._terrain_brush_height.max_value == 128 and editor._terrain_brush_height.step == 1, "terrain brush height is bounded to integer 1–128 cells")
	editor._terrain_brush_width.value = 12
	editor._terrain_brush_height.value = 8
	var brush: Dictionary = editor._brush(Vector2(-8.2, 0.1))
	check(brush.block_size == [12.0, 8.0] and brush.pos == [-8.0, 0.0], "placement preview uses current brush dimensions and snapping")
	check(not brush.has("team"), "terrain brush records have no faction")
	check(editor.place_at(Vector2(-8, 0)), "water patch places through normal editor commit")
	var water_id: String = editor.selected_id
	check(editor._nodes[water_id].get_meta("map_record").block_size == [12.0, 8.0], "water preview retains editable map footprint")
	check(editor._nodes[water_id].is_in_group("path_blockers"), "editor water is a real navigation blocker")
	check(editor._nav.nav.is_world_solid(Vector2(-8, 0)), "water center blocks editor navigation")
	check(editor._terrain_fields.visible and not editor._owner.visible and not editor._resource_fields.visible, "water inspector shows dimensions with no faction or resource controls")
	check(editor._terrain_width.value == 12 and editor._terrain_height.value == 8, "terrain inspector reflects placed dimensions")
	check(editor._pick(Vector2(-8, 0)) == editor._nodes[water_id], "terrain can be selected by its footprint")
	check(editor.place_at(Vector2(-4, 0)), "overlapping water patches can paint a continuous lake")
	check(editor.document.data.entities.size() == 2, "continuous terrain painting retains both patches")
	editor._palette.select(1)
	editor._palette.item_selected.emit(1)
	var default_cliff := Catalog.make_record("terrain", "cliff", Vector2.ZERO)
	default_size = Catalog.half_size(default_cliff) * 2.0
	check(editor._brush_id == "cliff", "terrain palette selects cliff kind")
	check(editor._terrain_brush_width.value == default_size.x and editor._terrain_brush_height.value == default_size.y, "switching terrain kinds restores appropriate catalog brush dimensions")
	editor._terrain_brush_width.value = 4
	editor._terrain_brush_height.value = 20
	check(editor.place_at(Vector2(12, 0)), "cliff patch places through normal editor commit")
	var cliff_id: String = editor.selected_id
	check(editor._nodes[cliff_id].kind == &"cliff", "cliff palette constructs cliff runtime geometry")
	check(editor._nav.nav.is_world_solid(Vector2(12, 0)), "cliff center blocks editor navigation")
	var count: int = editor.entities.get_child_count()
	check(not editor.place_at(Vector2(39, 0)), "terrain footprint beyond map bounds is rejected")
	check(editor.entities.get_child_count() == count, "invalid terrain placement leaves runtime entities unchanged")
	editor._select(water_id)
	editor._x.value = -10
	editor._z.value = -4
	editor._terrain_width.value = 10
	editor._terrain_height.value = 6
	editor._apply_inspector()
	check(editor._nodes[water_id].sim_pos == Vector2(-10, -4), "terrain inspector changes logical position")
	check(editor._nodes[water_id].block_size == Vector2(10, 6), "terrain inspector changes navigation footprint")
	check(not editor._record(water_id).has("team"), "terrain inspector does not add an ownership field")
	editor._history(false)
	check(editor._nodes[water_id].sim_pos == Vector2(-8, 0) and editor._nodes[water_id].block_size == Vector2(12, 8), "undo restores both terrain position and dimensions")
	editor._history(true)
	check(editor._nodes[water_id].sim_pos == Vector2(-10, -4) and editor._nodes[water_id].block_size == Vector2(10, 6), "redo restores edited terrain position and dimensions")
	# Exercise real viewport drag/release, rather than merely rewriting a record.
	editor._set_tool(editor.Tool.SELECT)
	var drag_start: Vector2 = editor.get_global_transform_with_canvas() * IsoMath.world_to_screen(Vector2(-12, -4))
	var drag_end: Vector2 = editor.get_global_transform_with_canvas() * IsoMath.world_to_screen(Vector2(-12, -12))
	_mouse(drag_start, true)
	var motion := InputEventMouseMotion.new()
	motion.position = drag_end
	motion.relative = drag_end - drag_start
	root.push_input(motion, true)
	_mouse(drag_end, false)
	check(editor._nodes[water_id].sim_pos == Vector2(-10, -12), "viewport drag moves terrain footprint")
	check(editor._drag_record.is_empty(), "terrain drag completes without retaining drag state")
	editor._history(false)
	check(editor._nodes[water_id].sim_pos == Vector2(-10, -4), "terrain dragging creates one undoable edit")
	editor._select(cliff_id)
	editor.delete_selected()
	check(not editor._nodes.has(cliff_id), "terrain deletion removes runtime blocker")
	check(not editor._nav.nav.is_world_solid(Vector2(12, 0)), "deleting terrain restores land navigation")
	editor._history(false)
	check(editor._nodes.has(cliff_id) and editor._nav.nav.is_world_solid(Vector2(12, 0)), "undo deletion restores terrain and its blocked cells")
	check(editor.save_map("user://terrain-editor-test.json"), "terrain map saves as formatted JSON")
	var saved: Dictionary = editor.document.data.duplicate(true)
	var content := FileAccess.get_file_as_string("user://terrain-editor-test.json")
	check(content.contains("\n  ") and content.contains('"terrain_id"') and content.contains('"block_size"'), "terrain file is formatted and includes terrain type and dimensions")
	editor._new_map()
	check(editor.open_map("user://terrain-editor-test.json"), "saved terrain map reopens in editor")
	check(editor.document.data == saved, "terrain map round trip preserves every record and brush dimension")
	check(editor.entities.get_child_count() == 3, "terrain map loading reconstructs each patch")
	check(editor._nav.nav.is_world_solid(Vector2(12, 0)), "loaded cliff remains impassable")
	editor._width.value = 16
	editor._height.value = 16
	editor._apply_settings()
	check(Data.bounds(editor.document.data).size == Vector2(80, 80), "terrain outside smaller dimensions prevents unsafe map shrinking")
	editor._error.hide()
	_test_sandbox(editor)
	if "--render" in OS.get_cmdline_user_args():
		await _render(editor, saved)
	editor.free()
	await process_frame
	DirAccess.remove_absolute("user://terrain-editor-test.json")
	if failures.is_empty():
		print("TERRAIN EDITOR: %d CHECKS PASSED" % checks)
		quit(0)
	else:
		print("TERRAIN EDITOR: %d / %d CHECKS FAILED" % [failures.size(), checks])
		quit(1)

func _test_sandbox(editor: Node2D) -> void:
	var data := Data.create(64, 48, "湖泊与悬崖试运行")
	var lake := Catalog.make_record("terrain", "water", Vector2.ZERO)
	lake.block_size = [12, 16]
	var cliff := Catalog.make_record("terrain", "cliff", Vector2(20, -12))
	cliff.block_size = [4, 8]
	data.entities = [lake, cliff, Catalog.make_record("unit", "villager", Vector2(-18, 0))]
	for index in data.entities.size():
		data.entities[index].id = "sandbox_%d" % index
	editor.document.replace(data)
	editor._rebuild_world()
	check(editor._nodes.sandbox_0.process_mode == Node.PROCESS_MODE_DISABLED, "editing mode disables terrain simulation")
	editor.toggle_play()
	var unit: UnitAgent = editor._nodes.sandbox_2
	var water: PathBlocker = editor._nodes.sandbox_0
	var shore := preload("res://scripts/world/shore_geometry.gd")
	var radius := CollisionResolver.unit_radius(unit)
	unit.set_physics_process(false)
	editor._select_runtime(unit)
	editor.command_at(Vector2(18, 0))
	check(unit.order == Enums.OrderType.MOVE, "sandbox commands movement across a lake")
	var remained_on_land := true
	var greatest_detour := 0.0
	for step in 900:
		editor._nav._process(1.0 / 30.0)
		unit._physics_process(1.0 / 30.0)
		remained_on_land = remained_on_land and not shore.circle_hits(unit.sim_pos, radius, water.get_water_contours())
		greatest_detour = maxf(greatest_detour, absf(unit.sim_pos.y))
		if unit.order == Enums.OrderType.NONE:
			break
	check(remained_on_land, "actual sandbox unit never steps into the lake")
	check(greatest_detour > 5.0, "actual sandbox movement routes around the irregular water and uses the walkable beach")
	check(unit.sim_pos.distance_to(Vector2(18, 0)) < 1.0, "unit reaches land on the far side of a lake")
	editor.command_at(Vector2.ZERO)
	remained_on_land = true
	for step in 600:
		editor._nav._process(1.0 / 30.0)
		unit._physics_process(1.0 / 30.0)
		remained_on_land = remained_on_land and not shore.circle_hits(unit.sim_pos, radius, water.get_water_contours())
		if unit.order == Enums.OrderType.NONE:
			break
	check(remained_on_land and unit.order == Enums.OrderType.NONE, "clicking water stops the unit at a reachable shore")
	check(shore.signed_distance(unit.sim_pos, water.get_water_contours()) >= radius - 0.001 and unit.sim_pos.distance_to(Vector2.ZERO) < 12.0, "water move goal resolves to the actual reachable shore")
	editor.command_at(Vector2(20, -20))
	var remained_outside_cliff := true
	for step in 750:
		editor._nav._process(1.0 / 30.0)
		unit._physics_process(1.0 / 30.0)
		remained_outside_cliff = remained_outside_cliff and not Rect2(18, -16, 4, 8).has_point(unit.sim_pos)
		if unit.order == Enums.OrderType.NONE:
			break
	check(remained_outside_cliff, "actual sandbox unit never steps into a cliff")
	check(unit.sim_pos.distance_to(Vector2(20, -20)) < 1.0, "unit reaches accessible land behind the cliff")
	check(editor.document.data == data, "terrain playtest does not modify saved layout")
	editor.toggle_play()
	check(editor._nodes.sandbox_2.sim_pos == Vector2(-18, 0), "ending playtest restores unit starting position")
	check(editor._nodes.sandbox_0.block_size == Vector2(12, 16), "ending playtest restores terrain geometry")
	check(not editor.document.is_dirty(), "terrain playtest leaves document clean")
	editor._category.select(2)
	editor._category.item_selected.emit(2)
	check(not editor._terrain_brush_fields.visible and editor._team.visible, "leaving terrain palette restores unit ownership controls")
	check(not editor.place_at(Vector2.ZERO), "land unit placement cannot overlap water")

func _mouse(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	root.push_input(event, true)

func _render(editor: Node2D, data: Dictionary) -> void:
	editor.document.replace(data)
	editor._rebuild_world()
	editor.fit_map()
	editor._category.select(3)
	editor._category.item_selected.emit(3)
	editor._select(data.entities[0].id)
	editor._set_status("地形可连续放置，也可选择后修改宽高；试运行中陆地单位自动绕过水体和悬崖。")
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/terrain-editor-preview.png")
	var scroll := editor._edit_panel.get_parent().get_parent() as ScrollContainer
	scroll.ensure_control_visible(editor._terrain_fields)
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/terrain-editor-inspector.png")
