extends Node

## Standalone pathfinding playground: dozens of units, square blockers
## (buildings / ore / water / cliff), G toggles footprint overlay.

const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const PathBlockerScript := preload("res://scripts/entities/path_blocker.gd")
const NavServiceHolderScript := preload("res://scripts/systems/nav_service_holder.gd")
const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const NavDebugOverlayScript := preload("res://scripts/presentation/nav_debug_overlay.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const SWORDSMAN_DEF := preload("res://data/units/swordsman.tres")
const ARCHER_DEF := preload("res://data/units/archer.tres")
const HOUSE_DEF := preload("res://data/buildings/house.tres")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")

const GROUND_MIN := -36
const GROUND_MAX := 36
const GROUND_STEP := 8
const UNIT_COUNT := 24
const WATER_SHEET := "res://assets/sprites/terrain/water_shallow"
const CLIFF_SHEET := "res://assets/sprites/terrain/cliff_section"
const CLIFF_B_SHEET := "res://assets/sprites/terrain/cliff_section_b"
const GOLD_SHEET := "res://assets/sprites/resources/gold_mine"

var match_state := MatchState.new()
var nav_holder: NavServiceHolderScript
var nav: NavGridServiceScript
var player_civ: CivDef = CHINESE_CIV

func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	match_state.register_pop(Enums.Team.PLAYER, 0, 80)
	_setup_ground()
	_setup_nav()
	_spawn_blockers()
	_spawn_units()
	call_deferred("_finish_setup")

func _finish_setup() -> void:
	if nav_holder != null:
		nav_holder.rebuild_from_scene()
	_setup_debug_overlay()
	_focus_camera()

func _setup_nav() -> void:
	nav_holder = NavServiceHolderScript.new()
	nav_holder.name = "NavService"
	nav_holder.setup(GROUND_MIN, GROUND_MAX, 1.0)
	nav = nav_holder.nav
	get_parent().call_deferred("add_child", nav_holder)

func _setup_debug_overlay() -> void:
	var match_root := get_parent()
	var overlay := NavDebugOverlayScript.new()
	overlay.name = "NavDebugOverlay"
	overlay.nav = nav
	match_root.call_deferred("add_child", overlay)

func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as Node2D
	if ground == null:
		return
	for child in ground.get_children():
		child.free()
	var texture: Texture2D = null
	if ResourceLoader.exists(TERRAIN_TEXTURE):
		texture = load(TERRAIN_TEXTURE) as Texture2D
	var lx := GROUND_MIN
	while lx <= GROUND_MAX:
		var lz := GROUND_MIN
		while lz <= GROUND_MAX:
			var tile := Sprite2D.new()
			tile.centered = true
			tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			tile.z_index = -100
			if texture != null:
				tile.texture = texture
				tile.scale = Vector2(0.35, 0.35)
			else:
				tile.modulate = GROUND_COLOR
			tile.position = IsoMathScript.world_to_screen(Vector2(float(lx), float(lz)))
			ground.add_child(tile)
			lz += GROUND_STEP
		lx += GROUND_STEP

func _spawn_blockers() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	# Square building wall (houses) — force a detour.
	_spawn_building(entities, Vector2(0.0, -2.0), "HouseA")
	_spawn_building(entities, Vector2(2.0, -2.0), "HouseB")
	_spawn_building(entities, Vector2(4.0, -2.0), "HouseC")
	_spawn_building(entities, Vector2(0.0, 0.0), "HouseD")
	_spawn_building(entities, Vector2(0.0, 2.0), "HouseE")
	# Gold ore squares.
	_spawn_blocker(
		entities, "GoldA", Vector2(-10.0, 6.0), Vector2(2.0, 2.0), GOLD_SHEET, 0, &"ore"
	)
	_spawn_blocker(
		entities, "GoldB", Vector2(-8.0, 8.0), Vector2(2.0, 2.0), GOLD_SHEET, 0, &"ore"
	)
	_spawn_blocker(
		entities, "GoldC", Vector2(12.0, -8.0), Vector2(2.0, 2.0), GOLD_SHEET, 0, &"ore"
	)
	# Water band (walk-impassable).
	for i in 8:
		_spawn_blocker(
			entities,
			"Water%d" % i,
			Vector2(-16.0 + float(i) * 2.0, 14.0),
			Vector2(2.0, 2.0),
			WATER_SHEET,
			i % 4,
			&"water"
		)
	# Cliff ridge.
	for i in 5:
		_spawn_blocker(
			entities,
			"Cliff%d" % i,
			Vector2(16.0, -14.0 + float(i) * 3.0),
			Vector2(3.0, 3.0),
			CLIFF_SHEET if i % 2 == 0 else CLIFF_B_SHEET,
			12,
			&"cliff"
		)

func _spawn_building(entities: Node2D, pos: Vector2, node_name: String) -> void:
	var building := BUILDING_VIEW.instantiate() as Node2D
	building.name = node_name
	building.set("team", Enums.Team.PLAYER)
	building.set("def", HOUSE_DEF)
	building.set("civ", player_civ)
	building.set("match_state", match_state)
	building.set("sim_pos", pos)
	entities.add_child(building)

func _spawn_blocker(
	entities: Node2D,
	node_name: String,
	pos: Vector2,
	size: Vector2,
	sheet: String,
	frame: int,
	kind: StringName
) -> void:
	var blocker := PathBlockerScript.new()
	blocker.name = node_name
	blocker.sim_pos = pos
	blocker.block_size = size
	blocker.sheet_base = sheet
	blocker.frame_index = frame
	blocker.kind = kind
	entities.add_child(blocker)

func _spawn_units() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	var defs := [VILLAGER_DEF, SWORDSMAN_DEF, ARCHER_DEF]
	var cols := 6
	for index in UNIT_COUNT:
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.name = "Unit%d" % (index + 1)
		unit.set("team", Enums.Team.PLAYER)
		unit.set("def", defs[index % defs.size()])
		unit.set("civ", player_civ)
		unit.set("match_state", match_state)
		var row := int(index / cols)
		var col := index % cols
		unit.set("sim_pos", Vector2(-22.0 + float(col) * 1.6, -18.0 + float(row) * 1.6))
		entities.add_child(unit)

func _focus_camera() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2(-8.0, -4.0))
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2(-8.0, -4.0))
