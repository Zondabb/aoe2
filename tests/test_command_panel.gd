extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const HUD_SCENE := preload("res://scenes/ui/hud.tscn")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
const BARRACKS: BuildingDef = preload("res://data/buildings/barracks.tres")
const UiCatalogScript := preload("res://scripts/presentation/ui_catalog.gd")

class MockSelection extends Node:
	signal selection_changed(selected: Array)

	var units: Array = []
	var building: Node2D

	func get_selected_units() -> Array:
		return units

	func get_selected_building() -> Node2D:
		return building

	func get_primary_selection() -> Node2D:
		return units[0] if not units.is_empty() else building

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_command_stop_clears_move(failures)
	_test_panel_texture_non_null(failures)
	_test_command_grid_for_villager(failures)
	_test_icon_frames_non_null(failures)
	_test_unit_icon_frame_mapping(failures)
	_test_train_button_click_survives(failures)
	return failures

func _test_command_stop_clears_move(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.sim_pos = Vector2.ZERO
	root.add_child(unit)
	unit.command_move(Vector2(5, 0))
	if unit.order != Enums.OrderType.MOVE:
		failures.append("setup move order failed")
	unit.command_stop()
	if unit.order != Enums.OrderType.NONE:
		failures.append("command_stop should clear MOVE order")
	root.free()

func _test_panel_texture_non_null(failures: Array[String]) -> void:
	if UiCatalogScript.panel_texture() == null:
		failures.append("UiCatalog.panel_texture should load exported panel_game sheet")

func _test_command_grid_for_villager(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var hud := HUD_SCENE.instantiate() as HudController
	root.add_child(hud)
	var mock := MockSelection.new()
	hud.add_child(mock)
	var state := MatchState.new()
	state.setup_defaults()
	var civ := load("res://data/civs/chinese.tres") as CivDef
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.team = Enums.Team.PLAYER
	root.add_child(unit)
	mock.units = [unit]
	hud.setup(state, civ, null, mock)
	var grid := hud.get_node("%CommandGrid") as GridContainer
	if grid == null:
		failures.append("CommandGrid missing from HUD")
	elif grid.get_child_count() < 1:
		failures.append("command grid should show buttons when villager is selected")
	root.free()

func _test_icon_frames_non_null(failures: Array[String]) -> void:
	var checks: Array[Dictionary] = [
		{"base": UiCatalogScript.ICONS_COMMANDS_BASE, "frame": UiCatalogScript.FRAME_STOP},
		{"base": UiCatalogScript.ICONS_BUILDINGS_BASE, "frame": UiCatalogScript.FRAME_BUILD_HOUSE},
		{"base": UiCatalogScript.ICONS_BUILDINGS_BASE, "frame": UiCatalogScript.FRAME_BUILD_LUMBER},
		{"base": UiCatalogScript.ICONS_BUILDINGS_BASE, "frame": UiCatalogScript.FRAME_BUILD_STABLE},
		{"base": UiCatalogScript.ICONS_UNITS_BASE, "frame": UiCatalogScript.FRAME_UNIT_VILLAGER},
	]
	for check in checks:
		var tex: Texture2D = UiCatalogScript.atlas_frame(check["base"], int(check["frame"]))
		if tex == null:
			failures.append("atlas_frame(%s, %d) should not be null" % [check["base"], int(check["frame"])])

func _test_unit_icon_frame_mapping(failures: Array[String]) -> void:
	if UiCatalogScript.unit_icon_frame(&"villager") != UiCatalogScript.FRAME_UNIT_VILLAGER:
		failures.append("villager icon frame mismatch")
	if UiCatalogScript.unit_icon_frame(&"archer") != UiCatalogScript.FRAME_UNIT_ARCHER:
		failures.append("archer icon frame mismatch")
	if UiCatalogScript.unit_icon_frame(&"unknown_unit") != 0:
		failures.append("unknown unit should fall back to frame 0")

func _test_train_button_click_survives(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var hud := HUD_SCENE.instantiate() as HudController
	root.add_child(hud)
	var mock := MockSelection.new()
	hud.add_child(mock)
	var state := MatchState.new()
	state.setup_defaults()
	state.resources[Enums.Team.PLAYER][Enums.ResourceType.FOOD] = 999
	state.resources[Enums.Team.PLAYER][Enums.ResourceType.GOLD] = 999
	state.population_cap[Enums.Team.PLAYER] = 10
	var civ := load("res://data/civs/chinese.tres") as CivDef
	var building := BUILDING_VIEW.instantiate() as Node2D
	building.set("def", BARRACKS)
	building.set("civ", civ)
	building.set("team", Enums.Team.PLAYER)
	building.set("match_state", state)
	building.set("is_complete", true)
	root.add_child(building)
	# This suite runs from SceneTree._initialize, before normal ready notifications.
	building.call("_ready")
	mock.building = building
	hud.setup(state, civ, null, mock)
	var grid := hud.get_node("%CommandGrid") as GridContainer
	if grid == null or grid.get_child_count() < 1:
		failures.append("barracks should show a train button")
		root.free()
		return
	var button := grid.get_child(0) as BaseButton
	button.pressed.emit()
	if (building.get("train_queue") as Array).is_empty():
		failures.append("train button click should enqueue a unit")
	button.pressed.emit()
	hud._refresh()
	var queue := hud.get_node("%ProductionQueue") as GridContainer
	if building.train_queue.size() != 2 or not queue.visible or not queue.get_child(1).visible:
		failures.append("repeated training clicks must display multiple queue items")
	building.train_progress = 1.0
	var food: int = state.resources[0][0]
	(queue.get_child(1) as Button).pressed.emit()
	hud._refresh()
	if building.train_queue.size() != 1 or building.train_progress != 1.0 or state.resources[0][0] <= food:
		failures.append("queue item click cancels and refunds without restarting the active item")
	hud.read_only = true
	hud._refresh()
	if not (queue.get_child(0) as Button).disabled:
		failures.append("spectators cannot cancel production")
	building.team = Enums.Team.AI
	hud._refresh()
	if queue.visible:
		failures.append("opponent production queue is not exposed")
	building.team = Enums.Team.PLAYER
	hud.read_only = false
	hud._refresh()
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.match_state = state
	root.add_child(unit)
	if unit.hp <= 0.0:
		unit._ready()
	# Exercise synchronous selection signals, without waiting for _process to
	# hide the old building queue. This is the box-selection crash path.
	mock.building = null
	mock.units = [unit]
	mock.selection_changed.emit([unit])
	if queue.visible or (hud.get_node("%ProductionProgress") as Control).visible:
		failures.append("selecting units immediately hides the previous building queue")
	if "队列" in (hud.get_node("%CommandHint") as Label).text:
		failures.append("unit selection must not retain production help text")
	mock.units = []
	mock.building = building
	mock.selection_changed.emit([building])
	if not queue.visible:
		failures.append("reselecting the building immediately restores its queue")
	mock.building = null
	mock.selection_changed.emit([])
	if queue.visible or (hud.get_node("%ProductionProgress") as Control).visible:
		failures.append("empty selection immediately hides production controls")
	root.free()
